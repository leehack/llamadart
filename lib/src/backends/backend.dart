import 'dart:typed_data';

import '../core/models/inference/model_params.dart';
import '../core/models/inference/generation_params.dart';
import '../core/models/inference/tool_choice.dart';
import '../core/models/chat/chat_message.dart';
import '../core/models/chat/content_part.dart';
import '../core/models/config/gpu_backend.dart';
import '../core/models/config/gpu_device_info.dart';
import '../core/models/config/log_level.dart';
import '../core/models/diagnostics/model_file_type.dart';
import '../core/models/tools/tool_definition.dart';

import 'web/web_backend.dart' if (dart.library.io) 'native/native_backend.dart';

/// Platform-agnostic interface for local model inference.
abstract class LlamaBackend {
  /// Factory to create the appropriate backend for the current platform.
  factory LlamaBackend() => createBackend();

  /// Whether the backend is currently initialized and ready for inference.
  bool get isReady;

  /// Initializes the model from a local file [path].
  Future<int> modelLoad(String path, ModelParams params);

  /// Initializes the model from a remote [url].
  Future<int> modelLoadFromUrl(
    String url,
    ModelParams params, {
    Function(double progress)? onProgress,
  });

  /// Releases the allocated [modelHandle].
  Future<void> modelFree(int modelHandle);

  /// Creates a new inference context for the given [modelHandle].
  Future<int> contextCreate(int modelHandle, ModelParams params);

  /// Releases the allocated [contextHandle].
  Future<void> contextFree(int contextHandle);

  /// Returns the actual context size used by the given [contextHandle].
  Future<int> getContextSize(int contextHandle);

  /// Generates a stream of token bytes for a given prompt and context.
  Stream<List<int>> generate(
    int contextHandle,
    String prompt,
    GenerationParams params, {
    List<LlamaContentPart>? parts,
  });

  /// Immediately cancels the current generation.
  void cancelGeneration();

  /// Encodes the given [text] into a list of token IDs.
  Future<List<int>> tokenize(
    int modelHandle,
    String text, {
    bool addSpecial = true,
  });

  /// Decodes a list of [tokens] back into a human-readable string.
  Future<String> detokenize(
    int modelHandle,
    List<int> tokens, {
    bool special = false,
  });

  /// Retrieves all available metadata from the loaded model.
  Future<Map<String, String>> modelMetadata(int modelHandle);

  /// Dynamically loads or updates a LoRA adapter's scale.
  Future<void> setLoraAdapter(int contextHandle, String path, double scale);

  /// Removes a specific LoRA adapter from the active session.
  Future<void> removeLoraAdapter(int contextHandle, String path);

  /// Removes all active LoRA adapters from the current context.
  Future<void> clearLoraAdapters(int contextHandle);

  /// Returns the name of the active runtime backend.
  Future<String> getBackendName();

  /// Whether this backend supports loading from URLs directly (e.g. WASM).
  ///
  /// Backends that support this (like Web) will handle URL-based model loading
  /// natively, while others may require the engine to download the file first.
  bool get supportsUrlLoading;

  /// Returns true if the hardware and backend support GPU acceleration.
  Future<bool> isGpuSupported();

  /// Updates the minimum log level for the backend.
  Future<void> setLogLevel(LlamaLogLevel level);

  /// Releases all allocated backend resources.
  Future<void> dispose();

  /// Loads a multimodal projector for vision/audio support.
  Future<int?> multimodalContextCreate(int modelHandle, String mmProjPath);

  /// Frees the multimodal context.
  Future<void> multimodalContextFree(int mmContextHandle);

  /// Checks if the model supports vision input.
  Future<bool> supportsVision(int mmContextHandle);

  /// Checks if the model supports audio input.
  Future<bool> supportsAudio(int mmContextHandle);

  /// Returns the total and free VRAM in bytes.
  Future<({int total, int free})> getVramInfo();

  /// Applies the model's chat template to the given [messages].
  ///
  /// If [customTemplate] is provided, it will be used instead of the model's
  /// default template.
  ///
  /// Returns the formatted prompt string.
  Future<String> applyChatTemplate(
    int modelHandle,
    List<Map<String, dynamic>> messages, {
    String? customTemplate,
    bool addAssistant = true,
  });
}

/// Optional backend capability for exposing selectable backend options.
abstract class BackendAvailability {
  /// Returns backend options available for user selection.
  Future<String> getAvailableBackends();
}

/// Optional backend capability for reporting grammar-constrained decoding.
///
/// Backends that do not support llama.cpp-style GBNF grammar constraints can
/// implement this so high-level chat rendering keeps prompt/parser behavior
/// while avoiding unsupported grammar parameters.
abstract class BackendGrammarConstraintsSupport {
  /// Whether [GenerationParams.grammar] and related grammar fields are supported.
  bool get supportsGrammarConstraints;
}

