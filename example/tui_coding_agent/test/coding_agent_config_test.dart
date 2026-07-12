import 'package:llamadart/llamadart.dart';
import 'package:llamadart_tui_coding_agent/src/coding_agent_config.dart';
import 'package:llamadart_tui_coding_agent/src/coding_agent_session.dart';
import 'package:test/test.dart';

void main() {
  test(
    'default Qwen source includes the exact offline-resolvable filename',
    () {
      expect(
        defaultModelSource,
        equals(
          'hf://unsloth/Qwen3.6-35B-A3B-GGUF/'
          'Qwen3.6-35B-A3B-UD-Q4_K_M.gguf',
        ),
      );

      final source = ModelSource.parse(defaultModelSource);
      final canonicalSource = ModelSource.huggingFace(
        repoId: 'unsloth/Qwen3.6-35B-A3B-GGUF',
        filePath: 'Qwen3.6-35B-A3B-UD-Q4_K_M.gguf',
      );
      expect(source.repoId, 'unsloth/Qwen3.6-35B-A3B-GGUF');
      expect(source.filePath, 'Qwen3.6-35B-A3B-UD-Q4_K_M.gguf');
      expect(source.canonicalKey, canonicalSource.canonicalKey);
      expect(
        source.cacheDirectoryName,
        'Qwen3.6-35B-A3B-UD-Q4_K_M-53ed4bc88c44',
      );
    },
  );

  test('Qwen3.6 coding-agent preset stays aligned with inference defaults', () {
    final preset = qwen36CodingAgentPreset;

    expect(preset.modelParams.contextSize, equals(16384));
    expect(preset.modelParams.gpuLayers, equals(99));
    expect(preset.modelParams.batchSize, equals(2048));
    expect(preset.modelParams.microBatchSize, equals(512));
    expect(preset.generationParams.maxTokens, equals(4096));
    expect(preset.generationParams.temp, equals(0.7));
    expect(preset.generationParams.topK, equals(20));
    expect(preset.generationParams.topP, equals(0.8));
    expect(preset.generationParams.minP, equals(0.0));
    expect(preset.generationParams.penalty, equals(1.0));
    expect(preset.generationParams.presencePenalty, equals(1.5));
    expect(preset.enableThinking, isFalse);
    expect(preset.maxToolRounds, equals(24));
  });

  test('Qwen3.6 thinking preset favors quality and a larger context', () {
    final preset = qwen36ThinkingCodingAgentPreset;

    expect(preset.modelParams.contextSize, equals(32768));
    expect(preset.modelParams.gpuLayers, equals(99));
    expect(preset.modelParams.batchSize, equals(2048));
    expect(preset.modelParams.microBatchSize, equals(512));
    expect(preset.generationParams.maxTokens, equals(8192));
    expect(preset.generationParams.temp, equals(0.6));
    expect(preset.generationParams.topK, equals(20));
    expect(preset.generationParams.topP, equals(0.95));
    expect(preset.generationParams.minP, equals(0.0));
    expect(preset.generationParams.penalty, equals(1.0));
    expect(preset.generationParams.presencePenalty, equals(0.0));
    expect(preset.enableThinking, isTrue);
    expect(preset.maxToolRounds, equals(24));
  });

  test('session config defaults to finite tool rounds', () {
    final config = CodingAgentConfig(
      workspaceRoot: '/workspace',
      modelSource: 'model.gguf',
      modelCacheDirectory: '/cache',
      modelParams: ModelParams(),
      generationParams: GenerationParams(),
    );

    expect(config.maxToolRounds, equals(24));
    expect(config.modelCacheDirectory, '/cache');
    expect(config.readOnly, isFalse);
    expect(config.enableThinking, isFalse);
  });

  test('session config delegates the default cache to llamadart', () {
    final config = CodingAgentConfig(
      workspaceRoot: '/workspace',
      modelSource: 'model.gguf',
      modelParams: const ModelParams(),
      generationParams: const GenerationParams(),
    );

    expect(config.modelCacheDirectory, isNull);
  });

  test('session config rejects a non-positive tool-round limit', () {
    expect(
      () => CodingAgentConfig(
        workspaceRoot: '/workspace',
        modelSource: 'model.gguf',
        modelCacheDirectory: '/cache',
        modelParams: const ModelParams(),
        generationParams: const GenerationParams(),
        maxToolRounds: 0,
      ),
      throwsArgumentError,
    );
  });
}
