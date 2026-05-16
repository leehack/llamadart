import 'dart:convert';

import 'package:crypto/crypto.dart';

String _basename(String pathOrUrl) {
  final withoutQuery = pathOrUrl.split('?').first.split('#').first;
  final normalized = withoutQuery.replaceAll('\\', '/');
  final parts = normalized.split('/').where((part) => part.isNotEmpty);
  return parts.isEmpty ? pathOrUrl : parts.last;
}

String _sourceFilename(ModelAssetSource source) {
  return source is RemoteModelAssetSource
      ? source.filename
      : source.displayName;
}

String _assetCacheKey(String canonicalKey) {
  return sha256.convert(utf8.encode(canonicalKey)).toString();
}

enum ModelAssetRole { model, multimodalProjector }

abstract class ModelAssetSource {
  const ModelAssetSource();

  String get displayName;

  String get canonicalKey;

  String get cacheKey;

  String get loadReference;

  bool get isRemote => this is RemoteModelAssetSource;

  bool get isLocal => this is LocalModelAssetSource;
}

class LocalModelAssetSource extends ModelAssetSource {
  final String path;

  const LocalModelAssetSource(this.path);

  @override
  String get displayName => _basename(path);

  @override
  String get canonicalKey => 'local:$path';

  @override
  String get cacheKey => _assetCacheKey(canonicalKey);

  @override
  String get loadReference => path;
}

class RemoteModelAssetSource extends ModelAssetSource {
  final String url;
  final String filename;
  final int? sizeBytes;
  final String? sha256;
  final Map<String, String>? headers;

  const RemoteModelAssetSource({
    required this.url,
    required this.filename,
    this.sizeBytes,
    this.sha256,
    this.headers,
  });

  @override
  String get displayName => filename;

  @override
  String get canonicalKey => 'remote:${jsonEncode([url, filename])}';

  @override
  String get cacheKey => _assetCacheKey(canonicalKey);

  @override
  String get loadReference => url;
}

class ResolvedModelAsset {
  final ModelAssetRole role;
  final ModelAssetSource source;
  final String loadReference;
  final bool isLocal;

  const ResolvedModelAsset({
    required this.role,
    required this.source,
    required this.loadReference,
    required this.isLocal,
  });
}

class ModelCapabilities {
  final bool supportsVision;
  final bool supportsAudio;
  final bool supportsVideo;
  final bool supportsToolCalling;
  final bool supportsThinking;

  const ModelCapabilities({
    this.supportsVision = false,
    this.supportsAudio = false,
    this.supportsVideo = false,
    this.supportsToolCalling = false,
    this.supportsThinking = false,
  });

  bool get isMultimodal => supportsVision || supportsAudio;
}

class ModelPreset {
  final double temperature;
  final int topK;
  final double topP;
  final double minP;
  final double penalty;
  final int thinkingBudgetTokens;
  final int contextSize;
  final int maxTokens;
  final bool thinkingEnabled;

  /// A value of 99 keeps auto-estimation behavior in ChatProvider.
  final int gpuLayers;

  const ModelPreset({
    this.temperature = 0.7,
    this.topK = 40,
    this.topP = 0.9,
    this.minP = 0.0,
    this.penalty = 1.1,
    this.thinkingBudgetTokens = 0,
    this.contextSize = 4096,
    this.maxTokens = 4096,
    this.gpuLayers = 99,
    this.thinkingEnabled = true,
  });
}

class ModelProfile {
  final String id;
  final String name;
  final String description;
  final ModelAssetSource modelSource;
  final ModelAssetSource? multimodalProjectorSource;
  final int sizeBytes;
  final ModelCapabilities capabilities;

  /// Recommended generation/model-loading preset for this model.
  final ModelPreset preset;

  /// Minimum RAM/VRAM in GB recommended for this model.
  final int minRamGb;

  const ModelProfile({
    required this.id,
    required this.name,
    required this.description,
    required this.modelSource,
    this.multimodalProjectorSource,
    this.sizeBytes = 0,
    this.capabilities = const ModelCapabilities(),
    this.minRamGb = 2,
    this.preset = const ModelPreset(),
  });

