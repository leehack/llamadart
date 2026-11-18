import 'package:llamadart/llamadart.dart';
import 'package:meta/meta.dart';

/// Primary Studio workspace modality a model descriptor targets.
enum StudioModelCategory {
  /// Conversational text, vision, audio, tool-calling, or reasoning model.
  chat('Chat & Multimodal'),

  /// Speech-to-text or text-to-speech model.
  speech('Speech'),

  /// Diffusion image generation checkpoint.
  image('Image'),

  /// Embedding, cross-encoder reranker, or System-1 decision model.
  playground('Embeddings & Lab');

  const StudioModelCategory(this.label);

  /// Display label for category filter tabs.
  final String label;
}

/// Host platform availability rules for a [StudioModelDescriptor].
enum StudioModelAvailability {
  /// Supported on desktop, mobile, and WebGPU.
  all,

  /// Supported on native platforms (desktop + mobile) only.
  nativeOnly,

  /// Supported on high-memory desktop platforms only.
  desktopOnly,
}

/// Specialization kind for non-chat models (STT, TTS, Image, Reranker, etc.).
enum StudioModelSpecialty {
  /// General chat / multimodal completion model.
  generalChat,

  /// Whole-audio GGUF speech-to-text (`Qwen3AsrAdapter`).
  qwen3Asr,

  /// Streaming/windowed LiteRT-LM speech-to-text (`LiteRtLmAsrAdapter`).
  liteRtAsr,

  /// Neural text-to-speech (`Qwen3TtsAdapter`).
  qwen3Tts,

  /// Stable Diffusion text-to-image checkpoint (`ImageGenerationEngine`).
  stableDiffusion,

  /// Text/multimodal embedding encoder (`LlamaTextEmbedder`).
  embedding,

  /// Cross-encoder reranker (`LlamaReranker`).
  reranker,

  /// Laya-style encoder + safetensors head (`DecisionEngine`).
  decision,
}

/// Default sampling and context preset bundled with a [StudioModelDescriptor].
@immutable
class StudioModelTuningPreset {
  /// Creates a [StudioModelTuningPreset].
  const StudioModelTuningPreset({
    this.temperature = 0.7,
    this.topK = 40,
    this.topP = 0.9,
    this.minP = 0.0,
    this.penalty = 1.1,
    this.contextSize = 4096,
    this.maxTokens = 2048,
    this.thinkingEnabled = false,
    this.thinkingBudgetTokens = 0,
    this.imageSteps = 1,
    this.imageGuidanceScale = 1.0,
  });

  /// Default temperature.
  final double temperature;

  /// Default Top-K cutoff.
  final int topK;

  /// Default Top-P cutoff.
  final double topP;

  /// Default Min-P cutoff.
  final double minP;

  /// Default repetition penalty.
  final double penalty;

  /// Recommended context window (`n_ctx`).
  final int contextSize;

  /// Recommended max completion tokens.
  final int maxTokens;

  /// Whether chain-of-thought reasoning is enabled by default.
  final bool thinkingEnabled;

  /// Recommended chain-of-thought token budget (`0` = runtime auto).
  final int thinkingBudgetTokens;

  /// Default diffusion sampling steps for image models.
  final int imageSteps;

  /// Default CFG scale for image models.
  final double imageGuidanceScale;
}

/// Remote or local companion asset (e.g., `mmproj`, `taesd`, `tokenizer.json`,
/// or `.safetensors` decision head) paired with a primary model file.
@immutable
class StudioModelCompanionAsset {
  /// Creates a [StudioModelCompanionAsset].
  const StudioModelCompanionAsset({
    required this.role,
    required this.filename,
    required this.sourceUri,
    this.webSourceUri,
    this.sizeBytes,
    this.sha256,
  });

  /// Logical role (`projector`, `taesd`, `tokenizer`, `decisionHead`).
  final String role;

  /// Canonical filename in cache.
  final String filename;

