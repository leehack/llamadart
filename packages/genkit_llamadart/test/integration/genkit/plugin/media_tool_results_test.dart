import 'package:genkit/genkit.dart';
import 'package:genkit_llamadart/genkit_llamadart.dart';
import 'package:llamadart/llamadart.dart' as llama;
import 'package:schemantic/schemantic.dart';
import 'package:test/test.dart';

import '../../../core/runtime/test_support/fake_runtime.dart';

const _capabilities = llama.LlamaEngineCapabilities(
  isSupported: true,
  supportsVision: true,
  supportsMultiTurnChat: true,
  supportsToolCalling: true,
  toolResultMedia: {llama.LlamaToolResultMedia.image},
);

Future<
  ({FakeRuntime runtime, Genkit ai, Tool<Map<String, dynamic>, String> tool})
>
_setup(
  List<Part> Function(String key) parts, {
  llama.LlamaEngineCapabilities capabilities = _capabilities,
  List<List<llama.LlamaCompletionChunk>>? scripts,
  List<String>? calls,
  LlamaDartMediaResolver? resolver,
}) async {
  final runtime = FakeRuntime()
    ..capabilitySnapshot = capabilities
    ..createScripts.addAll(
      scripts ??
          [
            [
              toolCallChunk(
                id: 'first',
                name: 'render',
                arguments: '{"key":"one"}',
              ),
              toolCallChunk(
                id: 'second',
                name: 'render',
                arguments: '{"key":"two"}',
                index: 1,
              ),
            ],
            [textChunk('done'), stopChunk()],
          ],
    );
  final plugin = LlamaDartPlugin(
    models: const [LlamaModelDefinition(name: 'local', modelPath: '/unused')],
    runtimeFactory: () => runtime,
    mediaResolver: resolver,
  );
  final ai = Genkit(plugins: [plugin], isDevEnv: false);
  addTearDown(() async {
    await plugin.dispose();
    await ai.shutdown();
  });
  final tool = ai.defineTool<Map<String, dynamic>, String>(
    name: 'render',
    description: 'Render',
    inputSchema: SchemanticType.from(
      jsonSchema: {
        'type': 'object',
        'properties': {
          'key': {'type': 'string'},
        },
        'required': ['key'],
      },
      parse: (v) => (v as Map).cast<String, dynamic>(),
    ),
    outputSchema: SchemanticType.string(),
    fn: (input, _) async {
      final key = input['key'] as String;
      calls?.add(key);
      return ToolResult.response('structured:$key', parts: parts(key));
    },
  );
  return (runtime: runtime, ai: ai, tool: tool);
}

List<Part> _textAndImage(String key) => [
  TextPart(text: 'chart $key'),
  MediaPart(
    media: Media(url: 'data:image/png;base64,AQID', contentType: 'image/png'),
  ),
];