/// Optional backend capability for native structured chat generation.
///
/// Backends that implement this can receive chat messages and tools directly
/// instead of only receiving the already-rendered prompt string. Callers should
/// check [supportsNativeChatGeneration] before invoking [generateChat].
abstract class BackendNativeChatGeneration {
  /// Whether the active backend/runtime can use native structured chat input.
  bool get supportsNativeChatGeneration;

  /// Generates from structured chat state.
  Stream<List<int>> generateChat(
    int contextHandle,
    List<LlamaChatMessage> messages,
    GenerationParams params, {
    List<ToolDefinition>? tools,
    ToolChoice toolChoice = ToolChoice.auto,
    bool parallelToolCalls = false,
    bool enableThinking = true,
    Map<String, dynamic>? chatTemplateKwargs,
    String? sourceLangCode,
    String? targetLangCode,
    DateTime? templateNow,
  });
}

/// Optional backend capability for exposing resolved runtime diagnostics.
abstract class BackendRuntimeDiagnostics {
  /// Returns resolved GPU layers used for the active model load.
  ///
  /// This value reflects the final layer count passed to native model load
  /// after backend policy/fallback decisions.
  Future<int?> getResolvedGpuLayers();
}

/// Optional backend capability for prompt-adapted speech recognition.
///
/// Web runtimes use this explicit opt-in to distinguish a bridge release that
/// has passed the speech-to-text cancellation and audio-ingestion contract
/// from an older bridge that merely reports generic audio support.
abstract class BackendPromptSpeechToTextSupport {
  /// Whether the active runtime is validated for prompt-adapted speech-to-text.
  bool get supportsPromptSpeechToText;

  /// Actionable reason when [supportsPromptSpeechToText] is false.
  String? get promptSpeechToTextUnsupportedReason;
}

/// Model family reported by a backend text-to-speech implementation.
enum BackendTextToSpeechModel {
  /// Qwen3-TTS audio generation through llama.cpp mtmd.
  qwen3Tts,
}

/// Phase reported while a backend synthesizes speech.
enum BackendTextToSpeechPhase {
  /// The backend is processing the text and optional speaker prompt.
  processingPrompt,

  /// The backend is generating audio-codec frames.
  generating,
}

/// Runtime capabilities for an optional backend text-to-speech path.
class BackendTextToSpeechCapabilities {
  /// Whether synthesis is available for the loaded model and projector.
  final bool isSupported;

  /// Actionable reason when [isSupported] is false.
  final String? unsupportedReason;

  /// Model family recognized by the backend.
  final BackendTextToSpeechModel? model;

  /// Output sample rate in Hertz.
  final int? sampleRateHz;

  /// Number of interleaved output channels.
  final int? channelCount;

  /// Whether a language hint can be supplied.
  final bool supportsLanguage;

  /// Whether encoded reference-speaker audio can be supplied.
  final bool supportsSpeakerReference;

  /// Whether an active synthesis can be cancelled cooperatively.
  final bool supportsCancellation;

  /// Creates a backend capability snapshot.
  const BackendTextToSpeechCapabilities({
    required this.isSupported,
    this.unsupportedReason,
    this.model,
    this.sampleRateHz,
    this.channelCount,
    this.supportsLanguage = false,
    this.supportsSpeakerReference = false,
    this.supportsCancellation = false,
  });
}

/// Sampling and input values passed to a backend TTS implementation.
class BackendTextToSpeechRequest {
  /// Text to synthesize.
  final String text;

  /// Optional language name or code accepted by the loaded model.
  final String? language;

  /// Optional local encoded reference-audio path.
  final String? speakerAudioPath;

  /// Optional encoded reference-audio bytes.
  final Uint8List? speakerAudioBytes;

  /// Maximum number of audio-codec frames to generate.
  final int maxFrames;

  /// Prompt evaluation batch size.
  final int promptBatchSize;

  /// Top-k sampling cutoff.
  final int topK;

  /// Top-p sampling cutoff.
  final double topP;

  /// Minimum probability sampling cutoff.
  final double minP;

  /// Sampling temperature.
  final double temperature;

  /// Random seed.
  final int seed;

  /// Creates a backend synthesis request.
  const BackendTextToSpeechRequest({
    required this.text,
    this.language,
    this.speakerAudioPath,
    this.speakerAudioBytes,
    this.maxFrames = 512,
    this.promptBatchSize = 512,
    this.topK = 40,
    this.topP = 0.95,
    this.minP = 0.0,
    this.temperature = 0.8,
    this.seed = 0xffffffff,
  });
}

/// Progress reported by a backend TTS implementation.
class BackendTextToSpeechProgress {
  /// Current synthesis phase.
  final BackendTextToSpeechPhase phase;

