import 'dart:async';

import 'package:dartpad_gguf_example/chat_controller.dart';
import 'package:dartpad_gguf_example/main.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:material_ui/material_ui.dart';

const _defaultSystem = 'You are a concise, helpful assistant.';
const _smolLmUrl =
    'https://huggingface.co/unsloth/SmolLM2-135M-Instruct-GGUF/resolve/'
    '9e6855bc4be717fca1ef21360a1db4b29d5c559a/'
    'SmolLM2-135M-Instruct-Q4_K_M.gguf';
const _qwen35Url =
    'https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/resolve/'
    '6ab461498e2023f6e3c1baea90a8f0fe38ab64d0/'
    'Qwen3.5-0.8B-Q4_K_M.gguf';
const _gemma4Url =
    'https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/'
    '0314792d7f1f7e229411f620751375812bb9faf2/'
    'gemma-4-E2B-it-Q4_K_S.gguf';
const _smolLmItem = 'SmolLM2 135M (~105 MB)';
const _qwen35Item = 'Qwen3.5 0.8B (~533 MB)';
const _gemma4Item = 'Gemma 4 E2B (desktop Chrome, ~3 GB)';
final _prompt = find.widgetWithText(TextField, 'Prompt');
final _send = find.widgetWithText(FilledButton, 'Send');
final _stop = find.widgetWithText(FilledButton, 'Stop');

