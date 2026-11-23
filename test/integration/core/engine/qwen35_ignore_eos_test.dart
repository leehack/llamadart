@TestOn('vm')
@Tags(['local-only'])
@Timeout(Duration(minutes: 10))
library;

import 'dart:io';

import 'package:llamadart/llamadart.dart';
import 'package:test/test.dart';

void main() {
  final model = Platform.environment['LLAMADART_QWEN35_MODEL'];
  final skip = model == null
      ? 'Set LLAMADART_QWEN35_MODEL to Qwen3.5-0.8B-Q4_K_M.gguf.'
      : null;
  late LlamaEngine engine;

  setUpAll(() async {
    if (model == null) return;
    engine = LlamaEngine(LlamaBackend());
    await engine.loadModel(
      model,
      modelParams: const ModelParams(
        contextSize: 2048,
        gpuLayers: 0,
        preferredBackend: GpuBackend.cpu,
        numberOfThreads: 2,
        numberOfThreadsBatch: 2,
      ),
    );
  });
  tearDownAll(() async {
    if (model != null) await engine.dispose();
  });

  const messages = [
    LlamaChatMessage.fromText(
      role: LlamaChatRole.user,
      text: 'Reply with exactly: alpha',
    ),
  ];
  const params = GenerationParams(
    maxTokens: 64,
    temp: 0,
    seed: 1,
    reusePromptPrefix: false,
  );

  Future<(String, String?, BackendPerfContextData)> run(
    GenerationParams params, {
    List<LlamaChatMessage> messages = messages,
    Map<String, dynamic>? responseFormat,
    List<ToolDefinition>? tools,
  }) async {
    final chunks = await engine
        .create(
          messages,
          params: params,
          enableThinking: false,
          responseFormat: responseFormat,
          tools: tools,
        )
        .toList();
    final performance = await engine.getPerformanceContext();
    return (
      chunks.map((chunk) => chunk.choices.first.delta.content ?? '').join(),
      chunks.last.choices.first.finishReason,
      performance!,
    );
  }

  test(
    'generation runs past the end of the reply to maxTokens',
    skip: skip,
    () async {
      final (text, reason, natural) = await run(params);
      expect(reason, 'stop');
      expect(natural.evalTokens, lessThan(params.maxTokens));

      final (longer, longerReason, ignoring) = await run(
        params.copyWith(ignoreEos: true),
      );
      expect(longerReason, 'length');
      expect(ignoring.evalTokens, params.maxTokens);
      expect(longer, startsWith(text));
    },
  );

  test('n-gram speculation also runs to maxTokens', skip: skip, () async {
    // The earlier answer gives n-gram speculation an end-of-turn to draft.
    final (_, reason, performance) = await run(
      messages: const [
        ...messages,
        LlamaChatMessage.fromText(role: LlamaChatRole.assistant, text: 'alpha'),
        ...messages,
      ],
      params.copyWith(
        ignoreEos: true,
        speculativeDecodingConfig: const SpeculativeDecodingConfig.ngramSimple(
          ngramSizeN: 1,
          ngramSizeM: 8,
        ),
      ),
    );
    expect(reason, 'length');
    expect(performance.evalTokens, params.maxTokens);
    expect(performance.speculativeDraftTokens, greaterThan(0));
  });

  test('a response format or a tool grammar is rejected', skip: skip, () async {
    final rejected = throwsA(
      isA<LlamaUnsupportedException>().having(
        (error) => error.toString(),
        'message',
        contains('ignoreEos'),
      ),
    );
    final ignoring = params.copyWith(ignoreEos: true);
    await expectLater(
      run(ignoring, responseFormat: const {'type': 'json_object'}),
      rejected,
    );
    await expectLater(
      run(
        ignoring,
        tools: [
          ToolDefinition(
            name: 'get_time',
            description: 'Returns the current time.',
            parameters: const [],
            handler: (_) async => '12:00',
          ),
        ],
      ),
      rejected,
    );
    final (_, reason, _) = await run(params);
    expect(reason, 'stop');
  });
}
