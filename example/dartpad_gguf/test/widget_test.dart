@TestOn('vm')
library;

import 'dart:async';

import 'package:dartpad_gguf_example/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';

void main() {
  late _FakeEngine engine;

  Future<void> openApp(WidgetTester tester) {
    engine = _FakeEngine();
    return tester.pumpWidget(GgufApp(createEngine: () async => engine));
  }

  Future<void> load(WidgetTester tester) async {
    await tester.tap(find.text('Load'));
    await tester.pump();
    engine.loadResult.complete();
    await tester.pump();
  }

  testWidgets('loads the default model and streams a story', (tester) async {
    await openApp(tester);
    final run = find.widgetWithText(FilledButton, 'Run');
    expect(tester.widget<FilledButton>(run).onPressed, isNull);
    await tester.tap(find.text('Load'));
    await tester.pump();
    expect(engine.source?.kind, ModelSourceKind.http);
    expect(engine.source?.url?.host, 'huggingface.co');
    expect(engine.source?.url?.path, contains('/resolve/b6dd7374'));
    expect(engine.params?.contextSize, 1024);

    engine.progress?.call(const ModelDownloadProgress.fraction(0.5));
    await tester.pump();
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      0.5,
    );
    engine.loadResult.complete();
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(
      find.text('WASM · memory64 · worker · single-thread'),
      findsOneWidget,
    );

    await tester.enterText(find.byType(TextField), 'Once upon a time');
    await tester.tap(run);
    await tester.pump();
    expect(engine.prompt, 'Once upon a time');
    engine.output.add('There was');
    await tester.pump();
    expect(find.text('There was'), findsOneWidget);
    engine.output.add(' a fox.');
    await engine.output.close();
    await tester.pump();
    expect(find.text('There was a fox.'), findsOneWidget);
    expect(run, findsOneWidget);
  });

  testWidgets('switches presets and cancels an instruct chat', (tester) async {
    await openApp(tester);
    await load(tester);
    await tester.tap(find.textContaining('Stories15M'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('SmolLM2').last);
    await tester.pumpAndSettle();

    final run = find.widgetWithText(FilledButton, 'Run');
    expect(tester.widget<FilledButton>(run).onPressed, isNull);
    engine.loadResult = Completer<void>();
    await load(tester);
    expect(engine.source?.url?.path, contains('/resolve/9e6855bc'));
    await tester.tap(run);
    await tester.pump();
    expect(engine.chatMessage?.role, LlamaChatRole.user);
    expect(engine.chatMessage?.content, contains('day hike'));
    engine.chat.add(
      LlamaCompletionChunk(
        id: 'chunk',
        object: 'chat.completion.chunk',
        created: 0,
        model: 'test.gguf',
        choices: [
          LlamaCompletionChunkChoice(
            index: 0,
            delta: LlamaCompletionChunkDelta(content: 'Bring water.'),
          ),
        ],
      ),
    );
    await tester.pump();
    expect(find.text('Bring water.'), findsOneWidget);

    await tester.tap(find.text('Stop'));
    await tester.pumpAndSettle();
    expect(engine.chat.hasListener, isFalse);
    expect(find.text('Bring water.'), findsOneWidget);
    expect(tester.widget<FilledButton>(run).onPressed, isNotNull);
  });

  testWidgets('shows typed load errors and lets the user retry', (
    tester,
  ) async {
    await openApp(tester);
    for (final (error, message) in [
      (
        LlamaUnsupportedException('Bridge unavailable'),
        'Unavailable: Bridge unavailable',
      ),
      (
        LlamaModelException('Download failed'),
        'Model load failed: Download failed',
      ),
    ]) {
      await tester.tap(find.text('Load'));
      await tester.pump();
      engine.loadResult.completeError(error);
      await tester.pump();
      expect(find.text(message), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      engine.loadResult = Completer<void>();
    }

    await load(tester);
    expect(find.textContaining('Model load failed'), findsNothing);
    await tester.tap(find.text('Run'));
    await tester.pump();
    engine.output.addError(LlamaInferenceException('Generation failed'));
    await tester.pump();
    expect(find.text('Generation failed'), findsOneWidget);
    expect(find.text('Run'), findsOneWidget);
  });

  testWidgets('disposes the engine and cancels an active stream', (
    tester,
  ) async {
    await openApp(tester);
    await load(tester);
    await tester.tap(find.text('Run'));
    await tester.pump();
    expect(engine.output.hasListener, isTrue);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(engine.output.hasListener, isFalse);
    expect(engine.disposed, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disposes an engine that arrives after unmounting', (
    tester,
  ) async {
    engine = _FakeEngine();
    final created = Completer<LlamaEngine>();
    await tester.pumpWidget(GgufApp(createEngine: () => created.future));
    await tester.tap(find.text('Load'));
    await tester.pumpWidget(const SizedBox());

    created.complete(engine);
    await tester.pump();
    expect(engine.source, isNull);
    expect(engine.disposed, isTrue);
    expect(tester.takeException(), isNull);
  });
}

class _FakeEngine extends Fake implements LlamaEngine {
  _FakeEngine() {
    addTearDown(() {
      if (!output.isClosed) unawaited(output.close());
      if (!chat.isClosed) unawaited(chat.close());
    });
  }

  final output = StreamController<String>(onCancel: () async {});
  final chat = StreamController<LlamaCompletionChunk>(onCancel: () async {});
  Completer<void> loadResult = Completer<void>();
  ModelDownloadProgressCallback? progress;
  ModelSource? source;
  ModelParams? params;
  String? prompt;
  LlamaChatMessage? chatMessage;
  bool disposed = false;

  @override
  Future<void> setModel(
    LlamaModel model, {
    ModelParams params = const ModelParams(),
    ModelLoadOptions download = ModelLoadOptions.defaults,
    ModelDownloadProgressCallback? onProgress,
  }) {
    source = model.source;
    this.params = params;
    progress = onProgress;
    return loadResult.future;
  }

  @override
  Future<String> getBackendName() async => 'WASM';

  @override
  Future<Map<String, String>> getMetadata() async => {
    'llamadart.webgpu.core_variant': 'memory64',
    'llamadart.webgpu.execution': 'worker',
    'llamadart.webgpu.runtime_notes': 'core_pthreads:0;core_single_thread',
  };

  @override
  Stream<String> generate(
    String prompt, {
    GenerationParams params = const GenerationParams(),
    List<LlamaContentPart>? parts,
  }) {
    this.prompt = prompt;
    return output.stream;
  }

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
    chatMessage = messages.single;
    return chat.stream;
  }

  @override
  Future<void> dispose() async => disposed = true;
}
