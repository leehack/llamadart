@TestOn('vm')
library;

import 'dart:async';

import 'package:flutter/material.dart' hide Action;
import 'package:flutter_test/flutter_test.dart';
import 'package:genkit/genkit.dart';
import 'package:genkit/plugin.dart';
import 'package:genkit_llamadart/genkit_llamadart.dart';
import 'package:genkit_llamadart_dartpad_example/main.dart';
import 'package:llamadart/llamadart.dart' as llama;

void main() {
  for (final label in ['GGUF', 'LiteRT-LM']) {
    testWidgets('$label loads, streams, stops and disposes', (tester) async {
      final runtime = _LocalRuntime();
      await _openLocal(tester, label, runtime);

      expect(
        runtime.definition?.modelPath,
        endsWith(label == 'GGUF' ? '.gguf' : '.litertlm'),
      );
      expect(find.text('Model ready (CPU).'), findsOneWidget);

      await _tap(tester, 'Generate');
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
      expect(find.text('Stopped.'), findsOneWidget);
      expect(find.text('A fox'), findsOneWidget);

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
      await _tap(tester, 'Generate');
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

  testWidgets('switching providers releases the loaded local runtime', (
    tester,
  ) async {
    final runtime = _LocalRuntime();
    await _openLocal(tester, 'GGUF', runtime);
    await _tap(tester, 'Gemini');
    expect(runtime.disposed, isTrue);
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
    expect(
      find.text('Gemini ready. Generate to verify your key.'),
      findsOneWidget,
    );

    await _tap(tester, 'Generate');
    expect(find.text('A cloud fox'), findsOneWidget);
    expect(
      plugin.requests.single.toJson().toString(),
      isNot(contains(_fakeKey)),
    );
    await _tap(tester, 'Stop');
    expect(plugin.cancellations, 1);
    expect(find.text('Stopped.'), findsOneWidget);
    expect(find.text('A cloud fox'), findsOneWidget);

    await _tap(tester, 'Generate');
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(plugin.cancellations, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Gemini errors never surface provider data or the API key', (
    tester,
  ) async {
    final plugin = _GeminiPlugin()..fail = true;
    await _connectGemini(tester, plugin);
    await _tap(tester, 'Generate');
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
}

const _fakeKey = 'widget-test-credential';

Future<void> _tap(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
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
  expect(tester.widget<TextField>(field).obscureText, isTrue);
  expect(tester.widget<TextField>(field).autofillHints, isNull);
  await tester.enterText(field, _fakeKey);
  await tester.pump();
  await _tap(tester, 'Connect');
  expect(receivedKey, _fakeKey);
  expect(field, findsNothing);
  expect(find.textContaining(_fakeKey), findsNothing);
}

llama.LlamaCompletionChunk _chunk(String text) => llama.LlamaCompletionChunk(
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
  final chunks = StreamController<llama.LlamaCompletionChunk>();
  LlamaModelDefinition? definition;
  Future<void>? loading;
  bool failLoad = false;
  bool canceled = false;
  bool disposed = false;
  bool? enableThinking;
  String? prompt;

  @override
  Future<llama.LlamaEngineCapabilities> get capabilities async =>
      const llama.LlamaEngineCapabilities(
        isSupported: true,
        backendName: 'CPU',
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
    prompt = messages.single.content;
    return chunks.stream;
  }

  @override
  void cancelGeneration() {
    canceled = true;
    unawaited(chunks.close());
  }

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

  @override
  String get name => 'googleai';

  @override
  Action? resolve(ActionType actionType, String name) {
    if (actionType != ActionType.model || name != 'gemini-3.5-flash-lite') {
      return null;
    }
    return Model(
      name: 'googleai/$name',
      fn: (request, context) async {
        requests.add(request);
        if (fail) throw StateError('Provider rejected $_fakeKey');
        final done = Completer<void>();
        final remove = context.cancel!.onCancel(() {
          cancellations++;
          done.complete();
        });
        try {
          context.sendChunk(
            ModelResponseChunk(
              index: 0,
              content: [TextPart(text: 'A cloud fox')],
            ),
          );
          await done.future;
          return ModelResponse(finishReason: FinishReason.aborted);
        } finally {
          remove();
        }
      },
    );
  }
}