  /// Primary download URL or local path.
  final String sourceUri;

  /// Optional Web-specific URL override.
  final String? webSourceUri;

  /// Expected byte length when known.
  final int? sizeBytes;

  /// Optional SHA-256 digest.
  final String? sha256;

  /// Resolves a `llamadart` [ModelSource] for the target platform.
  ModelSource toModelSource({required bool isWeb}) {
    final effective = isWeb ? (webSourceUri ?? sourceUri) : sourceUri;
    return ModelSource.parse(effective);
  }
}

/// Unified, immutable descriptor for curated, Hugging Face, and custom models.
@immutable
class StudioModelDescriptor {
  /// Creates a [StudioModelDescriptor].
  const StudioModelDescriptor({
    required this.id,
    required this.name,
    required this.description,
    required this.category,
    required this.filename,
    required this.sourceUri,
    this.webSourceUri,
    this.sizeBytes = 0,
    this.webSizeBytes,
    this.sha256,
    this.publisher = 'Community',
    this.quantizationLabel,
    this.minRamGb = 2,
    this.availability = StudioModelAvailability.all,
    this.specialty = StudioModelSpecialty.generalChat,
    this.liteRtAsrPreset,
    this.embeddingProfile = LlamaEmbeddingProfile.raw,
    this.companions = const <StudioModelCompanionAsset>[],
    this.supportsVision = false,
    this.supportsAudio = false,
    this.supportsToolCalling = false,
    this.supportsThinking = false,
    this.supportsSpeechToText = false,
    this.supportsTextToSpeech = false,
    this.webSupportsAudio,
    this.isRecommended = false,
    this.memoryNote,
    this.preset = const StudioModelTuningPreset(),
  });

  /// Stable model identifier.
  final String id;

  /// Human-readable title.
  final String name;

  /// Concise summary of strengths and intended use.
  final String description;

  /// Primary Studio category.
  final StudioModelCategory category;

  /// Canonical primary filename.
  final String filename;

  /// Primary model path, `https://` URL, or `hf://` URI.
  final String sourceUri;

  /// Optional Web-specific model URL override.
  final String? webSourceUri;

  /// Total combined download size in bytes (including companions).
  final int sizeBytes;

  /// Optional Web-specific total byte size.
  final int? webSizeBytes;

  /// Optional SHA-256 digest of the primary model file.
  final String? sha256;

  /// Publisher / organization badge.
  final String publisher;

  /// Quantization tag such as `Q4_K_M`, `Q8_0`, or `LiteRT-LM`.
  final String? quantizationLabel;

  /// Recommended minimum system RAM in GiB.
  final int minRamGb;

  /// Platform availability constraint.
  final StudioModelAvailability availability;

  /// Specialized engine adapter profile when non-chat.
  final StudioModelSpecialty specialty;

  /// Optional LiteRT-LM ASR preset when [specialty] is `liteRtAsr`.
  final LiteRtLmAsrModelPreset? liteRtAsrPreset;

  /// Embedding profile when [specialty] is `embedding`.
  final LlamaEmbeddingProfile embeddingProfile;

  /// Companion files required alongside the primary model.
  final List<StudioModelCompanionAsset> companions;

  /// Whether image inputs are supported.
  final bool supportsVision;

  /// Whether audio inputs are supported in chat.
  final bool supportsAudio;

  /// Whether structured tool calling is supported.
  final bool supportsToolCalling;

  /// Whether reasoning / `<think>` blocks are supported.
  final bool supportsThinking;

  /// Whether speech-to-text transcription is supported.
  final bool supportsSpeechToText;

  /// Whether text-to-speech synthesis is supported.
  final bool supportsTextToSpeech;

  /// Optional Web override for audio input support.
  final bool? webSupportsAudio;

  /// Highlighted starter recommendation in the Model Hub.
  final bool isRecommended;

  /// Optional memory warning note.
  final String? memoryNote;

  /// Recommended tuning defaults.
  final StudioModelTuningPreset preset;

