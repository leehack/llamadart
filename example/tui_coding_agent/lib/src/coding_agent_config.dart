import 'package:llamadart/llamadart.dart';

/// Default tool-round budget for one coding-agent request.
const int defaultCodingAgentMaxToolRounds = 24;

/// Qwen3.6 inference defaults used by the coding-agent example.
class CodingAgentInferencePreset {
  /// Model loading and context parameters.
  final ModelParams modelParams;

  /// Sampling and output parameters.
  final GenerationParams generationParams;

  /// Whether the chat template enables the model's thinking mode.
  final bool enableThinking;

  /// Maximum tool rounds allowed for one user request.
  final int maxToolRounds;

  /// Creates an inference preset.
  const CodingAgentInferencePreset({
    required this.modelParams,
    required this.generationParams,
    required this.enableThinking,
    required this.maxToolRounds,
  });
}

/// Qwen3.6 35B-A3B non-thinking preset used by the TUI by default.
const CodingAgentInferencePreset qwen36CodingAgentPreset =
    CodingAgentInferencePreset(
      modelParams: ModelParams(
        contextSize: 16384,
        gpuLayers: 99,
        batchSize: ModelParams.defaultBatchSize,
        microBatchSize: ModelParams.defaultMicroBatchSize,
      ),
      generationParams: GenerationParams(
        maxTokens: 4096,
        temp: 0.7,
        topK: 20,
        topP: 0.8,
        minP: 0.0,
        penalty: 1.0,
        presencePenalty: 1.5,
      ),
      enableThinking: false,
      maxToolRounds: defaultCodingAgentMaxToolRounds,
    );

/// Qwen3.6 35B-A3B high-quality thinking preset enabled by `--thinking`.
const CodingAgentInferencePreset qwen36ThinkingCodingAgentPreset =
    CodingAgentInferencePreset(
      modelParams: ModelParams(
        contextSize: 32768,
        gpuLayers: 99,
        batchSize: ModelParams.defaultBatchSize,
        microBatchSize: ModelParams.defaultMicroBatchSize,
      ),
      generationParams: GenerationParams(
        maxTokens: 8192,
        temp: 0.6,
        topK: 20,
        topP: 0.95,
        minP: 0.0,
        penalty: 1.0,
        presencePenalty: 0.0,
      ),
      enableThinking: true,
      maxToolRounds: defaultCodingAgentMaxToolRounds,
    );

/// Complete runtime configuration for a coding-agent session.
class CodingAgentConfig {
  /// Workspace root exposed to repository tools.
  final String workspaceRoot;

  /// Local path, URL, or exact `hf://` reference for the model.
  final String modelSource;

  /// Optional root directory override for downloaded model files.
  ///
  /// When `null`, `llamadart` selects its standard shared cache directory.
  final String? modelCacheDirectory;

  /// Model loading and context parameters.
  final ModelParams modelParams;

  /// Sampling and output parameters.
  final GenerationParams generationParams;

  /// Maximum tool rounds allowed for one user request.
  final int maxToolRounds;

  /// Whether only the non-mutating `read` tool is exposed.
  final bool readOnly;

  /// Whether the model's thinking mode is enabled in the chat template.
  final bool enableThinking;

  /// Creates a coding-agent configuration.
  CodingAgentConfig({
    required this.workspaceRoot,
    required this.modelSource,
    this.modelCacheDirectory,
    required this.modelParams,
    required this.generationParams,
    this.maxToolRounds = defaultCodingAgentMaxToolRounds,
    this.readOnly = false,
    this.enableThinking = false,
  }) {
    if (maxToolRounds <= 0) {
      throw ArgumentError.value(
        maxToolRounds,
        'maxToolRounds',
        'must be greater than zero',
      );
    }
  }
}