  /// Prompt tokens that have not yet been evaluated.
  final int promptTokensRemaining;

  /// Audio-codec frames generated so far.
  final int framesGenerated;

  /// Whether generation reached the requested frame limit.
  final bool truncated;

  /// Creates a progress snapshot.
  const BackendTextToSpeechProgress({
    required this.phase,
    required this.promptTokensRemaining,
    required this.framesGenerated,
    required this.truncated,
  });
}

/// Complete PCM output returned by a backend TTS implementation.
class BackendTextToSpeechResult {
  /// Interleaved normalized float32 PCM samples.
  final Float32List samples;

  /// Output sample rate in Hertz.
  final int sampleRateHz;

  /// Number of interleaved output channels.
  final int channelCount;

  /// Number of audio-codec frames generated.
  final int framesGenerated;

  /// Whether generation reached the requested frame limit.
  final bool truncated;

  /// Creates a backend synthesis result.
  const BackendTextToSpeechResult({
    required this.samples,
    required this.sampleRateHz,
    required this.channelCount,
    required this.framesGenerated,
    required this.truncated,
  });
}

/// Optional backend capability for dedicated text-to-speech synthesis.
abstract class BackendTextToSpeech {
  /// Discovers support for the loaded context and multimodal projector.
  Future<BackendTextToSpeechCapabilities> textToSpeechCapabilities(
    int contextHandle,
    int mmContextHandle,
  );

  /// Synthesizes one complete utterance.
  ///
  /// Current implementations return PCM only after generation has completed.
  /// [onProgress] does not imply incremental audio output.
  Future<BackendTextToSpeechResult> synthesizeTextToSpeech(
    int contextHandle,
    int mmContextHandle,
    BackendTextToSpeechRequest request, {
    void Function(BackendTextToSpeechProgress progress)? onProgress,
  });

  /// Cooperatively cancels the active synthesis, if any.
  void cancelTextToSpeech();
}

/// Optional backend capability for exposing loaded model file type metadata.
///
/// Backends that can identify the loaded model's native file type or
/// quantization format return a [ModelFileType]. Backends that do not expose
/// this data should omit this capability so high-level APIs return null.
abstract class BackendModelFileTypeDiagnostics {
  /// Returns file type metadata for [modelHandle], or null when unavailable.
  Future<ModelFileType?> getModelFileType(int modelHandle);
}

/// Optional backend capability for enumerating GPU-class devices for offload
/// selection (e.g. pinning to the discrete GPU on a laptop, or surfacing which
/// device is in use).
abstract class BackendGpuEnumeration {
  /// Lists the GPU-class devices the backend exposes.
  ///
  /// With an empty [probeBackends] only already-registered backends are
  /// inspected — no backend module is loaded, so an unsupported GPU runtime
  /// cannot crash the process during enumeration. Pass specific backends in
  /// [probeBackends] to opt into loading just those modules (each guarded)
  /// before enumerating. Backends with no offload devices (and web/WebGPU)
  /// return an empty list.
  Future<List<GpuDeviceInfo>> listGpuDevices({
    List<GpuBackend> probeBackends = const [],
  });
}

/// Native performance timings reported by llama.cpp for the active context.
class BackendPerfContextData {
  /// Time spent loading the model in ms.
  final double loadMs;

  /// Time spent evaluating prompt tokens in ms.
  final double promptEvalMs;

  /// Time spent generating tokens in ms.
  final double evalMs;

  /// Time spent sampling generated tokens in ms.
  final double sampleMs;

  /// Time spent decoding generated tokens in ms, excluding prompt ingestion.
  ///
  /// Backends that do not expose a separate decode-only measurement leave this
  /// null. For llama.cpp, this is the Dart-side `llama_decode` time measured
  /// during generation.
  final double? decodeMs;

  /// Number of prompt tokens evaluated.
  final int promptEvalTokens;

  /// Number of generated tokens evaluated.
  final int evalTokens;

  /// Number of sampler steps recorded.
  final int sampleCount;

  /// Number of times compute graphs were reused.
  final int reusedGraphs;

  /// Number of speculative draft tokens proposed by the backend.
  final int? speculativeDraftTokens;

  /// Number of speculative draft tokens accepted by the backend.
  final int? speculativeAcceptedDraftTokens;

  /// Number of speculative draft attempts made by the backend.
  final int? speculativeDraftAttempts;

  /// Number of target-model tokens decoded to verify speculative drafts.
  final int? speculativeVerifyTokens;

  /// Number of target-model tokens decoded to replay accepted speculative work.
  final int? speculativeReplayTokens;

  /// Time spent generating speculative draft tokens in ms.
  final double? speculativeDraftMs;

  /// Time spent verifying speculative draft tokens in ms.
  final double? speculativeVerifyMs;