  /// Inferred `llamadart` [ModelFormat] (`gguf` or `liteRtLm`).
  ModelFormat get format => filename.toLowerCase().endsWith('.litertlm')
      ? ModelFormat.liteRtLm
      : ModelFormat.gguf;

  /// Primary [ModelSource] for native or web execution.
  ModelSource primarySource({required bool isWeb}) {
    final effective = isWeb ? (webSourceUri ?? sourceUri) : sourceUri;
    return ModelSource.parse(effective, format: format);
  }

  /// Multimodal projector companion (`mmproj`), when present.
  StudioModelCompanionAsset? get projectorCompanion {
    for (final companion in companions) {
      if (companion.role == 'projector') {
        return companion;
      }
    }
    return null;
  }

  /// Optional TAESD companion for diffusion checkpoints.
  StudioModelCompanionAsset? get taesdCompanion {
    for (final companion in companions) {
      if (companion.role == 'taesd') {
        return companion;
      }
    }
    return null;
  }

  /// Optional tokenizer companion for LiteRT ASR models.
  StudioModelCompanionAsset? get tokenizerCompanion {
    for (final companion in companions) {
      if (companion.role == 'tokenizer') {
        return companion;
      }
    }
    return null;
  }

  /// Optional `.safetensors` head companion for System-1 decision models.
  StudioModelCompanionAsset? get decisionHeadCompanion {
    for (final companion in companions) {
      if (companion.role == 'decisionHead') {
        return companion;
      }
    }
    return null;
  }

  /// Effective byte size on the current target platform.
  int effectiveSizeBytes({required bool isWeb}) {
    if (isWeb && webSizeBytes != null) {
      return webSizeBytes!;
    }
    return sizeBytes;
  }

  /// Formatted human-readable download size label (e.g., `720 MB`, `2.59 GB`).
  String sizeLabel({required bool isWeb}) {
    final bytes = effectiveSizeBytes(isWeb: isWeb);
    if (bytes <= 0) {
      return 'Local / Custom';
    }
    final gib = bytes / (1024 * 1024 * 1024);
    if (gib >= 1.0) {
      final decimals = gib >= 10 ? 1 : 2;
      return '${gib.toStringAsFixed(decimals)} GB';
    }
    final mib = bytes / (1024 * 1024);
    return '${mib.toStringAsFixed(0)} MB';
  }

  /// Whether this model can run on the given host class.
  bool isSupportedOn({required bool isWeb, required bool isMobile}) {
    return switch (availability) {
      StudioModelAvailability.all => true,
      StudioModelAvailability.nativeOnly => !isWeb,
      StudioModelAvailability.desktopOnly => !isWeb && !isMobile,
    };
  }

  /// Effective audio input support on the given host class.
  bool effectiveSupportsAudio({required bool isWeb}) =>
      isWeb ? (webSupportsAudio ?? supportsAudio) : supportsAudio;

  /// Capability tags suitable for compact UI pills.
  List<String> capabilityBadges({required bool isWeb}) {
    final badges = <String>[
      if (format == ModelFormat.liteRtLm) 'LiteRT-LM' else 'GGUF',
      if (quantizationLabel != null && quantizationLabel!.isNotEmpty)
        quantizationLabel!,
      if (supportsVision) 'Vision',
      if (effectiveSupportsAudio(isWeb: isWeb)) 'Audio',
      if (supportsToolCalling) 'Tools',
      if (supportsThinking) 'Thinking',
      if (supportsSpeechToText) 'STT',
      if (supportsTextToSpeech) 'TTS',
      if (specialty == StudioModelSpecialty.stableDiffusion) 'Diffusion',
      if (specialty == StudioModelSpecialty.embedding) 'Embeddings',
      if (specialty == StudioModelSpecialty.reranker) 'Reranker',
      if (specialty == StudioModelSpecialty.decision) 'Decision Head',
    ];
    return badges;
  }
}
