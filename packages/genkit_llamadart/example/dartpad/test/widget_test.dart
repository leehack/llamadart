@TestOn('vm')
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:genkit/genkit.dart';
import 'package:genkit/plugin.dart';
import 'package:genkit_llamadart/genkit_llamadart.dart';
import 'package:genkit_llamadart_dartpad_example/main.dart';
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

    await _tap(tester, 'Send');
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
    expect(find.text('Load the GGUF model to begin.'), findsOneWidget);
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