void main() {
  test('image tool results reach the next model turn in call order', () async {
    final calls = <String>[];
    final s = await _setup(_textAndImage, calls: calls);
    final result = await s.ai.generate(
      model: llamaDart.model('local'),
      prompt: 'render',
      tools: [s.tool],
      maxTurns: 2,
      config: const LlamaDartGenerationConfig(parallelToolCalls: true),
    );
    expect(result.finishReason, FinishReason.stop, reason: '${result.error}');
    expect(result.text, 'done');
    expect(calls, ['one', 'two']);
    final forwarded = s.runtime.recordedMessages[1]
        .expand((m) => m.parts)
        .whereType<llama.LlamaToolResultContent>()
        .toList();
    expect(forwarded.map((p) => (p.id, p.name)), [
      ('first', 'render'),
      ('second', 'render'),
    ]);
    for (final part in forwarded) {
      expect(part.result, isNull);
      expect(part.content, hasLength(2));
      expect(part.content[0], isA<llama.LlamaTextContent>());
      expect((part.content[1] as llama.LlamaImageContent).bytes, [1, 2, 3]);
    }
    expect(
      forwarded.map((p) => (p.content[0] as llama.LlamaTextContent).text),
      ['chart one', 'chart two'],
    );
    final history = result.messages
        .expand((m) => m.content)
        .where((p) => p.isToolResponse)
        .map((p) => p.toolResponse!)
        .toList();
    expect(history.map((p) => p.output), ['structured:one', 'structured:two']);
    expect(history.every((p) => p.content!.last['media'] != null), isTrue);
    expect(s.runtime.createCallCount, 2);
    expect(result.usage?.inputImages, 2);
  });

  test('thinking budgets still require text-only input', () async {
    final s = await _setup(
      _textAndImage,
      capabilities: const llama.LlamaEngineCapabilities(
        isSupported: true,
        supportsMultiTurnChat: true,
        supportsToolCalling: true,
        supportsThinkingBudget: true,
        toolResultMedia: {llama.LlamaToolResultMedia.image},
      ),
    );
    final result = await s.ai.generate(
      model: llamaDart.model('local'),
      prompt: 'render',
      tools: [s.tool],
      maxTurns: 2,
      config: const LlamaDartGenerationConfig(
        thinkingBudget: ThinkingBudget(maxTokens: 16),
      ),
    );
    expect(result.finishReason, FinishReason.failed);
    expect(s.runtime.createCallCount, 1);
    expect('${result.cause}', contains('text-only input'));
  });

  test('media results survive interrupt and resume', () async {
    final s = await _setup(
      _textAndImage,
      scripts: [
        [
          toolCallChunk(
            id: 'first',
            name: 'render',
            arguments: '{"key":"one"}',
          ),
          toolCallChunk(
            id: 'confirmation',
            name: 'confirm',
            arguments: '{}',
            index: 1,
          ),
        ],
        [textChunk('done'), stopChunk()],
      ],
    );
    final confirm = s.ai.defineInterrupt<Map<String, dynamic>, String>(
      name: 'confirm',
      description: 'Confirm',
      inputSchema: SchemanticType.from(
        jsonSchema: {'type': 'object'},
        parse: (v) => (v as Map).cast<String, dynamic>(),
      ),
    );
    var result = await s.ai.generate(
      model: llamaDart.model('local'),
      prompt: 'render',
      tools: [s.tool, confirm],
      maxTurns: 2,
      config: const LlamaDartGenerationConfig(parallelToolCalls: true),
    );
    expect(result.finishReason, FinishReason.interrupted);
    expect(s.runtime.createCallCount, 1);
    result = await s.ai.generate(
      model: llamaDart.model('local'),
      messages: result.messages,
      tools: [s.tool, confirm],
      maxTurns: 2,
      interruptRespond: [InterruptResponse(result.interrupts.single, 'ok')],
    );
    expect(result.text, 'done', reason: '${result.error}');
    final forwarded = s.runtime.recordedMessages[1]
        .expand((m) => m.parts)
        .whereType<llama.LlamaToolResultContent>()
        .toList();
    expect(forwarded.map((p) => p.id), ['first', 'confirmation']);
    expect(forwarded.first.content.last, isA<llama.LlamaImageContent>());
    expect(forwarded.last.result, 'ok');
  });

  test(
    'a runtime without tool-result media stops before the next turn',
    () async {
      final s = await _setup(
        _textAndImage,
        capabilities: const llama.LlamaEngineCapabilities(
          isSupported: true,
          supportsVision: true,
          supportsMultiTurnChat: true,
          supportsToolCalling: true,
        ),
      );
      final result = await s.ai.generate(
        model: llamaDart.model('local'),
        prompt: 'render',
        tools: [s.tool],
        maxTurns: 2,
      );
      expect(result.finishReason, FinishReason.failed);
      expect(s.runtime.createCallCount, 1);
      expect(
        result.cause,
        isA<GenkitException>().having(
          (e) => e.status,
          'status',
          StatusCode.unimplemented,
        ),
      );
    },
  );

  test('audio results need an audio-capable runtime', () async {
    final s = await _setup(
      (_) => [
        MediaPart(
          media: Media(
            url: 'data:audio/wav;base64,BAUG',
            contentType: 'audio/wav',
          ),
        ),
      ],
    );
    final result = await s.ai.generate(
      model: llamaDart.model('local'),
      prompt: 'render',
      tools: [s.tool],
      maxTurns: 2,
    );
    expect(result.finishReason, FinishReason.failed);
    expect(s.runtime.createCallCount, 1);
    expect('${result.cause}', contains('audio tool-result content'));
  });

  test(
    'a remote image without a resolver stops before the next turn',
    () async {
      final calls = <String>[];
      final s = await _setup(
        (_) => [
          MediaPart(
            media: Media(
              url: 'https://host/SECRET_SENTINEL?token=TOKEN_SENTINEL',
              contentType: 'image/png',
            ),
          ),
        ],
        calls: calls,
      );
      final result = await s.ai.generate(
        model: llamaDart.model('local'),
        prompt: 'render',
        tools: [s.tool],
        maxTurns: 2,
      );
      expect(result.finishReason, FinishReason.failed);
      expect(calls, ['one', 'two']);
      expect(s.runtime.createCallCount, 1);
      expect('${result.error} ${result.cause}', isNot(contains('SENTINEL')));
    },
  );

  test('unsupported result parts stop before the second model turn', () async {
    final calls = <String>[];
    final s = await _setup(
      (_) => [
        TextPart(text: 'first'),
        ResourcePart(resource: {'uri': 'private://secret'}),
      ],
      calls: calls,
    );
    final result = await s.ai.generate(
      model: llamaDart.model('local'),
      prompt: 'render',
      tools: [s.tool],
      maxTurns: 2,
    );
    expect(result.finishReason, FinishReason.failed);
    expect(s.runtime.createCallCount, 1);
    expect(
      result.cause,
      isA<GenkitException>().having(
        (e) => e.status,
        'status',
        StatusCode.unimplemented,
      ),
    );
  });
}
