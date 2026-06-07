// coverage:ignore-file

import 'dart:convert';
import 'dart:typed_data';

/// Runtime metrics shape shared with the native LiteRT-LM implementation.
class LiteRtLmRuntimeMetrics {
  /// Number of prompt/input tokens.
  final int inputTokens;

  /// Number of generated/output tokens.
  final int outputTokens;

  /// Time to first token in seconds, when reported by LiteRT-LM.
  final double? timeToFirstTokenSeconds;

  /// Engine initialization time in seconds, when reported by LiteRT-LM.
  final double? initSeconds;

  /// Prompt prefill throughput in tokens per second.
  final double? prefillTokensPerSecond;

  /// Decode throughput in tokens per second.
  final double? decodeTokensPerSecond;

  /// Wall-clock runtime measured by Dart.
  final int wallMilliseconds;

  /// Creates runtime metrics.
  const LiteRtLmRuntimeMetrics({
    required this.inputTokens,
    required this.outputTokens,
    required this.timeToFirstTokenSeconds,
    required this.initSeconds,
    required this.prefillTokensPerSecond,
    required this.decodeTokensPerSecond,
    required this.wallMilliseconds,
  });

  /// Converts metrics to JSON-compatible values.
  Map<String, Object?> toJson() => {
    'inputTokens': inputTokens,
    'outputTokens': outputTokens,
    'timeToFirstTokenSeconds': timeToFirstTokenSeconds,
    'initSeconds': initSeconds,
    'prefillTokensPerSecond': prefillTokensPerSecond,
    'decodeTokensPerSecond': decodeTokensPerSecond,
    'wallMilliseconds': wallMilliseconds,
  };
}

/// Generated text and runtime metrics from a LiteRT-LM run.
class LiteRtLmRuntimeResult {
  /// Generated text.
  final String text;

  /// Runtime metrics.
  final LiteRtLmRuntimeMetrics metrics;

  /// Creates a runtime result.
  const LiteRtLmRuntimeResult({required this.text, required this.metrics});
}

/// LiteRT-LM media input passed through the native Conversation API.
class LiteRtLmMediaInput {
  LiteRtLmMediaInput._({required this.type, this.path, this.bytes});

  /// Creates image input backed by a local file path.
  factory LiteRtLmMediaInput.imagePath(String path) {
    return LiteRtLmMediaInput._(type: LiteRtLmMediaType.image, path: path);
  }

  /// Creates image input backed by encoded image bytes.
  factory LiteRtLmMediaInput.imageBlob(Uint8List bytes) {
    return LiteRtLmMediaInput._(
      type: LiteRtLmMediaType.image,
      bytes: Uint8List.fromList(bytes),
    );
  }

  /// Creates audio input backed by a local file path.
  factory LiteRtLmMediaInput.audioPath(String path) {
    return LiteRtLmMediaInput._(type: LiteRtLmMediaType.audio, path: path);
  }

  /// Creates audio input backed by encoded audio bytes.
  factory LiteRtLmMediaInput.audioBlob(Uint8List bytes) {
    return LiteRtLmMediaInput._(
      type: LiteRtLmMediaType.audio,
      bytes: Uint8List.fromList(bytes),
    );
  }

  /// Media modality.
  final LiteRtLmMediaType type;

  /// Local file path, when file-backed.
  final String? path;

  /// Encoded media bytes, when blob-backed.
  final Uint8List? bytes;

  /// Converts this input to LiteRT-LM conversation message JSON.
  Map<String, Object> toJson() {
    final result = <String, Object>{'type': type.name};
    final localPath = path;
    if (localPath != null) {
      result['path'] = localPath;
      return result;
    }
    final blob = bytes;
    if (blob != null) {
      result['blob'] = base64Encode(blob);
      return result;
    }
    throw StateError('LiteRT-LM media input must have a path or bytes.');
  }
}

/// Media modality for [LiteRtLmMediaInput].
enum LiteRtLmMediaType {
  /// Image input.
  image,

  /// Audio input.
  audio,
}

/// Web-safe placeholder for the native-only runtime client.
class LiteRtLmRuntimeClient {
  /// Creates a placeholder client on platforms without `dart:ffi`.
  LiteRtLmRuntimeClient() {
    throw UnsupportedError('LiteRT-LM runtime requires a native platform.');
  }

  /// Initializes the native LiteRT-LM engine.
  Future<void> initialize({
    required String modelPath,
    String backend = 'gpu',
    int maxTokens = 4096,
    int outputTokens = 256,
    int? prefillTokens,
    int? maxNumImages,
    String? cacheDir,
    bool speculativeDecoding = true,
    int minLogLevel = 3,
  }) {
    throw UnsupportedError('LiteRT-LM runtime requires a native platform.');
  }

  /// Updates the native LiteRT-LM log level.
  void setMinLogLevel(int level) {
    throw UnsupportedError('LiteRT-LM runtime requires a native platform.');
  }

  /// Creates a conversation for generation/token operations.
  void createConversation({
    String? systemMessage,
    double temperature = 0.8,
    int topK = 40,
    double topP = 0.95,
    int seed = 1,
    bool npuBackend = false,
  }) {
    throw UnsupportedError('LiteRT-LM runtime requires a native platform.');
  }

  /// Tokenizes text with the native LiteRT-LM tokenizer.
  List<int> tokenize(String text, {bool addSpecial = true}) {
    throw UnsupportedError('LiteRT-LM runtime requires a native platform.');
  }

  /// Converts native LiteRT-LM token ids back to text.
  String detokenize(List<int> tokens) {
    throw UnsupportedError('LiteRT-LM runtime requires a native platform.');
  }

  /// Streams generated text from the active conversation.
  Stream<String> generate(
    String prompt, {
    List<LiteRtLmMediaInput> mediaInputs = const <LiteRtLmMediaInput>[],
    int? visualTokenBudget,
  }) {
    throw UnsupportedError('LiteRT-LM runtime requires a native platform.');
  }

  /// Runs a benchmark-style prompt loop and returns runtime metrics.
  Future<LiteRtLmRuntimeResult> run({
    required String prompt,
    int warmupRuns = 1,
    int measuredRuns = 3,
  }) {
    throw UnsupportedError('LiteRT-LM runtime requires a native platform.');
  }

  /// Reads runtime metrics for the active conversation.
  LiteRtLmRuntimeMetrics readMetrics({required int wallMilliseconds}) {
    throw UnsupportedError('LiteRT-LM runtime requires a native platform.');
  }

  /// Cancels active native generation.
  void cancel() {
    throw UnsupportedError('LiteRT-LM runtime requires a native platform.');
  }

  /// Releases native LiteRT-LM resources.
  void dispose() {}
}