  bool get isMultimodal => capabilities.isMultimodal;
}

class DownloadableModel {
  final String id;
  final String name;
  final String description;
  final String url;
  final String filename;
  final String? mmprojUrl;
  final String? mmprojFilename;
  final int sizeBytes;
  final bool supportsVision;
  final bool supportsAudio;
  final bool supportsVideo;
  final bool supportsToolCalling;
  final bool supportsThinking;
  final ModelAssetSource? _modelSourceOverride;
  final ModelAssetSource? _multimodalProjectorSourceOverride;

  /// Recommended generation/model-loading preset for this model.
  final ModelPreset preset;

  /// Minimum RAM/VRAM in GB recommended for this model.
  final int minRamGb;

  const DownloadableModel({
    required this.name,
    required this.description,
    required this.url,
    required this.filename,
    required this.sizeBytes,
    this.mmprojUrl,
    this.mmprojFilename,
    this.supportsVision = false,
    this.supportsAudio = false,
    this.supportsVideo = false,
    this.supportsToolCalling = false,
    this.supportsThinking = false,
    this.minRamGb = 2,
    this.preset = const ModelPreset(),
  }) : id = filename,
       _modelSourceOverride = null,
       _multimodalProjectorSourceOverride = null;

  DownloadableModel.fromSources({
    String? id,
    required this.name,
    required this.description,
    required ModelAssetSource modelSource,
    ModelAssetSource? multimodalProjectorSource,
    this.sizeBytes = 0,
    this.supportsVision = false,
    this.supportsAudio = false,
    this.supportsVideo = false,
    this.supportsToolCalling = false,
    this.supportsThinking = false,
    this.minRamGb = 2,
    this.preset = const ModelPreset(),
  }) : id = id ?? modelSource.displayName,
       url = modelSource.loadReference,
       filename = _sourceFilename(modelSource),
       mmprojUrl = multimodalProjectorSource is RemoteModelAssetSource
           ? multimodalProjectorSource.url
           : null,
       mmprojFilename = multimodalProjectorSource == null
           ? null
           : _sourceFilename(multimodalProjectorSource),
       _modelSourceOverride = modelSource,
       _multimodalProjectorSourceOverride = multimodalProjectorSource;

  ModelAssetSource get modelSource {
    final override = _modelSourceOverride;
    if (override != null) {
      return override;
    }
    return RemoteModelAssetSource(
      url: url,
      filename: filename,
      sizeBytes: sizeBytes,
    );
  }

  ModelAssetSource? get multimodalProjectorSource {
    final override = _multimodalProjectorSourceOverride;
    if (override != null) {
      return override;
    }
    if (mmprojUrl == null || mmprojFilename == null || mmprojUrl!.isEmpty) {
      return null;
    }
    return RemoteModelAssetSource(url: mmprojUrl!, filename: mmprojFilename!);
  }

  ModelCapabilities get capabilities => ModelCapabilities(
    supportsVision: supportsVision,
    supportsAudio: supportsAudio,
    supportsVideo: supportsVideo,
    supportsToolCalling: supportsToolCalling,
    supportsThinking: supportsThinking,
  );

  bool get isMultimodal => supportsVision || supportsAudio;

  String get sizeMb => (sizeBytes / (1024 * 1024)).toStringAsFixed(1);