void main() {
  late _FakeEngine engine;

  void createFakeEngine() {
    engine = _FakeEngine();
    addTearDown(engine.dispose);
  }

  Future<void> openApp(WidgetTester tester) async {
    createFakeEngine();
    await tester.pumpWidget(GgufApp(createEngine: () async => engine));
    await tester.tap(find.text('Load'));
    await tester.pump();
  }

  Future<void> send(WidgetTester tester, String text) async {
    await tester.enterText(_prompt, text);
    await tester.pump();
    await tester.tap(_send);
    await tester.pump();
  }

  Future<void> finishStream(WidgetTester tester) async {
    await tester.pump();
    // Browser streams can deliver completion across both test clock queues.
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
    }
  }

  Future<void> finishTurn(WidgetTester tester, String reply) async {
    engine.emit(reply);
    unawaited(engine.output!.close());
    await finishStream(tester);
  }

  Future<void> readyApp(WidgetTester tester) async {
    await openApp(tester);
    engine.loaded.complete();
    await tester.pump();
  }

  testWidgets('starts one load when tapped twice before a rebuild', (
    tester,
  ) async {
    createFakeEngine();
    final created = Completer<LlamaEngine>();
    var attempts = 0;
    await tester.pumpWidget(
      GgufApp(
        createEngine: () {
          attempts++;
          return created.future;
        },
      ),
    );

    await tester.tap(find.text('Load'));
    await tester.tap(find.text('Load'));

    created.complete(engine);
    engine.loaded.complete();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    expect(attempts, 1);
  });

  testWidgets('loads pinned SmolLM2, reports progress and streams text', (
    tester,
  ) async {
    await openApp(tester);
    expect(
      engine.source?.url,
      Uri.parse(
        'https://huggingface.co/unsloth/SmolLM2-135M-Instruct-GGUF/resolve/'
        '9e6855bc4be717fca1ef21360a1db4b29d5c559a/'
        'SmolLM2-135M-Instruct-Q4_K_M.gguf',
      ),
    );
    expect(engine.contextSize, 2048);
    engine.progress?.call(const ModelDownloadProgress.fraction(0.5));
    await tester.pump();
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      0.5,
    );

    engine.loaded.complete();
    await tester.pump();
    await send(tester, 'Tell me a story');
    engine.emit('There was');
    await tester.pump();
    expect(find.text('There was'), findsOneWidget);
    await finishTurn(tester, ' a fox.');
    expect(find.text('There was a fox.'), findsOneWidget);
  });

  testWidgets('sends visible conversation history until Clear', (tester) async {
    await readyApp(tester);
    await send(tester, 'Hello');
    await finishTurn(tester, 'Hi there');
    await send(tester, 'Follow up');
    expect(engine.lastMessages, [
      (LlamaChatRole.system, _defaultSystem),
      (LlamaChatRole.user, 'Hello'),
      (LlamaChatRole.assistant, 'Hi there'),
      (LlamaChatRole.user, 'Follow up'),
    ]);
    await finishTurn(tester, 'Second answer');

    for (final text in ['Hello', 'Hi there', 'Follow up', 'Second answer']) {
      expect(find.text(text), findsOneWidget);
    }

    await tester.tap(find.text('Clear'));
    await tester.pump();
    expect(find.text('Hi there'), findsNothing);
    await send(tester, 'Fresh turn');
    expect(engine.lastMessages, [
      (LlamaChatRole.system, _defaultSystem),
      (LlamaChatRole.user, 'Fresh turn'),
    ]);
    await finishTurn(tester, 'Fresh answer');
  });

  testWidgets('generation settings reach the model request', (tester) async {
    await readyApp(tester);
    expect(find.widgetWithText(TextField, 'System prompt'), findsNothing);
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();

    tester.widget<Slider>(find.byType(Slider).at(0)).onChanged!(0.2);
    await tester.pump();
    tester.widget<Slider>(find.byType(Slider).at(1)).onChanged!(128);
    await tester.pump();
    await tester.enterText(
      find.widgetWithText(TextField, 'System prompt'),
      '  Reply like a pirate.  ',
    );
    await send(tester, 'Hello');
    expect(engine.lastParams?.temp, 0.2);
    expect(engine.lastParams?.maxTokens, 128);
    expect(engine.lastMessages, [
      (LlamaChatRole.system, 'Reply like a pirate.'),
      (LlamaChatRole.user, 'Hello'),
    ]);
    await finishTurn(tester, 'Ahoy!');
  });

  testWidgets('shows elapsed time and then exact reported usage', (
    tester,
  ) async {
    await readyApp(tester);
    expect(find.text('WebGPU'), findsOneWidget);
    await send(tester, 'Hello');
    expect(
      find.textContaining(RegExp(r'Streaming… · \d+\.\ds · WebGPU')),
      findsOneWidget,
    );
    expect(find.textContaining(' tok'), findsNothing);

    engine.emit(
      'Hi there',
      usage: const LlamaGenerationUsage(
        promptTokens: 10,
        completionTokens: 20,
        duration: Duration(seconds: 2),
      ),
    );
    unawaited(engine.output!.close());
    await finishStream(tester);
    expect(find.text('20 tok · 10.0 tok/s · WebGPU'), findsOneWidget);

    await send(tester, 'No usage this time');
    await finishTurn(tester, 'I am still here.');
    expect(find.textContaining(RegExp(r'\d+\.\ds · WebGPU')), findsOneWidget);
    expect(find.textContaining(' tok'), findsNothing);
    expect(engine.countedText, isNull);
  });

  testWidgets('a preset fills and focuses the prompt and enables Send', (
    tester,
  ) async {
    await readyApp(tester);
    expect(tester.widget<FilledButton>(_send).onPressed, isNull);
    await tester.tap(find.widgetWithText(ActionChip, 'Summarize'));
    await tester.pump();

    final field = tester.widget<TextField>(_prompt);
    expect(
      field.controller?.text,
      'Summarize how WebGPU speeds up browser AI in 3 short bullet points.',
    );
    expect(field.focusNode?.hasFocus, isTrue);
    expect(tester.widget<FilledButton>(_send).onPressed, isNotNull);
  });

  testWidgets('Stop shows flushed text and sends it in the next turn', (
    tester,
  ) async {
    await readyApp(tester);
    await send(tester, 'Tell me a story');
    engine.emit('A fox');
    await tester.pump();
    expect(find.text('A fox'), findsOneWidget);

    engine.flushOnCancel = ' ran home.';
    engine.holdAfterCancel = true;
    await tester.tap(_stop);
    await finishStream(tester);
    expect(engine.events, ['cancel']);
    expect(engine.output!.hasListener, isTrue);
    expect(find.text('Stopping…'), findsOneWidget);
    expect(find.text('A fox ran home.'), findsOneWidget);

    unawaited(engine.output!.close());
    await finishStream(tester);
    expect(engine.output!.hasListener, isFalse);
    expect(find.text('A fox ran home.'), findsOneWidget);
    expect(engine.countedText, 'A fox ran home.');
    expect(find.text('Stopped.'), findsOneWidget);
    expect(_send, findsOneWidget);

    await send(tester, 'What happened next?');
    expect(engine.lastMessages, [
      (LlamaChatRole.system, _defaultSystem),
      (LlamaChatRole.user, 'Tell me a story'),
      (LlamaChatRole.assistant, 'A fox ran home.'),
      (LlamaChatRole.user, 'What happened next?'),
    ]);
    await finishTurn(tester, 'It went to sleep.');
  });

  testWidgets('Stop before any output rolls back the turn', (tester) async {
    await readyApp(tester);
    await send(tester, 'Rolled back');
    await tester.tap(_stop);
    await finishStream(tester);
    expect(engine.events, ['cancel']);
    expect(find.text('Rolled back'), findsNothing);
    expect(find.text('Assistant'), findsNothing);
    expect(find.text('Stopped.'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await send(tester, 'Try again');
    expect(engine.lastMessages, [
      (LlamaChatRole.system, _defaultSystem),
      (LlamaChatRole.user, 'Try again'),
    ]);
    await finishTurn(tester, 'It worked.');
  });

  testWidgets('Stop keeps an empty assistant turn committed by the session', (
    tester,
  ) async {
    await readyApp(tester);
    await send(tester, 'First turn');
    engine.emit('', thinking: 'Thinking');
    await tester.pump();

    await tester.tap(_stop);
    await finishStream(tester);
    expect(find.text('First turn'), findsOneWidget);
    expect(find.text('Assistant'), findsOneWidget);
    expect(
      find.descendant(of: find.byType(SelectionArea), matching: find.text('')),
      findsOneWidget,
    );
    expect(find.text('Stopped.'), findsOneWidget);
    expect(engine.countedText, isNull);

    await send(tester, 'Next turn');
    expect(engine.lastMessages, [
      (LlamaChatRole.system, _defaultSystem),
      (LlamaChatRole.user, 'First turn'),
      (LlamaChatRole.assistant, ''),
      (LlamaChatRole.user, 'Next turn'),
    ]);
    await finishTurn(tester, 'Hello');
  });

  testWidgets('shows typed load and generation errors', (tester) async {
    await openApp(tester);
    engine.loaded.completeError(LlamaModelException('Download failed'));
    await tester.pump();
    expect(find.text('Download failed'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);

    engine.loaded = Completer<void>();
    await tester.tap(find.text('Load'));
    await tester.pump();
    engine.loaded.complete();
    await tester.pump();
    await send(tester, 'Will fail');
    engine.output!.addError(LlamaInferenceException('Generation failed'));
    unawaited(engine.output!.close());
    await finishStream(tester);
    expect(find.text('Generation failed'), findsOneWidget);
    expect(find.text('Will fail'), findsNothing);
    expect(_send, findsOneWidget);
  });

  testWidgets('cancels generation before disposing the engine', (tester) async {
    await readyApp(tester);
    await send(tester, 'Hello');
    expect(engine.output!.hasListener, isTrue);

    await tester.pumpWidget(const SizedBox());
    await finishStream(tester);
    expect(engine.events, ['cancel', 'dispose']);
    expect(engine.output!.hasListener, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disposes an engine that arrives after unmounting', (
    tester,
  ) async {
    createFakeEngine();
    final created = Completer<LlamaEngine>();
    await tester.pumpWidget(GgufApp(createEngine: () => created.future));
    await tester.tap(find.text('Load'));
    await tester.pumpWidget(const SizedBox());

    created.complete(engine);
    await tester.pump();
    expect(engine.source, isNull);
    expect(engine.events, ['dispose']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('defaults to SmolLM2 135M and disables thinking mode', (
    tester,
  ) async {
    createFakeEngine();
    await tester.pumpWidget(GgufApp(createEngine: () async => engine));

    expect(find.text(_smolLmItem), findsOneWidget);
    expect(find.text('Load SmolLM2 135M to begin.'), findsOneWidget);

    await tester.tap(find.text('Load'));
    await tester.pump();
    expect(engine.source?.url, Uri.parse(_smolLmUrl));
    expect(engine.contextSize, 2048);
    expect(engine.modelBytesHint, kIsWeb ? 105454144 : null);

    engine.loaded.complete();
    await tester.pump();
    await send(tester, 'Hello');
    expect(engine.lastEnableThinking, isFalse);
    await finishTurn(tester, 'Hi!');
  });

  testWidgets('selecting another model passes its pinned URL and params', (
    tester,
  ) async {
    createFakeEngine();
    await tester.pumpWidget(GgufApp(createEngine: () async => engine));

    await tester.tap(find.text(_smolLmItem));
    await tester.pumpAndSettle();
    await tester.tap(find.text(_qwen35Item).last);
    await tester.pumpAndSettle();

    expect(find.text('Load Qwen3.5 0.8B to begin.'), findsOneWidget);
    await tester.tap(find.text('Load'));
    await tester.pump();

    expect(engine.source?.url, Uri.parse(_qwen35Url));
    expect(engine.contextSize, 2048);
    expect(engine.modelBytesHint, kIsWeb ? 532517120 : null);

    engine.loaded.complete();
    await tester.pump();
  });

  testWidgets(
    'selecting Gemma 4 E2B shows desktop Chrome ~3 GB label and warning before Load',
    (tester) async {
      createFakeEngine();
      await tester.pumpWidget(GgufApp(createEngine: () async => engine));

      await tester.tap(find.text(_smolLmItem));
      await tester.pumpAndSettle();
      await tester.tap(find.text(_gemma4Item).last);
      await tester.pumpAndSettle();

      expect(find.text(_gemma4Item), findsOneWidget);
      expect(find.textContaining('Large download (~3 GB)'), findsOneWidget);
      expect(find.textContaining('Use desktop Chrome'), findsOneWidget);
      expect(find.textContaining('Safari'), findsOneWidget);
      expect(engine.source, isNull);

      await tester.tap(find.text('Load'));
      await tester.pump();
      expect(engine.source?.url, Uri.parse(_gemma4Url));
      expect(engine.contextSize, 2048);
      expect(engine.modelBytesHint, kIsWeb ? 3043934304 : null);

      engine.loaded.complete();
      await tester.pump();
    },
  );

  testWidgets(
    'switching model while loaded disposes previous engine, clears chat, and requires Load',
    (tester) async {
      final engines = <_FakeEngine>[];
      await tester.pumpWidget(
        GgufApp(
          createEngine: () async {
            final created = _FakeEngine();
            engines.add(created);
            addTearDown(created.dispose);
            return created;
          },
        ),
      );

      await tester.tap(find.text('Load'));
      await tester.pump();
      engines[0].loaded.complete();
      await tester.pump();

      await tester.enterText(_prompt, 'Hello');
      await tester.pump();
      await tester.tap(_send);
      await tester.pump();
      engines[0].emit('Hi there');
      unawaited(engines[0].output!.close());
      await finishStream(tester);
      expect(find.text('Hello'), findsOneWidget);
      expect(find.text('Hi there'), findsOneWidget);

      await tester.ensureVisible(find.text(_smolLmItem));
      await tester.pump();
      await tester.tap(find.text(_smolLmItem));
      await tester.pumpAndSettle();
      await tester.tap(find.text(_qwen35Item).last);
      await tester.pumpAndSettle();

      expect(engines[0].events, contains('dispose'));
      expect(find.text('Hello'), findsNothing);
      expect(find.text('Hi there'), findsNothing);
      expect(find.text('Load Qwen3.5 0.8B to begin.'), findsOneWidget);
      expect(tester.widget<FilledButton>(_send).onPressed, isNull);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Load'))
            .onPressed,
        isNotNull,
      );
      expect(engines, hasLength(1));

      await tester.tap(find.text('Load'));
      await tester.pump();
      expect(engines, hasLength(2));
      expect(engines[1].source?.url, Uri.parse(_qwen35Url));

      engines[1].progress?.call(const ModelDownloadProgress.fraction(0.4));
      await tester.pump();
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        0.4,
      );

      engines[1].loaded.complete();
      await tester.pump();
    },
  );

  test('buildGgufModelParams passes modelBytesHint only on web', () {
    for (final model in ggufModels) {
      final webParams = buildGgufModelParams(model, isWeb: true);
      expect(webParams.contextSize, model.contextSize);
      expect(webParams.modelBytesHint, model.sizeBytes);
      expect(webParams.preferMemory64, isNull);

      final nativeParams = buildGgufModelParams(model, isWeb: false);
      expect(nativeParams.contextSize, model.contextSize);
      expect(nativeParams.modelBytesHint, isNull);
      expect(nativeParams.preferMemory64, isNull);
    }
  });

  testWidgets('picker is disabled during load and generation', (tester) async {
    createFakeEngine();
    await tester.pumpWidget(GgufApp(createEngine: () async => engine));

    DropdownButton<GgufModelOption> pickerWidget() =>
        tester.widget<DropdownButton<GgufModelOption>>(
          find.byType(DropdownButton<GgufModelOption>),
        );

    expect(pickerWidget().onChanged, isNotNull);

    await tester.tap(find.text('Load'));
    await tester.pump();
    expect(pickerWidget().onChanged, isNull);
    await tester.tap(find.text(_smolLmItem));
    await tester.pump();
    expect(find.text(_qwen35Item), findsNothing);

    engine.loaded.complete();
    await tester.pump();
    expect(pickerWidget().onChanged, isNotNull);

    await send(tester, 'Hello');
    expect(pickerWidget().onChanged, isNull);
    await tester.ensureVisible(find.text(_smolLmItem));
    await tester.pump();
    await tester.tap(find.text(_smolLmItem));
    await tester.pump();
    expect(find.text(_qwen35Item), findsNothing);

    await finishTurn(tester, 'Done');
    expect(pickerWidget().onChanged, isNotNull);
  });

  testWidgets(
    'recovers from non-LlamaException errors in load, send, token count, and dispose',
    (tester) async {
      await openApp(tester);
      engine.loaded.completeError(StateError('Wasm OOM'));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('Could not load SmolLM2 135M.'), findsOneWidget);
      expect(find.textContaining('Wasm OOM'), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Load'))
            .onPressed,
        isNotNull,
      );
      expect(
        tester
            .widget<DropdownButton<GgufModelOption>>(
              find.byType(DropdownButton<GgufModelOption>),
            )
            .onChanged,
        isNotNull,
      );

      engine.loaded = Completer<void>();
      await tester.tap(find.text('Load'));
      await tester.pump();
      engine.loaded.complete();
      await tester.pump();

      await send(tester, 'First');
      await finishTurn(tester, 'First reply');

      await send(tester, 'Boom');
      engine.output!.addError(StateError('Bridge panic'));
      unawaited(engine.output!.close());
      await finishStream(tester);

      expect(tester.takeException(), isNull);
      expect(find.text('Generation failed.'), findsOneWidget);
      expect(find.textContaining('Bridge panic'), findsNothing);
      expect(_stop, findsNothing);
      expect(_send, findsOneWidget);
      expect(
        tester
            .widget<DropdownButton<GgufModelOption>>(
              find.byType(DropdownButton<GgufModelOption>),
            )
            .onChanged,
        isNotNull,
      );
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Clear'))
            .onPressed,
        isNotNull,
      );
      expect(find.text('Boom'), findsNothing);
      expect(find.text('First reply'), findsOneWidget);

      engine.tokenCountError = StateError('tokenizer failed');
      await send(tester, 'Partial');
      engine.emit('Halfway');
      await tester.pump();
      await tester.tap(_stop);
      await finishStream(tester);

      expect(tester.takeException(), isNull);
      expect(find.text('Stopped.'), findsOneWidget);
      expect(find.text('Halfway'), findsOneWidget);
      expect(_send, findsOneWidget);
      expect(
        tester
            .widget<DropdownButton<GgufModelOption>>(
              find.byType(DropdownButton<GgufModelOption>),
            )
            .onChanged,
        isNotNull,
      );
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Clear'))
            .onPressed,
        isNotNull,
      );

      engine.disposeError = StateError('dispose failed');
      await tester.ensureVisible(find.text(_smolLmItem));
      await tester.pump();
      await tester.tap(find.text(_smolLmItem));
      await tester.pumpAndSettle();
      await tester.tap(find.text(_qwen35Item).last);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(
        tester
            .widget<DropdownButton<GgufModelOption>>(
              find.byType(DropdownButton<GgufModelOption>),
            )
            .onChanged,
        isNotNull,
      );
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Load'))
            .onPressed,
        isNotNull,
      );
      expect(
        find.textContaining('Load Qwen3.5 0.8B to begin.'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'renders narrow viewport cleanly with updated Gemma warning hidden after Load',
    (tester) async {
      tester.view.physicalSize = const Size(320, 480);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      createFakeEngine();
      await tester.pumpWidget(GgufApp(createEngine: () async => engine));

      expect(
        tester
            .widgetList<ConstrainedBox>(find.byType(ConstrainedBox))
            .any((box) => box.constraints.maxWidth == 640),
        isTrue,
      );

      final dropdown = tester.widget<DropdownButton<GgufModelOption>>(
        find.byType(DropdownButton<GgufModelOption>),
      );
      for (final item in dropdown.items!) {
        final label = item.child as Text;
        expect(label.maxLines, 1);
        expect(label.overflow, TextOverflow.ellipsis);
      }

      await tester.tap(find.text(_smolLmItem));
      await tester.pumpAndSettle();
      await tester.tap(find.text(_gemma4Item).last);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.textContaining('Large download (~3 GB)'), findsOneWidget);
      expect(find.textContaining('~4–6 GiB peak browser RSS'), findsOneWidget);
      expect(find.textContaining('~3.5 GiB steady'), findsOneWidget);
      expect(
        find.textContaining('Chrome 158 on Apple silicon macOS'),
        findsOneWidget,
      );

      final warningText = find.textContaining('Large download (~3 GB)');
      final warningContext = tester.element(warningText);
      final warningBox = tester.widget<DecoratedBox>(
        find
            .ancestor(of: warningText, matching: find.byType(DecoratedBox))
            .first,
      );
      expect(
        (warningBox.decoration as BoxDecoration).color,
        Theme.of(warningContext).colorScheme.tertiaryContainer,
      );

      await tester.ensureVisible(find.text('Load'));
      await tester.tap(find.text('Load'));
      await tester.pump();
      engine.loaded.complete();
      await tester.pump();

      expect(find.textContaining('~4–6 GiB peak browser RSS'), findsNothing);

      await tester.ensureVisible(_prompt);
      await send(tester, 'Hi');
      await finishTurn(tester, 'Hello');

      final expectedUserColor = Theme.of(tester.element(find.text('Hi')))
          .colorScheme
          .onPrimaryContainer;
      expect(
        tester.widget<Text>(find.text('You')).style?.color,
        expectedUserColor,
      );
      expect(
        tester.widget<Text>(find.text('Hi')).style?.color,
        expectedUserColor,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'formats download progress with percent and MB/GB then switches to Initializing',
    (tester) async {
      final engines = <_FakeEngine>[];
      await tester.pumpWidget(
        GgufApp(
          createEngine: () async {
            final created = _FakeEngine();
            engines.add(created);
            addTearDown(created.dispose);
            return created;
          },
        ),
      );

      await tester.tap(find.text('Load'));
      await tester.pump();

      engines[0].progress?.call(const ModelDownloadProgress.fraction(0.5));
      await tester.pump();
      expect(
        find.text('Downloading SmolLM2 135M… 50% (~53 / 105 MB)'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        0.5,
      );

      engines[0].progress?.call(const ModelDownloadProgress.fraction(0.504));
      await tester.pump();
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        0.5,
      );

      engines[0].progress?.call(const ModelDownloadProgress.fraction(1.0));
      await tester.pump();
      expect(find.text('Initializing SmolLM2 135M…'), findsOneWidget);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        1.0,
      );

      engines[0].loaded.complete();
      await tester.pump();
      expect(find.text('Model ready.'), findsOneWidget);

      await tester.tap(find.text(_smolLmItem));
      await tester.pumpAndSettle();
      await tester.tap(find.text(_gemma4Item).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Load'));
      await tester.pump();

      engines[1].progress?.call(const ModelDownloadProgress.fraction(0.42));
      await tester.pump();
      expect(
        find.text('Downloading Gemma 4 E2B… 42% (~1.3 / 3.0 GB)'),
        findsOneWidget,
      );

      engines[1].progress?.call(
        const ModelDownloadProgress(
          receivedBytes: 1500000000,
          totalBytes: 3000000000,
        ),
      );
      await tester.pump();
      expect(
        find.text('Downloading Gemma 4 E2B… 50% (1.5 / 3.0 GB)'),
        findsOneWidget,
      );

      engines[1].loaded.complete();
      await tester.pump();
    },
  );

  testWidgets(
    'streaming does not rebuild completed bubbles and disables settings while busy',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        createFakeEngine();
        await tester.pumpWidget(GgufApp(createEngine: () async => engine));
        await tester.tap(find.text('Settings'));
        await tester.pumpAndSettle();

        expect(
          tester.getSemantics(find.byType(Slider).at(0)).label,
          contains('Temperature'),
        );
        expect(
          tester.getSemantics(find.byType(Slider).at(1)).label,
          contains('Max tokens'),
        );

        await tester.tap(find.text('Load'));
        await tester.pump();
        expect(
          tester.widget<Slider>(find.byType(Slider).at(0)).onChanged,
          isNull,
        );
        expect(
          tester.widget<Slider>(find.byType(Slider).at(1)).onChanged,
          isNull,
        );
        expect(
          tester
              .widget<TextFormField>(
                find.widgetWithText(TextFormField, 'System prompt'),
              )
              .enabled,
          isFalse,
        );

        engine.loaded.complete();
        await tester.pump();
        expect(
          tester.widget<Slider>(find.byType(Slider).at(0)).onChanged,
          isNotNull,
        );
        expect(
          tester.widget<Slider>(find.byType(Slider).at(1)).onChanged,
          isNotNull,
        );
        expect(
          tester
              .widget<TextFormField>(
                find.widgetWithText(TextFormField, 'System prompt'),
              )
              .enabled,
          isTrue,
        );

        await send(tester, 'First');
        await finishTurn(tester, 'First answer');
        expect(find.byType(SelectionArea), findsOneWidget);
        expect(find.byType(SelectableText), findsNothing);

        final completedBeforePrompt = tester.widget<Text>(
          find.text('First answer'),
        );
        await tester.enterText(
          find.widgetWithText(TextFormField, 'System prompt'),
          'Be brief.',
        );
        await tester.pump();
        expect(
          identical(
            completedBeforePrompt,
            tester.widget<Text>(find.text('First answer')),
          ),
          isTrue,
        );

        await send(tester, 'Second');
        expect(
          tester.widget<Slider>(find.byType(Slider).at(0)).onChanged,
          isNull,
        );
        expect(
          tester.widget<Slider>(find.byType(Slider).at(1)).onChanged,
          isNull,
        );
        expect(
          tester
              .widget<TextFormField>(
                find.widgetWithText(TextFormField, 'System prompt'),
              )
              .enabled,
          isFalse,
        );

        final completedDuringStream = tester.widget<Text>(
          find.text('First answer'),
        );
        engine.emit('Part 1');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        engine.emit(' Part 2');
        await tester.pump();

        expect(find.text('Part 1 Part 2'), findsOneWidget);
        expect(
          identical(
            completedDuringStream,
            tester.widget<Text>(find.text('First answer')),
          ),
          isTrue,
        );

        unawaited(engine.output!.close());
        await finishStream(tester);
        expect(
          tester.widget<Slider>(find.byType(Slider).at(0)).onChanged,
          isNotNull,
        );
        expect(
          tester.widget<Slider>(find.byType(Slider).at(1)).onChanged,
          isNotNull,
        );
        expect(
          tester
              .widget<TextFormField>(
                find.widgetWithText(TextFormField, 'System prompt'),
              )
              .enabled,
          isTrue,
        );
      } finally {
        semantics.dispose();
      }
    },
  );
}

class _FakeBackend extends Fake implements LlamaBackend {
  @override
  void cancelGeneration() {}
}

class _FakeEngine extends LlamaEngine {
  _FakeEngine() : super(_FakeBackend());

  final events = <String>[];
  Completer<void> loaded = Completer<void>();
  ModelDownloadProgressCallback? progress;
  ModelSource? source;
  int? contextSize;
  int? modelBytesHint;
  StreamController<LlamaCompletionChunk>? output;
  List<(LlamaChatRole, String)>? lastMessages;
  GenerationParams? lastParams;
  bool? lastEnableThinking;
  String? flushOnCancel;
  bool holdAfterCancel = false;
  String? countedText;
  Object? disposeError;
  Object? tokenCountError;

  void emit(String text, {String? thinking, LlamaGenerationUsage? usage}) {
    output!.add(
      LlamaCompletionChunk(
        id: 'test',
        object: 'chat.completion.chunk',
        created: 0,
        model: 'test',
        choices: [
          LlamaCompletionChunkChoice(
            index: 0,
            delta: LlamaCompletionChunkDelta(content: text, thinking: thinking),
          ),
        ],
        usage: usage,
      ),
    );
  }

  @override
  Future<void> setModel(
    LlamaModel model, {
    ModelParams params = const ModelParams(),
    ModelLoadOptions download = ModelLoadOptions.defaults,
    ModelDownloadProgressCallback? onProgress,
  }) {
    source = model.source;
    contextSize = params.contextSize;
    modelBytesHint = params.modelBytesHint;
    progress = onProgress;
    return loaded.future;
  }

  @override
  Future<LlamaChatTemplateResult> chatTemplate(
    List<LlamaChatMessage> messages, {
    bool addAssistant = true,
    Map<String, dynamic>? jsonSchema,
    List<ToolDefinition>? tools,
    ToolChoice toolChoice = ToolChoice.auto,
    bool parallelToolCalls = false,
    bool enableThinking = true,
    Map<String, dynamic>? responseFormat,
    String? customTemplate,
    String? sourceLangCode,
    String? targetLangCode,
    bool includeTokenCount = true,
    Map<String, dynamic>? chatTemplateKwargs,
    DateTime? templateNow,
  }) async => const LlamaChatTemplateResult(prompt: '', tokenCount: 10);

  @override
  Stream<LlamaCompletionChunk> create(
    List<LlamaChatMessage> messages, {
    GenerationParams? params,
    List<ToolDefinition>? tools,
    ToolChoice? toolChoice,
    bool parallelToolCalls = false,
    bool enableThinking = true,
    Map<String, dynamic>? responseFormat,
    String? sourceLangCode,
    String? targetLangCode,
    Map<String, dynamic>? chatTemplateKwargs,
    DateTime? templateNow,
  }) {
    lastMessages = messages.map((m) => (m.role, m.content)).toList();
    lastParams = params;
    lastEnableThinking = enableThinking;
    output = StreamController<LlamaCompletionChunk>.broadcast();
    return output!.stream;
  }

  @override
  Future<String> getBackendName() async => 'WebGPU';

  @override
  Future<int> getTokenCount(String text) async {
    countedText = text;
    if (tokenCountError != null) throw tokenCountError!;
    return 4;
  }

  @override
  void cancelGeneration() {
    events.add('cancel');
    super.cancelGeneration();
    final stream = output;
    if (stream == null || stream.isClosed) return;
    final flush = flushOnCancel;
    flushOnCancel = null;
    if (flush != null) emit(flush);
    if (!holdAfterCancel) unawaited(stream.close());
  }

  @override
  Future<void> dispose() async {
    if (events.contains('dispose')) return;
    events.add('dispose');
    unawaited(output?.close());
    if (disposeError != null) throw disposeError!;
  }
}
