import 'dart:async';

import 'package:dartpad_gguf_example/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';

const _defaultSystem = 'You are a concise, helpful assistant.';
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
    expect(find.widgetWithText(SelectableText, ''), findsOneWidget);
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
  StreamController<LlamaCompletionChunk>? output;
  List<(LlamaChatRole, String)>? lastMessages;
  GenerationParams? lastParams;
  String? flushOnCancel;
  bool holdAfterCancel = false;
  String? countedText;

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
    output = StreamController<LlamaCompletionChunk>.broadcast();
    return output!.stream;
  }

  @override
  Future<String> getBackendName() async => 'WebGPU';

  @override
  Future<int> getTokenCount(String text) async {
    countedText = text;
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
  }
}
