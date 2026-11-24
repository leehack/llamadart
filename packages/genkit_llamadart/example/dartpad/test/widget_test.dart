@TestOn('vm')
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:genkit/genkit.dart';
import 'package:genkit/plugin.dart';
import 'package:genkit_llamadart/genkit_llamadart.dart';
import 'package:genkit_llamadart_dartpad_example/main.dart';
import 'package:genkit_llamadart_dartpad_example/playground_controller.dart';
import 'package:genkit_llamadart_dartpad_example/playground_widgets.dart';
import 'package:llamadart/llamadart.dart' as llama;
import 'package:material_ui/material_ui.dart' hide Action;

void main() {
  for (final label in ['GGUF', 'LiteRT-LM']) {
    testWidgets('$label sends history when supported and Clear resets it', (
      tester,
    ) async {
      final runtime = _LocalRuntime(supportsMultiTurn: true);
      await _openLocal(tester, label, runtime);
      final suffix = label == 'LiteRT-LM' ? '\n/no_think' : '';

      await _send(tester, 'Hello');
      await _reply(tester, runtime, 'Hi there');
      await _send(tester, 'Follow up');

      final second = runtime.history.last;
      expect(second.map((message) => message.role), [
        llama.LlamaChatRole.system,
        llama.LlamaChatRole.user,
        llama.LlamaChatRole.assistant,
        llama.LlamaChatRole.user,
      ]);
      expect(second.skip(1).map((message) => message.content), [
        'Hello',
        'Hi there',
        'Follow up$suffix',
      ]);
      await _reply(tester, runtime, 'Second reply');
      for (final text in ['Hello', 'Hi there', 'Follow up', 'Second reply']) {
        expect(find.text(text), findsWidgets);
      }

      await _tap(tester, 'Clear');
      expect(find.text('Hi there'), findsNothing);
      await _send(tester, 'Fresh start');
      expect(runtime.history.last.map((message) => message.role), [
        llama.LlamaChatRole.system,
        llama.LlamaChatRole.user,
      ]);
      expect(runtime.prompt, 'Fresh start$suffix');
      await _reply(tester, runtime, 'Starting fresh');
    });

    testWidgets('$label forwards generation settings', (tester) async {
      final runtime = _LocalRuntime(supportsMultiTurn: label == 'GGUF');
      await _openLocal(tester, label, runtime);
      await _tap(tester, 'Settings');
      await _setSlider(tester, 0, 0.2);
      await _setSlider(tester, 1, 128);

      final system = find.widgetWithText(TextField, 'System prompt');
      if (label == 'GGUF') {
        await tester.enterText(system, 'Reply like a pirate.');
      } else {
        expect(tester.widget<TextField>(system).enabled, isFalse);
      }
      await _send(tester, 'Hello');

      expect(runtime.params.last!.temp, closeTo(0.2, 0.001));
      expect(runtime.params.last!.maxTokens, 128);
      if (label == 'GGUF') {
        expect(runtime.history.last.first.role, llama.LlamaChatRole.system);
        expect(runtime.history.last.first.content, 'Reply like a pirate.');
      } else {
        expect(runtime.history.last.single.content, 'Hello\n/no_think');
      }
      await _reply(tester, runtime, 'Ahoy');
    });
  }

  testWidgets(
    'single-turn LiteRT-LM displays a transcript and sends one prompt',
    (tester) async {
      final runtime = _LocalRuntime(backendName: 'LiteRT-LM Web GPU');
      await _openLocal(tester, 'LiteRT-LM', runtime);
      expect(
        find.textContaining('This runtime runs single-turn only'),
        findsOneWidget,
      );
      await _tap(tester, 'Settings');
      expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, 'System prompt'))
            .enabled,
        isFalse,
      );
      await _tap(tester, 'Settings');

      await _send(tester, 'Hello');
      await _reply(tester, runtime, 'Hi there');
      expect(find.textContaining('LiteRT-LM Web GPU · '), findsOneWidget);
      expect(find.textContaining(RegExp(r'\d+\.\ds$')), findsOneWidget);
      expect(find.textContaining(' tok'), findsNothing);

      await _send(tester, 'Follow up');
      expect(runtime.history.last.single.content, 'Follow up\n/no_think');
      expect(find.text('Hi there'), findsOneWidget);
      await _reply(tester, runtime, 'Second reply');
    },
  );

  testWidgets('stats show live elapsed time and reported tokens', (
    tester,
  ) async {
    final runtime = _LocalRuntime(backendName: 'WebGPU');
    await _openLocal(tester, 'GGUF', runtime);
    await _send(tester, 'Hello');
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.textContaining(RegExp(r'WebGPU · \d+\.\ds$')), findsOneWidget);
    expect(find.textContaining(' tok'), findsNothing);

    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await _reply(
      tester,
      runtime,
      'Hi there',
      usage: const llama.LlamaGenerationUsage(
        promptTokens: 10,
        completionTokens: 20,
        duration: Duration(seconds: 2),
      ),
    );
    expect(find.textContaining('WebGPU · 20 tok · '), findsOneWidget);
    expect(find.textContaining('tok/s'), findsOneWidget);
    await _tap(tester, 'Clear');
    expect(find.text('WebGPU'), findsOneWidget);
    expect(find.textContaining(' tok'), findsNothing);
  });

  testWidgets('a preset fills and focuses the empty composer', (tester) async {
    await _openLocal(tester, 'GGUF', _LocalRuntime());
    final prompt = find.widgetWithText(TextField, 'Prompt');
    await tester.enterText(prompt, '');
    await tester.pump();
    final send = find.widgetWithText(FilledButton, 'Send');
    expect(tester.widget<FilledButton>(send).onPressed, isNull);

    await _tap(tester, 'Summarize');
    expect(
      tester.widget<TextField>(prompt).controller!.text,
      'Summarize how WebGPU speeds up browser AI in 3 short bullet points.',
    );
    expect(tester.widget<TextField>(prompt).focusNode!.hasFocus, isTrue);
    expect(tester.widget<FilledButton>(send).onPressed, isNotNull);
  });

  testWidgets('Gemini catches transport setup faults before Genkit', (
    tester,
  ) async {
    final plugin = _GeminiPlugin();
    await _connectGemini(tester, plugin);
    final generate = tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, 'Send'))
        .onPressed!;
    // runWithClient forks an HTTP zone before it calls Genkit.
    runZoned(
      generate,
      zoneSpecification: ZoneSpecification(
        fork: (self, parent, zone, specification, values) =>
            throw StateError('Transport setup contains $_fakeKey'),
      ),
    );
    await tester.pumpAndSettle();

    expect(plugin.requests, isEmpty);
    expect(find.text('Assistant'), findsNothing);
    expect(
      find.text('Gemini request failed. Check your API key and connection.'),
      findsOneWidget,
    );
    expect(find.textContaining(_fakeKey), findsNothing);
    expect(find.text('Done.'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final label in ['GGUF', 'LiteRT-LM']) {
    testWidgets('$label loads, streams, stops and disposes', (tester) async {
      final runtime = _LocalRuntime();
      await _openLocal(tester, label, runtime);

      expect(
        runtime.definition?.modelPath,
        endsWith(label == 'GGUF' ? '.gguf' : '.litertlm'),
      );
      expect(
        runtime.definition!.modelParams.contextSize,
        label == 'GGUF' ? 2048 : 1024,
      );
      expect(find.text('Model ready (CPU).'), findsOneWidget);

      await _tap(tester, 'Send');
      expect(runtime.enableThinking, label == 'LiteRT-LM');
      expect(
        runtime.prompt,
        label == 'LiteRT-LM'
            ? 'Tell me a story about a fox.\n/no_think'
            : 'Tell me a story about a fox.',
      );
      runtime.chunks.add(_chunk('A fox'));
      await tester.pumpAndSettle();
      expect(find.text('A fox'), findsOneWidget);

      await _tap(tester, 'Stop');
      expect(runtime.canceled, isTrue);
      expect(find.text('Send'), findsOneWidget);
      expect(find.text('Stopped.'), findsOneWidget);
      expect(find.text('A fox'), findsOneWidget);

      runtime.chunks.add(_chunk(' late'));
      unawaited(runtime.chunks.close());
      await tester.pumpAndSettle();
      expect(find.text('A fox'), findsOneWidget);
      expect(find.textContaining(' late'), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(runtime.disposed, isTrue);
    });

    testWidgets('$label shows load and generation errors', (tester) async {
      final runtime = _LocalRuntime()..failLoad = true;
      await _openLocal(tester, label, runtime);
      expect(find.text('The model download failed.'), findsOneWidget);
      expect(runtime.disposed, isTrue);

      await tester.pumpWidget(const SizedBox());
      final failingRuntime = _LocalRuntime();
      await _openLocal(tester, label, failingRuntime);
      await _tap(tester, 'Send');
      failingRuntime.chunks.addError(
        llama.LlamaStateException('The runtime could not decode.'),
      );
      await failingRuntime.chunks.close();
      await tester.pumpAndSettle();
      expect(
        find.textContaining('The runtime could not decode.'),
        findsOneWidget,
      );
      expect(find.text('Done.'), findsNothing);
    });
  }

  testWidgets('switching providers releases the runtime and clears the chat', (
    tester,
  ) async {
    final runtime = _LocalRuntime(backendName: 'WebGPU, CPU');
    await _openLocal(tester, 'GGUF', runtime);
    expect(find.text('Model ready (GGUF).'), findsOneWidget);
    await _send(tester, 'Hello');
    await _reply(tester, runtime, 'Hi there');
    await _tap(tester, 'Gemini');
    expect(runtime.disposed, isTrue);
    expect(find.text('Hi there'), findsNothing);
    expect(find.text('Enter a Gemini API key to connect.'), findsOneWidget);
  });

  testWidgets('a model finishing its load after unmount is disposed', (
    tester,
  ) async {
    final loading = Completer<void>();
    final runtime = _LocalRuntime()..loading = loading.future;
    await tester.pumpWidget(_localApp(runtime));
    await tester.tap(find.text('Load'));
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    loading.complete();
    await tester.pumpAndSettle();
    expect(runtime.disposed, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Gemini connects, streams, stops and cancels on dispose', (
    tester,
  ) async {
    final plugin = _GeminiPlugin();
    await _connectGemini(tester, plugin);
    expect(find.text('Gemini ready. Send to verify your key.'), findsOneWidget);

    await _tap(tester, 'Send');
    expect(find.text('A cloud fox'), findsOneWidget);
    expect(
      plugin.requests.single.toJson().toString(),
      isNot(contains(_fakeKey)),
    );
    await _tap(tester, 'Stop');
    expect(plugin.cancellations, 1);
    expect(find.text('Stopped.'), findsOneWidget);
    expect(find.text('A cloud fox'), findsOneWidget);

    await _send(tester, 'Follow up');
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(plugin.cancellations, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Stop releases the UI while Gemini is silent', (tester) async {
    final finish = Completer<void>();
    addTearDown(() {
      if (!finish.isCompleted) finish.complete();
    });
    final plugin = _GeminiPlugin()..finishFirstRequest = finish.future;
    await _connectGemini(tester, plugin);

    await _tap(tester, 'Send');
    expect(find.text('A cloud fox'), findsOneWidget);
    await _tap(tester, 'Stop');
    expect(plugin.cancellations, 1);
    expect(find.text('Stopped.'), findsOneWidget);
    expect(find.text('A cloud fox'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, 'Prompt'),
      'Follow up',
    );
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Send'))
          .onPressed,
      isNotNull,
    );
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'GGUF'))
          .enabled,
      isTrue,
    );

    await _tap(tester, 'Send');
    expect(plugin.requests, hasLength(2));
    expect(plugin.requests.last.messages.map((message) => message.role), [
      Role.system,
      Role.user,
      Role.model,
      Role.user,
    ]);
    expect(plugin.requests.last.messages[2].content.single.text, 'A cloud fox');
    finish.complete();
    await tester.pumpAndSettle();
    expect(find.text('Stop'), findsOneWidget);
    expect(find.text('Generating…'), findsOneWidget);
    expect(find.text('A cloud fox'), findsNWidgets(2));
    expect(find.textContaining(' late'), findsNothing);

    await _tap(tester, 'Stop');
    await _tap(tester, 'GGUF');
    expect(find.text('Load SmolLM2 135M to begin.'), findsOneWidget);
  });

  testWidgets('Gemini errors never surface provider data or the API key', (
    tester,
  ) async {
    final plugin = _GeminiPlugin()..fail = true;
    await _connectGemini(tester, plugin);
    await _tap(tester, 'Send');
    expect(
      find.text('Gemini request failed. Check your API key and connection.'),
      findsOneWidget,
    );
    expect(find.textContaining(_fakeKey), findsNothing);
    expect(
      plugin.requests.single.toJson().toString(),
      isNot(contains(_fakeKey)),
    );
    expect(tester.takeException(), isNull);
  });

  test(
    'buildGgufModelParams sets modelBytesHint on Web and omits it natively',
    () {
      expect(ggufModels.map((model) => model.id), [
        'smollm2-135m',
        'qwen3.5-0.8b',
        'gemma-4-e2b',
      ]);
      for (final model in ggufModels) {
        final webParams = buildGgufModelParams(model, isWeb: true);
        expect(webParams.contextSize, 2048);
        expect(webParams.modelBytesHint, model.sizeBytes);
        expect(webParams.preferMemory64, isNull);

        final nativeParams = buildGgufModelParams(model, isWeb: false);
        expect(nativeParams.contextSize, 2048);
        expect(nativeParams.modelBytesHint, isNull);
        expect(nativeParams.preferMemory64, isNull);
      }
    },
  );

  test('LiteRT-LM models keep Qwen3 first and omit GGUF-only hints', () {
    expect(liteRtLmModels.map((model) => model.id), [
      'qwen3-0.6b',
      'gemma-4-e2b-litert',
    ]);
    for (final model in liteRtLmModels) {
      final params = buildLiteRtLmModelParams(model);
      expect(params.contextSize, 1024);
      expect(params.modelBytesHint, isNull);
      expect(params.preferMemory64, isNull);
      expect(params.jsBackedModelStaging, isNull);
    }
  });

  testWidgets(
    'default GGUF model is SmolLM2 135M with pinned URL and thinking off',
    (tester) async {
      final runtime = _LocalRuntime();
      await tester.pumpWidget(_localApp(runtime));

      expect(find.text('SmolLM2 135M (~105 MB)'), findsOneWidget);
      expect(
        find.text('Fastest download; good for quick tests.'),
        findsOneWidget,
      );
      expect(find.textContaining('Requires desktop Chrome'), findsNothing);

      await _tap(tester, 'Load');
      expect(runtime.definition?.name, 'smollm2-135m');
      expect(
        runtime.definition?.modelPath,
        'https://huggingface.co/unsloth/SmolLM2-135M-Instruct-GGUF/resolve/'
        '9e6855bc4be717fca1ef21360a1db4b29d5c559a/'
        'SmolLM2-135M-Instruct-Q4_K_M.gguf',
      );
      expect(runtime.definition?.modelParams.contextSize, 2048);

      await _tap(tester, 'Send');
      expect(runtime.enableThinking, isFalse);
      await _reply(tester, runtime, 'A fox');
    },
  );

  testWidgets(
    'selecting Qwen3.5 0.8B updates status and loads pinned URL with thinking off',
    (tester) async {
      final runtime = _LocalRuntime();
      await tester.pumpWidget(_localApp(runtime));

      await _selectLocalModel(tester, 'Qwen3.5 0.8B (~533 MB)');
      expect(runtime.definition, isNull);
      expect(find.text('Load Qwen3.5 0.8B to begin.'), findsOneWidget);
      expect(
        find.text('Stronger responses; thinking disabled for quick replies.'),
        findsOneWidget,
      );
      expect(find.textContaining('Requires desktop Chrome'), findsNothing);

      await _tap(tester, 'Load');
      expect(runtime.definition?.name, 'qwen3.5-0.8b');
      expect(
        runtime.definition?.modelPath,
        'https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/resolve/'
        '6ab461498e2023f6e3c1baea90a8f0fe38ab64d0/'
        'Qwen3.5-0.8B-Q4_K_M.gguf',
      );
      expect(runtime.definition?.modelParams.contextSize, 2048);

      await _tap(tester, 'Send');
      expect(runtime.enableThinking, isFalse);
      await _reply(tester, runtime, 'A fox');
    },
  );

  testWidgets(
    'selecting Gemma 4 E2B shows pre-download warning before Load and loads pinned URL',
    (tester) async {
      final runtime = _LocalRuntime();
      await tester.pumpWidget(_localApp(runtime));

      await _selectLocalModel(tester, 'Gemma 4 E2B (desktop Chrome, ~3 GB)');
      expect(runtime.definition, isNull);
      expect(find.text('Load Gemma 4 E2B to begin.'), findsOneWidget);
      expect(
        find.textContaining(
          'Desktop Chrome with WebAssembly memory64 is required',
        ),
        findsOneWidget,
      );

      await _tap(tester, 'Load');
      expect(runtime.definition?.name, 'gemma-4-e2b');
      expect(
        runtime.definition?.modelPath,
        'https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/'
        '0314792d7f1f7e229411f620751375812bb9faf2/'
        'gemma-4-E2B-it-Q4_K_S.gguf',
      );
      expect(runtime.definition?.modelParams.contextSize, 2048);
      expect(
        find.textContaining('Requires desktop Chrome with WebAssembly'),
        findsNothing,
      );

      await _tap(tester, 'Send');
      expect(runtime.enableThinking, isFalse);
      await _reply(tester, runtime, 'A fox');
    },
  );

  testWidgets(
    'switching GGUF model while loaded disposes runtime, clears chat, and waits for Load',
    (tester) async {
      final runtimes = <_LocalRuntime>[];
      await tester.pumpWidget(
        GenkitDartPadApp(
          bootstrapGguf: () async {},
          bootstrapLiteRt: () async {},
          runtimeFactory: () {
            final runtime = _LocalRuntime(supportsMultiTurn: true);
            runtimes.add(runtime);
            return runtime;
          },
        ),
      );

      await _tap(tester, 'Load');
      expect(runtimes, hasLength(1));
      expect(find.byType(DropdownButton<LocalModelOption>), findsOneWidget);

      await _send(tester, 'Hello');
      await _reply(tester, runtimes[0], 'Hi there');
      expect(find.text('Hi there'), findsOneWidget);

      await _selectLocalModel(tester, 'Qwen3.5 0.8B (~533 MB)');
      expect(runtimes[0].disposed, isTrue);
      expect(find.text('Hi there'), findsNothing);
      expect(runtimes, hasLength(1));
      expect(find.text('Load Qwen3.5 0.8B to begin.'), findsOneWidget);
      final loadButton = find.widgetWithText(OutlinedButton, 'Load');
      expect(loadButton, findsOneWidget);
      expect(tester.widget<OutlinedButton>(loadButton).onPressed, isNotNull);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Send'))
            .onPressed,
        isNull,
      );

      await _tap(tester, 'Load');
      expect(runtimes, hasLength(2));
      expect(
        runtimes[1].definition?.modelPath,
        'https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/resolve/'
        '6ab461498e2023f6e3c1baea90a8f0fe38ab64d0/'
        'Qwen3.5-0.8B-Q4_K_M.gguf',
      );
    },
  );

  testWidgets('each local provider shows its model picker', (tester) async {
    await tester.pumpWidget(_localApp(_LocalRuntime()));
    expect(find.byType(DropdownButton<LocalModelOption>), findsOneWidget);
    expect(find.text('GGUF model'), findsOneWidget);

    await _tap(tester, 'LiteRT-LM');
    expect(find.byType(DropdownButton<LocalModelOption>), findsOneWidget);
    expect(find.text('LiteRT-LM model'), findsOneWidget);
    expect(find.text('GGUF model'), findsNothing);

    await _tap(tester, 'Gemini');
    expect(find.byType(DropdownButton<LocalModelOption>), findsNothing);

    await _tap(tester, 'GGUF');
    expect(find.byType(DropdownButton<LocalModelOption>), findsOneWidget);
  });

  for (final provider in ['GGUF', 'LiteRT-LM']) {
    testWidgets('$provider picker is disabled during load and generation', (
      tester,
    ) async {
      final loading = Completer<void>();
      final runtime = _LocalRuntime()..loading = loading.future;
      await tester.pumpWidget(_localApp(runtime));
      if (provider == 'LiteRT-LM') await _tap(tester, provider);

      DropdownButton<LocalModelOption> picker() =>
          tester.widget<DropdownButton<LocalModelOption>>(
            find.byType(DropdownButton<LocalModelOption>),
          );

      expect(picker().onChanged, isNotNull);

      await tester.tap(find.text('Load'));
      await tester.pump();
      expect(picker().onChanged, isNull);

      loading.complete();
      await tester.pumpAndSettle();
      expect(picker().onChanged, isNotNull);

      await tester.tap(find.text('Send'));
      await tester.pump();
      expect(picker().onChanged, isNull);

      await _reply(tester, runtime, 'A fox');
      expect(picker().onChanged, isNotNull);
    });
  }

  testWidgets('LiteRT-LM defaults to pinned Qwen3 0.6B with a prompt suffix', (
    tester,
  ) async {
    final runtime = _LocalRuntime();
    await tester.pumpWidget(_localApp(runtime));
    await _tap(tester, 'LiteRT-LM');

    expect(find.text('Qwen3 0.6B (~343 MB)'), findsOneWidget);
    expect(find.text('Load Qwen3 0.6B to begin.'), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
    await _tap(tester, 'Load');
    expect(runtime.definition?.name, 'qwen3-0.6b');
    expect(
      runtime.definition?.modelPath,
      'https://huggingface.co/litert-community/Qwen3-0.6B/resolve/'
      '8d42ab5f1db14cad987fac57aeb17d070f9e180d/'
      'Qwen3-0.6B_dynamic_wi4b32_afp32.litertlm',
    );
    expect(runtime.definition?.modelParams.contextSize, 1024);
    expect(runtime.definition?.modelParams.modelBytesHint, isNull);

    await _send(tester, 'Hello');
    expect(runtime.prompt, 'Hello\n/no_think');
    expect(runtime.enableThinking, isTrue);
    await _reply(tester, runtime, 'Hi');
  });

  testWidgets(
    'LiteRT-LM Gemma 4 E2B warns before loading and sends the plain prompt',
    (tester) async {
      final loading = Completer<void>();
      final runtime = _LocalRuntime()..loading = loading.future;
      await tester.pumpWidget(_localApp(runtime));
      await _tap(tester, 'LiteRT-LM');
      await _selectLocalModel(tester, 'Gemma 4 E2B (desktop Chrome, ~2 GB)');

      expect(runtime.definition, isNull);
      expect(find.text('Load Gemma 4 E2B to begin.'), findsOneWidget);
      expect(find.textContaining('Large download (~2 GB'), findsOneWidget);
      expect(find.textContaining('~3 GB peak Chrome memory'), findsOneWidget);
      expect(find.textContaining('re-downloads the file'), findsOneWidget);
      expect(find.textContaining('Requires WebGPU on desktop'), findsOneWidget);

      await tester.tap(find.text('Load'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('Loading Gemma 4 E2B… 2s'), findsOneWidget);
      loading.complete();
      await tester.pumpAndSettle();
      expect(runtime.definition?.name, 'gemma-4-e2b-litert');
      expect(
        runtime.definition?.modelPath,
        'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/'
        '2e12bfd869b2962984f97a1f2a26807316d534cc/'
        'gemma-4-E2B-it-web.litertlm',
      );
      expect(runtime.definition?.modelParams.contextSize, 1024);
      expect(runtime.definition?.modelParams.modelBytesHint, isNull);
      expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);

      await _send(tester, 'Hello');
      expect(runtime.prompt, 'Hello');
      expect(runtime.enableThinking, isTrue);
      await _reply(tester, runtime, 'Hi');
    },
  );

  testWidgets(
    'switching loaded LiteRT-LM to Gemma disposes and waits for Load',
    (tester) async {
      final runtimes = <_LocalRuntime>[];
      await tester.pumpWidget(
        GenkitDartPadApp(
          bootstrapLiteRt: () async {},
          runtimeFactory: () {
            final runtime = _LocalRuntime(backendName: 'LiteRT-LM Web GPU');
            runtimes.add(runtime);
            return runtime;
          },
        ),
      );
      await _tap(tester, 'LiteRT-LM');
      await _tap(tester, 'Load');
      await _send(tester, 'First question');
      await _reply(tester, runtimes.single, 'First answer');
      expect(find.text('First answer'), findsOneWidget);
      expect(find.text(singleTurnNotice), findsOneWidget);
      expect(find.textContaining('LiteRT-LM Web GPU ·'), findsOneWidget);

      await _selectLocalModel(tester, 'Gemma 4 E2B (desktop Chrome, ~2 GB)');
      expect(runtimes.single.disposed, isTrue);
      expect(find.text('First question'), findsNothing);
      expect(find.text('First answer'), findsNothing);
      expect(find.text(singleTurnNotice), findsNothing);
      expect(find.textContaining('LiteRT-LM Web GPU'), findsNothing);
      expect(find.text('Load Gemma 4 E2B to begin.'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Send'))
            .onPressed,
        isNull,
      );

      await _tap(tester, 'Load');
      expect(runtimes, hasLength(2));
      expect(find.text(singleTurnNotice), findsOneWidget);
      final gemma = runtimes.last;
      expect(gemma.definition?.modelPath, liteRtLmModels.last.url);
      await _send(tester, 'Next question');
      expect(gemma.prompt, 'Next question');
      expect(gemma.enableThinking, isTrue);
      expect(gemma.history.single, hasLength(1));
      await _reply(tester, gemma, 'Next answer');
    },
  );

  testWidgets('unloaded LiteRT-LM selection survives provider switching', (
    tester,
  ) async {
    await tester.pumpWidget(_localApp(_LocalRuntime()));
    await _tap(tester, 'LiteRT-LM');
    await _selectLocalModel(tester, 'Gemma 4 E2B (desktop Chrome, ~2 GB)');

    for (final provider in ['GGUF', 'LiteRT-LM']) {
      await tester.tap(find.text(provider));
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsNothing);
      await tester.pumpAndSettle();
    }
    expect(find.text('Load Gemma 4 E2B to begin.'), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
  });

  testWidgets('LiteRT-LM Gemma warning leaves Load reachable at 320x480', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 480);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final runtime = _LocalRuntime();
    await tester.pumpWidget(_localApp(runtime));
    await _tap(tester, 'LiteRT-LM');
    final dropdown = tester.widget<DropdownButton<LocalModelOption>>(
      find.byType(DropdownButton<LocalModelOption>),
    );
    for (final item in dropdown.items!) {
      final label = item.child as Text;
      expect(label.maxLines, 1);
      expect(label.overflow, TextOverflow.ellipsis);
    }
    await _selectLocalModel(tester, 'Gemma 4 E2B (desktop Chrome, ~2 GB)');
    expect(tester.takeException(), isNull);
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Load').hitTestable(),
      80,
      scrollable: find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Scrollable),
      ),
    );
    await _tap(tester, 'Load');
    expect(runtime.definition?.name, 'gemma-4-e2b-litert');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Send clears prompt and auto-scrolls while streaming without yanking scrolled-up readers',
    (tester) async {
      tester.view.physicalSize = const Size(400, 420);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final runtime = _LocalRuntime(supportsMultiTurn: true);
      await _openLocal(tester, 'GGUF', runtime);
      final scroll = tester.widget<ListView>(find.byType(ListView)).controller!;

      await _send(tester, 'First question');
      expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, 'Prompt'))
            .controller!
            .text,
        isEmpty,
      );

      for (var i = 0; i < 16; i++) {
        runtime.chunks.add(_chunk('Line $i: ${'word ' * 10}\n'));
        await tester.pump();
      }
      expect(scroll.position.maxScrollExtent, greaterThan(0));
      expect(scroll.position.extentAfter, 0);
      await runtime.chunks.close();
      await tester.pumpAndSettle();

      await _send(tester, 'Second question');
      scroll.jumpTo(0);
      await tester.pump();
      expect(scroll.position.extentAfter, greaterThan(48));

      runtime.chunks.add(_chunk('Scrolled up output\n' * 12));
      await tester.pump();
      expect(scroll.position.pixels, 0);

      await runtime.chunks.close();
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'local GGUF trims oldest history pairs above budget with a visible note while Gemini stays untrimmed',
    (tester) async {
      final runtime = _LocalRuntime(supportsMultiTurn: true);
      await _openLocal(tester, 'GGUF', runtime);

      String block(String tag, int length) => '$tag ${'x' * length}';
      final u0 = block('U0', 900);
      final a0 = block('A0', 900);
      final u1 = block('U1', 900);
      final a1 = block('A1', 900);
      final u2 = block('U2', 900);
      final a2 = block('A2', 900);

      await _send(tester, u0);
      await _reply(tester, runtime, a0);
      await _send(tester, u1);
      await _reply(tester, runtime, a1);
      await _send(tester, u2);
      expect(runtime.history.last.map((m) => m.content).toList(), [
        'You are a concise, helpful assistant.',
        u0,
        a0,
        u1,
        a1,
        u2,
      ]);
      expect(
        find.textContaining('Older turns remain visible here'),
        findsNothing,
      );
      await _reply(tester, runtime, a2);

      await _send(tester, 'U3 latest');
      final forwarded = runtime.history.last.map((m) => m.content).toList();
      expect(forwarded, [
        'You are a concise, helpful assistant.',
        u1,
        a1,
        u2,
        a2,
        'U3 latest',
      ]);
      expect(forwarded, isNot(contains(u0)));
      expect(forwarded, isNot(contains(a0)));
      expect(
        find.text(
          'Older turns remain visible here, while only recent turns are sent '
          'to fit the local context window.',
        ),
        findsOneWidget,
      );
      await _reply(tester, runtime, 'A3 latest');

      final scroll = tester.widget<ListView>(find.byType(ListView)).controller!;
      scroll.jumpTo(0);
      await tester.pump();
      expect(find.text(u0), findsOneWidget);

      await _tap(tester, 'Clear');
      expect(
        find.textContaining('Older turns remain visible here'),
        findsNothing,
      );

      await tester.pumpWidget(const SizedBox());
      final plugin = _GeminiPlugin();
      await _connectGemini(tester, plugin);
      // Exceed localHistoryCharBudget (4,500 chars) to confirm Gemini stays untrimmed.
      for (final u in [
        block('GU0', 2000),
        block('GU1', 2000),
        block('GU2', 2000),
      ]) {
        await _send(tester, u);
        expect(plugin.requests.last, isNotNull);
        await _tap(tester, 'Stop');
      }
      await _send(tester, 'U3 gemini');
      expect(plugin.requests.last.messages.map((m) => m.role).toList(), [
        Role.system,
        Role.user,
        Role.model,
        Role.user,
        Role.model,
        Role.user,
        Role.model,
        Role.user,
      ]);
      await _tap(tester, 'Stop');

      await tester.pumpWidget(const SizedBox());
      final failingRuntime = _LocalRuntime(supportsMultiTurn: true);
      await _openLocal(tester, 'GGUF', failingRuntime);
      await _send(tester, 'First');
      await _reply(tester, failingRuntime, 'First reply');
      await _send(tester, 'Second');
      failingRuntime.chunks.addError(
        llama.LlamaStateException('Context full.'),
      );
      await failingRuntime.chunks.close();
      await tester.pumpAndSettle();
      expect(find.textContaining('Context full.'), findsOneWidget);
      expect(
        find.textContaining('Try Clear or a shorter prompt.'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'narrow 320x480 viewport fits Gemma 4 warning, dropdown ellipsis, progress semantics, and user bubble contrast',
    (tester) async {
      tester.view.physicalSize = const Size(320, 480);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final loading = Completer<void>();
      final runtime = _LocalRuntime(supportsMultiTurn: true)
        ..loading = loading.future;
      await tester.pumpWidget(_localApp(runtime));

      final dropdown = tester.widget<DropdownButton<LocalModelOption>>(
        find.byType(DropdownButton<LocalModelOption>),
      );
      for (final item in dropdown.items!) {
        final label = item.child as Text;
        expect(label.maxLines, 1);
        expect(label.overflow, TextOverflow.ellipsis);
      }

      await _selectLocalModel(tester, 'Gemma 4 E2B (desktop Chrome, ~3 GB)');
      expect(tester.takeException(), isNull);
      expect(find.textContaining('~4–6 GiB peak browser RSS'), findsOneWidget);
      expect(find.textContaining('~3.5 GiB steady'), findsOneWidget);
      expect(
        find.textContaining('Chrome 158 on Apple silicon macOS'),
        findsOneWidget,
      );
      expect(
        tester.getSize(find.byType(ListView)).height,
        greaterThanOrEqualTo(200),
      );

      await tester.scrollUntilVisible(
        find.text('Load'),
        100,
        scrollable: find.descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.ensureVisible(find.text('Load'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Load'));
      await tester.pump();
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .semanticsLabel,
        'Loading model',
      );
      loading.complete();
      await tester.pumpAndSettle();

      await _send(tester, 'Hello');
      await _reply(tester, runtime, 'Hi');
      final scheme = Theme.of(tester.element(find.text('Hello'))).colorScheme;
      expect(
        tester.widget<Text>(find.text('You')).style?.color,
        scheme.onPrimaryContainer,
      );
      expect(
        tester.widget<Text>(find.text('Hello')).style?.color,
        scheme.onPrimaryContainer,
      );
    },
  );

  testWidgets(
    'unloaded provider switch does not flash progress, restores selected GGUF label, and sliders expose semantics',
    (tester) async {
      await tester.pumpWidget(_localApp(_LocalRuntime()));
      await _selectLocalModel(tester, 'Qwen3.5 0.8B (~533 MB)');

      await tester.tap(find.text('LiteRT-LM'));
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsNothing);
      await tester.pumpAndSettle();

      await tester.tap(find.text('GGUF'));
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsNothing);
      await tester.pumpAndSettle();
      expect(find.text('Load Qwen3.5 0.8B to begin.'), findsOneWidget);

      await _tap(tester, 'Settings');
      final sliders = tester.widgetList<Slider>(find.byType(Slider)).toList();
      expect(sliders, hasLength(2));
      expect(sliders[0].semanticFormatterCallback, isNotNull);
      expect(sliders[1].semanticFormatterCallback, isNotNull);
      expect(
        find.ancestor(
          of: find.byType(Slider).first,
          matching: find.byType(MergeSemantics),
        ),
        findsOneWidget,
      );
      expect(
        find.ancestor(
          of: find.byType(Slider).last,
          matching: find.byType(MergeSemantics),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'elapsed load time ticks on status line while local model loads',
    (tester) async {
      final loading = Completer<void>();
      final runtime = _LocalRuntime()..loading = loading.future;
      await tester.pumpWidget(_localApp(runtime));

      await tester.tap(find.text('Load'));
      await tester.pump();
      expect(find.text('Loading SmolLM2 135M…'), findsOneWidget);

      await tester.pump(const Duration(seconds: 5));
      expect(find.text('Loading SmolLM2 135M… 5s'), findsOneWidget);

      await tester.pump(const Duration(seconds: 60));
      expect(find.text('Loading SmolLM2 135M… 1m 05s'), findsOneWidget);

      loading.complete();
      await tester.pumpAndSettle();
      expect(find.text('Model ready (CPU).'), findsOneWidget);
    },
  );

  testWidgets(
    'streaming chunks, stats ticks, and load ticks isolate rebuilds from PlaygroundController listeners',
    (tester) async {
      final loading = Completer<void>();
      final runtime = _LocalRuntime()..loading = loading.future;
      final controller = PlaygroundController(
        bootstrapGguf: () async {},
        bootstrapLiteRt: () async {},
        runtimeFactory: () => runtime,
        googlePlugin: (key) => _GeminiPlugin(),
      );
      addTearDown(controller.dispose);

      var rootBuilds = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: ListenableBuilder(
            listenable: controller,
            builder: (_, _) {
              rootBuilds++;
              return PlaygroundView(controller: controller);
            },
          ),
        ),
      );
      expect(rootBuilds, 1);

      await tester.tap(find.text('Load'));
      await tester.pump();
      expect(rootBuilds, 2);
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('Loading SmolLM2 135M… 3s'), findsOneWidget);
      expect(rootBuilds, 2);

      loading.complete();
      await tester.pumpAndSettle();
      expect(rootBuilds, 3);

      await tester.tap(find.text('Send'));
      await tester.pump();
      expect(rootBuilds, 4);

      await tester.pump(const Duration(milliseconds: 250));
      for (var i = 0; i < 4; i++) {
        runtime.chunks.add(_chunk('w$i '));
        await tester.pump();
      }
      expect(find.text('w0 w1 w2 w3 '), findsOneWidget);
      expect(find.textContaining(RegExp(r'CPU · \d+\.\ds$')), findsOneWidget);
      expect(rootBuilds, 4);

      await runtime.chunks.close();
      await tester.pumpAndSettle();
      expect(rootBuilds, 5);
    },
  );
}

const _fakeKey = 'widget-test-credential';

Future<void> _send(WidgetTester tester, String prompt) async {
  await tester.enterText(find.widgetWithText(TextField, 'Prompt'), prompt);
  await tester.pump();
  await _tap(tester, 'Send');
}

Future<void> _reply(
  WidgetTester tester,
  _LocalRuntime runtime,
  String text, {
  llama.LlamaGenerationUsage? usage,
}) async {
  runtime.chunks.add(_chunk(text, usage: usage));
  await runtime.chunks.close();
  await tester.pumpAndSettle();
}

Future<void> _setSlider(WidgetTester tester, int index, double value) async {
  tester.widget<Slider>(find.byType(Slider).at(index)).onChanged!(value);
  await tester.pump();
}

Future<void> _tap(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

Future<void> _selectLocalModel(WidgetTester tester, String itemLabel) async {
  await tester.tap(find.byType(DropdownButton<LocalModelOption>));
  await tester.pumpAndSettle();
  await tester.tap(find.text(itemLabel).last);
  await tester.pumpAndSettle();
}

GenkitDartPadApp _localApp(_LocalRuntime runtime) => GenkitDartPadApp(
  bootstrapGguf: () async {},
  bootstrapLiteRt: () async {},
  runtimeFactory: () => runtime,
);

Future<void> _openLocal(
  WidgetTester tester,
  String label,
  _LocalRuntime runtime,
) async {
  await tester.pumpWidget(_localApp(runtime));
  if (label != 'GGUF') await _tap(tester, label);
  await _tap(tester, 'Load');
}

Future<void> _connectGemini(WidgetTester tester, _GeminiPlugin plugin) async {
  String? receivedKey;
  await tester.pumpWidget(
    GenkitDartPadApp(
      googlePlugin: (key) {
        receivedKey = key;
        return plugin;
      },
    ),
  );
  await _tap(tester, 'Gemini');
  final field = find.widgetWithText(TextField, 'Gemini API key');
  final keyField = tester.widget<TextField>(field);
  expect(keyField.obscureText, isTrue);
  expect(keyField.autofillHints, isNull);
  expect(keyField.autocorrect, isFalse);
  expect(keyField.enableSuggestions, isFalse);
  expect(keyField.enableIMEPersonalizedLearning, isFalse);
  await tester.enterText(field, _fakeKey);
  await tester.pump();
  await _tap(tester, 'Connect');
  expect(receivedKey, _fakeKey);
  expect(keyField.controller!.text, isEmpty);
  expect(field, findsNothing);
  expect(find.textContaining(_fakeKey), findsNothing);
}

llama.LlamaCompletionChunk _chunk(
  String text, {
  llama.LlamaGenerationUsage? usage,
}) => llama.LlamaCompletionChunk(
  usage: usage,
  id: 'test',
  object: 'chat.completion.chunk',
  created: 0,
  model: 'test',
  choices: [
    llama.LlamaCompletionChunkChoice(
      index: 0,
      delta: llama.LlamaCompletionChunkDelta(content: text),
    ),
  ],
);

class _LocalRuntime
    implements LlamaDartRuntime, LlamaRuntimeCapabilityProvider {
  _LocalRuntime({this.supportsMultiTurn = false, this.backendName = 'CPU'});

  final bool supportsMultiTurn;
  final String backendName;
  final history = <List<llama.LlamaChatMessage>>[];
  final params = <llama.GenerationParams?>[];
  var chunks = StreamController<llama.LlamaCompletionChunk>();
  LlamaModelDefinition? definition;
  Future<void>? loading;
  bool failLoad = false;
  bool canceled = false;
  bool disposed = false;
  bool? enableThinking;
  String? prompt;

  @override
  Future<llama.LlamaEngineCapabilities> get capabilities async =>
      llama.LlamaEngineCapabilities(
        isSupported: true,
        backendName: backendName,
        supportsMultiTurnChat: supportsMultiTurn,
      );

  @override
  Future<void> initialize(LlamaModelDefinition definition) async {
    this.definition = definition;
    if (failLoad) throw llama.LlamaModelException('The model download failed.');
    await loading;
  }

  @override
  Stream<llama.LlamaCompletionChunk> create(
    List<llama.LlamaChatMessage> messages, {
    llama.GenerationParams? params,
    List<llama.ToolDefinition>? tools,
    llama.ToolChoice? toolChoice,
    bool parallelToolCalls = false,
    bool enableThinking = false,
    String? sourceLangCode,
    String? targetLangCode,
    Map<String, dynamic>? chatTemplateKwargs,
  }) {
    this.enableThinking = enableThinking;
    history.add(messages);
    this.params.add(params);
    prompt = messages.last.content;
    if (chunks.isClosed) {
      chunks = StreamController<llama.LlamaCompletionChunk>();
    }
    return chunks.stream;
  }

  @override
  void cancelGeneration() => canceled = true;

  @override
  Future<void> dispose() async {
    disposed = true;
    // A load-only fake has no subscriber to drain.
    unawaited(chunks.close());
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _GeminiPlugin extends GenkitPlugin {
  final requests = <ModelRequest>[];
  int cancellations = 0;
  bool fail = false;
  Future<void>? finishFirstRequest;

  @override
  String get name => 'googleai';

  @override
  Action? resolve(ActionType actionType, String name) {
    if (actionType != ActionType.model || name != 'gemini-3.1-flash-lite') {
      return null;
    }
    return Model(
      name: 'googleai/$name',
      fn: (request, context) async {
        requests.add(request);
        if (fail) throw StateError('Provider rejected $_fakeKey');
        final stalled = requests.length == 1 ? finishFirstRequest : null;
        final done = Completer<void>();
        final remove = context.cancel!.onCancel(() {
          cancellations++;
          if (stalled == null) done.complete();
        });
        try {
          context.sendChunk(
            ModelResponseChunk(
              index: 0,
              content: [TextPart(text: 'A cloud fox')],
            ),
          );
          await (stalled ?? done.future);
          if (stalled != null) {
            context.sendChunk(
              ModelResponseChunk(index: 0, content: [TextPart(text: ' late')]),
            );
          }
          return ModelResponse(finishReason: FinishReason.aborted);
        } finally {
          remove();
        }
      },
    );
  }
}