  static const List<DownloadableModel> defaultModels = [
    DownloadableModel(
      name: 'FunctionGemma 270M',
      description:
          '🛠️ Tiny tools model (253MB) • Great function-calling demo.',
      url:
          'https://huggingface.co/unsloth/functiongemma-270m-it-GGUF/resolve/main/functiongemma-270m-it-Q4_K_M.gguf?download=true',
      filename: 'functiongemma-270m-it-Q4_K_M.gguf',
      sizeBytes: 253127904,
      minRamGb: 2,
      supportsToolCalling: true,
      preset: ModelPreset(
        temperature: 0.0,
        topK: 40,
        topP: 0.9,
        contextSize: 4096,
        maxTokens: 1024,
      ),
    ),
    DownloadableModel(
      name: 'Qwen3.5 0.8B Instruct',
      description:
          '🆕 Unsloth Q4_K_M bundle (720MB) • Consistent Qwen pick across web, mobile, and native with tuned non-thinking defaults.',
      url:
          'https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/resolve/main/Qwen3.5-0.8B-Q4_K_M.gguf?download=true',
      filename: 'Qwen3.5-0.8B-Q4_K_M.gguf',
      mmprojUrl:
          'https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/resolve/main/mmproj-F16.gguf?download=true',
      mmprojFilename: 'Qwen3.5-0.8B-mmproj-F16.gguf',
      sizeBytes: 754903104,
      minRamGb: 3,
      supportsVision: true,
      supportsToolCalling: true,
      supportsThinking: true,
      preset: ModelPreset(
        temperature: 0.7,
        topK: 20,
        topP: 0.8,
        penalty: 1.0,
        contextSize: 4096,
        maxTokens: 1024,
        thinkingEnabled: false,
      ),
    ),
    DownloadableModel(
      name: 'Llama 3.2 1B Instruct',
      description: '🧰 General + tools (808MB) • Reliable everyday assistant.',
      url:
          'https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf?download=true',
      filename: 'Llama-3.2-1B-Instruct-Q4_K_M.gguf',
      sizeBytes: 807694464,
      minRamGb: 3,
      supportsToolCalling: true,
      preset: ModelPreset(
        temperature: 0.2,
        topK: 40,
        topP: 0.9,
        contextSize: 8192,
        maxTokens: 2048,
      ),
    ),
    DownloadableModel(
      name: 'Gemma 3 1B it',
      description:
          '🧩 Gemma template (806MB) • Lightweight multilingual baseline.',
      url:
          'https://huggingface.co/ggml-org/gemma-3-1b-it-GGUF/resolve/main/gemma-3-1b-it-Q4_K_M.gguf?download=true',
      filename: 'gemma-3-1b-it-Q4_K_M.gguf',
      sizeBytes: 806058240,
      minRamGb: 3,
      preset: ModelPreset(
        temperature: 0.7,
        topK: 40,
        topP: 0.9,
        contextSize: 8192,
        maxTokens: 2048,
      ),
    ),
    DownloadableModel(
      name: 'LFM2.5 1.2B Instruct',
      description: '🌊 LFM baseline (731MB) • Popular small Liquid text model.',
      url:
          'https://huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct-GGUF/resolve/main/LFM2.5-1.2B-Instruct-Q4_K_M.gguf?download=true',
      filename: 'LFM2.5-1.2B-Instruct-Q4_K_M.gguf',
      sizeBytes: 730895168,
      minRamGb: 3,
      preset: ModelPreset(
        temperature: 0.2,
        topK: 40,
        topP: 0.9,
        contextSize: 8192,
        maxTokens: 2048,
      ),
    ),
    DownloadableModel(
      name: 'Qwen3.5 2B Instruct',
      description:
          '🆕 Unsloth Q4_K_M bundle (1.85GB) • Better Qwen quality with one cross-platform quant for web, mobile, and laptops.',
      url:
          'https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/main/Qwen3.5-2B-Q4_K_M.gguf?download=true',
      filename: 'Qwen3.5-2B-Q4_K_M.gguf',
      mmprojUrl:
          'https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/main/mmproj-F16.gguf?download=true',
      mmprojFilename: 'Qwen3.5-2B-mmproj-F16.gguf',
      sizeBytes: 1983861664,
      minRamGb: 5,
      supportsVision: true,
      supportsToolCalling: true,
      supportsThinking: true,
      preset: ModelPreset(
        temperature: 0.7,
        topK: 20,
        topP: 0.8,
        penalty: 1.0,
        contextSize: 8192,
        maxTokens: 1024,
        thinkingEnabled: false,
      ),
    ),
    DownloadableModel(
      name: 'Qwen3.5 4B Instruct',
      description:
          '🆕 Unsloth Q4_K_M bundle (3.29GB) • Best Qwen balance when you want one quant across web and native targets.',
      url:
          'https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/main/Qwen3.5-4B-Q4_K_M.gguf?download=true',
      filename: 'Qwen3.5-4B-Q4_K_M.gguf',
      mmprojUrl:
          'https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/main/mmproj-F16.gguf?download=true',
      mmprojFilename: 'Qwen3.5-4B-mmproj-F16.gguf',
      sizeBytes: 3529359968,
      minRamGb: 8,
      supportsVision: true,
      supportsToolCalling: true,
      supportsThinking: true,
      preset: ModelPreset(
        temperature: 0.7,
        topK: 20,
        topP: 0.8,
        penalty: 1.0,
        contextSize: 8192,
        maxTokens: 1024,
        thinkingEnabled: false,
      ),
    ),
    DownloadableModel(
      name: 'Gemma 4 E2B it',
      description:
          '🧪 Multimodal Gemma 4 vision bundle (2.83GB + 940MB mmproj) • Supports image input; audio support is not advertised by the current projector/runtime path.',
      url:
          'https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-Q4_K_S.gguf?download=true',
      filename: 'gemma-4-E2B-it-Q4_K_S.gguf',
      mmprojUrl:
          'https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/main/mmproj-F16.gguf?download=true',
      mmprojFilename: 'gemma-4-E2B-it-mmproj-F16.gguf',
      sizeBytes: 3043927168,
      minRamGb: 8,
      supportsVision: true,
      supportsAudio: false,
      supportsVideo: true,
      supportsToolCalling: true,
      supportsThinking: true,
      preset: ModelPreset(
        temperature: 0.7,
        topK: 64,
        topP: 0.95,
        penalty: 1.0,
        contextSize: 8192,
        maxTokens: 1024,
        thinkingEnabled: false,
      ),
    ),
    DownloadableModel(
      name: 'LFM2.5 1.2B Thinking',
      description:
          '🧠 Reasoning-focused LFM (731MB) • Good compact thinking model.',
      url:
          'https://huggingface.co/LiquidAI/LFM2.5-1.2B-Thinking-GGUF/resolve/main/LFM2.5-1.2B-Thinking-Q4_K_M.gguf?download=true',
      filename: 'LFM2.5-1.2B-Thinking-Q4_K_M.gguf',
      sizeBytes: 730895360,
      minRamGb: 3,
      supportsThinking: true,
      preset: ModelPreset(
        temperature: 0.05,
        topK: 50,
        topP: 0.1,
        contextSize: 16384,
        maxTokens: 4096,
      ),
    ),
    DownloadableModel(
      name: 'SmolVLM 500M Instruct',
      description:
          '👁️ Vision bundle (636MB) • Proven lightweight image understanding.',
      url:
          'https://huggingface.co/ggml-org/SmolVLM-500M-Instruct-GGUF/resolve/main/SmolVLM-500M-Instruct-Q8_0.gguf?download=true',
      filename: 'SmolVLM-500M-Instruct-Q8_0.gguf',
      mmprojUrl:
          'https://huggingface.co/ggml-org/SmolVLM-500M-Instruct-GGUF/resolve/main/mmproj-SmolVLM-500M-Instruct-f16.gguf?download=true',
      mmprojFilename: 'mmproj-SmolVLM-500M-Instruct-f16.gguf',
      sizeBytes: 636275712,
      minRamGb: 3,
      supportsVision: true,
      preset: ModelPreset(
        temperature: 0.2,
        topK: 40,
        topP: 0.9,
        contextSize: 4096,
        maxTokens: 1024,
      ),
    ),
    DownloadableModel(
      name: 'LFM2-VL 450M',
      description:
          '🖼️ Tiny VLM bundle (323MB) • Fast multimodal demo for mobile.',
      url:
          'https://huggingface.co/LiquidAI/LFM2-VL-450M-GGUF/resolve/main/LFM2-VL-450M-Q4_0.gguf?download=true',
      filename: 'LFM2-VL-450M-Q4_0.gguf',
      mmprojUrl:
          'https://huggingface.co/LiquidAI/LFM2-VL-450M-GGUF/resolve/main/mmproj-LFM2-VL-450M-Q8_0.gguf?download=true',
      mmprojFilename: 'mmproj-LFM2-VL-450M-Q8_0.gguf',
      sizeBytes: 323197440,
      minRamGb: 2,
      supportsVision: true,
      preset: ModelPreset(
        temperature: 0.2,
        topK: 40,
        topP: 0.9,
        contextSize: 8192,
        maxTokens: 1024,
      ),
    ),
    DownloadableModel(
      name: 'Ultravox v0.5 1B',
      description:
          '🎤 Audio bundle (2.18GB) • Reliable speech understanding demo.',
      url:
          'https://huggingface.co/ggml-org/ultravox-v0_5-llama-3_2-1b-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf?download=true',
      filename: 'ultravox-v0.5-1b-q4_k_m.gguf',
      mmprojUrl:
          'https://huggingface.co/ggml-org/ultravox-v0_5-llama-3_2-1b-GGUF/resolve/main/mmproj-ultravox-v0_5-llama-3_2-1b-f16.gguf?download=true',
      mmprojFilename: 'mmproj-ultravox-v0_5-llama-3_2-1b-f16.gguf',
      sizeBytes: 2178818080,
      minRamGb: 4,
      supportsAudio: true,
      preset: ModelPreset(
        temperature: 0.2,
        topK: 40,
        topP: 0.9,
        contextSize: 4096,
        maxTokens: 1024,
      ),
    ),
    DownloadableModel(
      name: 'Llama 3.2 3B Instruct',
      description:
          '🏠 Balanced large model (2.02GB) • Strong general assistant.',
      url:
          'https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf?download=true',
      filename: 'Llama-3.2-3B-Instruct-Q4_K_M.gguf',
      sizeBytes: 2019377696,
      minRamGb: 4,
      supportsToolCalling: true,
      preset: ModelPreset(
        temperature: 0.2,
        topK: 40,
        topP: 0.9,
        contextSize: 8192,
        maxTokens: 2048,
      ),
    ),
    DownloadableModel(
      name: 'Meta-Llama 3.1 8B Instruct',
      description:
          '🚀 Flagship quality (4.92GB) • Popular large model benchmark.',
      url:
          'https://huggingface.co/bartowski/Meta-Llama-3.1-8B-Instruct-GGUF/resolve/main/Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf?download=true',
      filename: 'Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf',
      sizeBytes: 4920739232,
      minRamGb: 8,
      supportsToolCalling: true,
      preset: ModelPreset(
        temperature: 0.2,
        topK: 40,
        topP: 0.9,
        contextSize: 8192,
        maxTokens: 2048,
      ),
    ),
    DownloadableModel(
      name: 'Qwen3.5 9B Instruct',
      description:
          '🆕 Unsloth Q4_K_M bundle (6.32GB) • Highest-quality Qwen preset with the same quant family across platforms.',
      url:
          'https://huggingface.co/unsloth/Qwen3.5-9B-GGUF/resolve/main/Qwen3.5-9B-Q4_K_M.gguf?download=true',
      filename: 'Qwen3.5-9B-Q4_K_M.gguf',
      mmprojUrl:
          'https://huggingface.co/unsloth/Qwen3.5-9B-GGUF/resolve/main/mmproj-F16.gguf?download=true',
      mmprojFilename: 'Qwen3.5-9B-mmproj-F16.gguf',
      sizeBytes: 6784286240,
      minRamGb: 12,
      supportsVision: true,
      supportsToolCalling: true,
      supportsThinking: true,
      preset: ModelPreset(
        temperature: 0.7,
        topK: 20,
        topP: 0.8,
        penalty: 1.0,
        contextSize: 8192,
        maxTokens: 1024,
        thinkingEnabled: false,
      ),
    ),
  ];
}