  /// Accepted speculative draft-token ratio, when available.
  double? get speculativeAcceptanceRate {
    final draftTokens = speculativeDraftTokens;
    final acceptedDraftTokens = speculativeAcceptedDraftTokens;
    if (draftTokens == null ||
        acceptedDraftTokens == null ||
        draftTokens <= 0) {
      return null;
    }
    return acceptedDraftTokens / draftTokens;
  }

  /// Creates a new [BackendPerfContextData].
  const BackendPerfContextData({
    required this.loadMs,
    required this.promptEvalMs,
    required this.evalMs,
    required this.sampleMs,
    this.decodeMs,
    required this.promptEvalTokens,
    required this.evalTokens,
    required this.sampleCount,
    required this.reusedGraphs,
    this.speculativeDraftTokens,
    this.speculativeAcceptedDraftTokens,
    this.speculativeDraftAttempts,
    this.speculativeVerifyTokens,
    this.speculativeReplayTokens,
    this.speculativeDraftMs,
    this.speculativeVerifyMs,
  });
}

/// Optional backend capability for exposing llama.cpp perf timings.
abstract class BackendPerformanceDiagnostics {
  /// Returns current native perf timings for [contextHandle] when available.
  Future<BackendPerfContextData?> getPerformanceContext(int contextHandle);
}

/// Optional backend capability for generating text embeddings.
abstract class BackendEmbeddings {
  /// Generates a single embedding vector for [text].
  ///
  /// When [normalize] is true, the backend returns an L2-normalized vector.
  Future<List<double>> embed(
    int contextHandle,
    String text, {
    bool normalize = true,
  });
}

/// Optional backend capability for reporting whether [BackendEmbeddings] is
/// actually available for the active runtime.
///
/// This is useful for delegating/router backends where the wrapper may expose
/// embedding methods but support depends on the selected concrete backend.
/// Backends that do not implement this interface fall back to the structural
/// `is BackendEmbeddings` check used by older versions.
abstract class BackendEmbeddingsSupport {
  /// Whether embedding calls are expected to be supported by this backend.
  bool get supportsEmbeddings;
}

/// Optional backend capability for batching embedding requests.
abstract class BackendBatchEmbeddings extends BackendEmbeddings {
  /// Generates embedding vectors for all [texts] in order.
  ///
  /// When [normalize] is true, each returned vector is L2-normalized.
  Future<List<List<double>>> embedBatch(
    int contextHandle,
    List<String> texts, {
    bool normalize = true,
  });
}

/// Result of [BackendStatePersistence.stateLoadFile]. Contains the token
/// sequence saved alongside the native KV-cache state.
///
/// Loading restores the native KV cache only. Callers using higher-level
/// chat abstractions must persist and reconstruct their chat message
/// history separately; these raw token IDs are exposed mainly for
/// diagnostics and raw-prompt callers.
class StateLoadResult {
  /// The token IDs that the saved state was produced from.
  final List<int> tokens;

  /// Creates a new [StateLoadResult].
  const StateLoadResult({required this.tokens});
}

/// Optional backend capability for persisting the KV cache to disk and
/// restoring it later, mirroring `llama_state_save_file` /
/// `llama_state_load_file` in llama.cpp. Saving captures the native
/// runtime state of [contextHandle] together with the token sequence
/// that produced it. Loading restores the native KV cache and returns
/// the saved token sequence; subsequent inference can skip prompt
/// evaluation when callers re-issue a prompt with the restored token
/// prefix and prompt-prefix reuse enabled.
abstract class BackendStatePersistence {
  /// Writes the KV cache state of [contextHandle] together with the
  /// token sequence in [tokens] to [path]. The file format is the one
  /// llama.cpp emits — opaque, version-tied, and not portable across
  /// llama.cpp builds.
  ///
  /// Returns true on success.
  Future<bool> stateSaveFile(int contextHandle, String path, List<int> tokens);

  /// Restores the KV cache of [contextHandle] from a file previously
  /// written by [stateSaveFile]. [tokenCapacity] caps how many tokens
  /// the caller is willing to receive — typically the context size of
  /// the loaded model. Throws if the file is corrupt or was produced
  /// by a different llama.cpp build.
  Future<StateLoadResult> stateLoadFile(
    int contextHandle,
    String path,
    int tokenCapacity,
  );
}

/// Optional backend capability for reporting whether
/// [BackendStatePersistence] is actually available for the active runtime.
///
/// This is useful for delegating/router backends where the wrapper may expose
/// the persistence methods but support depends on the selected concrete
/// backend. Backends that do not implement this interface fall back to the
/// structural `is BackendStatePersistence` check used by older versions.
abstract class BackendStatePersistenceSupport {
  /// Whether state save/load calls are expected to be supported by this backend.
  bool get supportsStatePersistence;
}
