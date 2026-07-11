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

enum ModelMediaInputMode { externalProjector, direct, none }

enum ModelAvailability { all, nativeDesktop }

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
  final int? webSizeBytes;
  final bool supportsVision;
  final bool supportsAudio;
  final bool supportsVideo;
  final bool? webSupportsVision;
  final bool? webSupportsAudio;
  final bool? webSupportsVideo;
  final ModelMediaInputMode mediaInputMode;
  final ModelMediaInputMode? webMediaInputMode;
  final bool supportsToolCalling;
  final bool supportsThinking;
  final String? distribution;
  final ModelAvailability availability;
  final ModelAssetSource? _modelSourceOverride;
  final ModelAssetSource? _multimodalProjectorSourceOverride;
  final ModelAssetSource? _webModelSourceOverride;
  final ModelAssetSource? _webMultimodalProjectorSourceOverride;

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
    this.webSizeBytes,
    ModelAssetSource? webModelSource,
    ModelAssetSource? webMultimodalProjectorSource,
    this.mmprojUrl,
    this.mmprojFilename,
    this.supportsVision = false,
    this.supportsAudio = false,
    this.supportsVideo = false,
    this.webSupportsVision,
    this.webSupportsAudio,
    this.webSupportsVideo,
    this.mediaInputMode = ModelMediaInputMode.externalProjector,
    this.webMediaInputMode,
    this.supportsToolCalling = false,
    this.supportsThinking = false,
    this.distribution,
    this.availability = ModelAvailability.all,
    this.minRamGb = 2,
    this.preset = const ModelPreset(),
  }) : id = filename,
       _modelSourceOverride = null,
       _multimodalProjectorSourceOverride = null,
       _webModelSourceOverride = webModelSource,
       _webMultimodalProjectorSourceOverride = webMultimodalProjectorSource;

  DownloadableModel.fromSources({
    String? id,
    required this.name,
    required this.description,
    required ModelAssetSource modelSource,
    ModelAssetSource? multimodalProjectorSource,
    ModelAssetSource? webModelSource,
    ModelAssetSource? webMultimodalProjectorSource,
    this.sizeBytes = 0,
    this.webSizeBytes,
    this.supportsVision = false,
    this.supportsAudio = false,
    this.supportsVideo = false,
    this.webSupportsVision,
    this.webSupportsAudio,
    this.webSupportsVideo,
    this.mediaInputMode = ModelMediaInputMode.externalProjector,
    this.webMediaInputMode,
    this.supportsToolCalling = false,
    this.supportsThinking = false,
    this.distribution,
    this.availability = ModelAvailability.all,
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
       _multimodalProjectorSourceOverride = multimodalProjectorSource,
       _webModelSourceOverride = webModelSource,
       _webMultimodalProjectorSourceOverride = webMultimodalProjectorSource;

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

  ModelAssetSource get webModelSource => _webModelSourceOverride ?? modelSource;

  ModelAssetSource? get webMultimodalProjectorSource =>
      _webMultimodalProjectorSourceOverride ?? multimodalProjectorSource;

  ModelAssetSource modelSourceFor({required bool web}) {
    return web ? webModelSource : modelSource;
  }

  ModelAssetSource? multimodalProjectorSourceFor({required bool web}) {
    return web ? webMultimodalProjectorSource : multimodalProjectorSource;
  }

  int sizeBytesFor({required bool web}) {
    if (web && webSizeBytes != null) {
      return webSizeBytes!;
    }
    final source = modelSourceFor(web: web);
    if (source is RemoteModelAssetSource && source.sizeBytes != null) {
      return source.sizeBytes!;
    }
    return sizeBytes;
  }

  String filenameFor({required bool web}) {
    return _sourceFilename(modelSourceFor(web: web));
  }

  ModelCapabilities get capabilities => ModelCapabilities(
    supportsVision: supportsVision,
    supportsAudio: supportsAudio,
    supportsVideo: supportsVideo,
    supportsToolCalling: supportsToolCalling,
    supportsThinking: supportsThinking,
  );

  bool supportsVisionFor({required bool web}) =>
      web ? webSupportsVision ?? supportsVision : supportsVision;

  bool supportsAudioFor({required bool web}) =>
      web ? webSupportsAudio ?? supportsAudio : supportsAudio;

  bool supportsVideoFor({required bool web}) =>
      web ? webSupportsVideo ?? supportsVideo : supportsVideo;

  ModelMediaInputMode mediaInputModeFor({required bool web}) =>
      web ? webMediaInputMode ?? mediaInputMode : mediaInputMode;

  bool isMultimodalFor({required bool web}) =>
      supportsVisionFor(web: web) || supportsAudioFor(web: web);

  bool get isMultimodal => supportsVision || supportsAudio;

  String get sizeMb => (sizeBytes / (1024 * 1024)).toStringAsFixed(1);

  String sizeLabelFor({required bool web}) {
    final bytes = sizeBytesFor(web: web);
    final gibibytes = bytes / (1024 * 1024 * 1024);
    if (gibibytes >= 1) {
      final digits = gibibytes >= 10 ? 1 : 2;
      return '${gibibytes.toStringAsFixed(digits)} GB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
  }

  bool get isNativeDesktopOnly =>
      availability == ModelAvailability.nativeDesktop;

  bool isAvailableFor({required bool web, required bool mobile}) =>
      availability == ModelAvailability.all || (!web && !mobile);

  static const List<DownloadableModel> defaultModels = [
    DownloadableModel(
      name: 'FunctionGemma 270M',
      description: 'Tiny specialist for function calling and tool-use demos.',
      url:
          'https://huggingface.co/unsloth/functiongemma-270m-it-GGUF/resolve/main/functiongemma-270m-it-Q4_K_M.gguf?download=true',
      filename: 'functiongemma-270m-it-Q4_K_M.gguf',
      sizeBytes: 253127904,
      distribution: 'Unsloth',
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
      description: 'Small general assistant with tools, reasoning, and vision.',
      url:
          'https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/resolve/main/Qwen3.5-0.8B-Q4_K_M.gguf?download=true',
      filename: 'Qwen3.5-0.8B-Q4_K_M.gguf',
      mmprojUrl:
          'https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/resolve/main/mmproj-F16.gguf?download=true',
      mmprojFilename: 'Qwen3.5-0.8B-mmproj-F16.gguf',
      sizeBytes: 754903104,
      distribution: 'Unsloth',
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
      name: 'Gemma 4 E2B it',
      description:
          'Compact multimodal assistant for image, audio, and video input.',
      url:
          'https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-Q4_K_S.gguf?download=true',
      filename: 'gemma-4-E2B-it-Q4_K_S.gguf',
      mmprojUrl:
          'https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/main/mmproj-F16.gguf?download=true',
      mmprojFilename: 'gemma-4-E2B-it-mmproj-F16.gguf',
      sizeBytes: 3043927168,
      distribution: 'Unsloth',
      minRamGb: 8,
      supportsVision: true,
      supportsAudio: true,
      webSupportsAudio: false,
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
      name: 'Gemma 4 E2B LiteRT-LM',
      description:
          'Optimized LiteRT-LM variant with native audio and text-only Web support.',
      url:
          'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm?download=true',
      filename: 'gemma-4-E2B-it.litertlm',
      sizeBytes: 2588147712,
      webSizeBytes: 2008432640,
      webModelSource: RemoteModelAssetSource(
        url:
            'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it-web.litertlm?download=true',
        filename: 'gemma-4-E2B-it-web.litertlm',
        sizeBytes: 2008432640,
      ),
      distribution: 'LiteRT Community',
      minRamGb: 8,
      supportsAudio: true,
      webSupportsAudio: false,
      mediaInputMode: ModelMediaInputMode.direct,
      webMediaInputMode: ModelMediaInputMode.none,
      supportsThinking: true,
      preset: ModelPreset(
        temperature: 0.7,
        topK: 64,
        topP: 0.95,
        contextSize: 8192,
        maxTokens: 1024,
        thinkingEnabled: false,
      ),
    ),
    DownloadableModel(
      name: 'Gemma 4 E4B it',
      description:
          'Higher-quality multimodal model for capable edge and desktop devices.',
      url:
          'https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF/resolve/main/gemma-4-E4B-it-Q4_K_S.gguf?download=true',
      filename: 'gemma-4-E4B-it-Q4_K_S.gguf',
      mmprojUrl:
          'https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF/resolve/main/mmproj-F16.gguf?download=true',
      mmprojFilename: 'gemma-4-E4B-it-mmproj-F16.gguf',
      sizeBytes: 4844848288,
      distribution: 'Unsloth',
      minRamGb: 12,
      supportsVision: true,
      supportsAudio: true,
      webSupportsAudio: false,
      supportsVideo: true,
      supportsToolCalling: true,
      supportsThinking: true,
      preset: ModelPreset(
        temperature: 0.7,
        topK: 64,
        topP: 0.95,
        penalty: 1.0,
        contextSize: 8192,
        maxTokens: 2048,
        thinkingEnabled: false,
      ),
    ),
    DownloadableModel(
      name: 'Gemma 4 12B it',
      description:
          'Strong multimodal reasoning for higher-memory desktop systems.',
      url:
          'https://huggingface.co/unsloth/gemma-4-12b-it-GGUF/resolve/main/gemma-4-12b-it-Q4_K_S.gguf?download=true',
      filename: 'gemma-4-12b-it-Q4_K_S.gguf',
      mmprojUrl:
          'https://huggingface.co/unsloth/gemma-4-12b-it-GGUF/resolve/main/mmproj-F16.gguf?download=true',
      mmprojFilename: 'gemma-4-12b-it-mmproj-F16.gguf',
      sizeBytes: 6764524960,
      distribution: 'Unsloth',
      availability: ModelAvailability.nativeDesktop,
      minRamGb: 16,
      supportsVision: true,
      supportsAudio: true,
      supportsVideo: true,
      supportsToolCalling: true,
      supportsThinking: true,
      preset: ModelPreset(
        temperature: 0.7,
        topK: 64,
        topP: 0.95,
        penalty: 1.0,
        contextSize: 8192,
        maxTokens: 2048,
        thinkingEnabled: false,
      ),
    ),
    DownloadableModel(
      name: 'Gemma 4 26B A4B it',
      description:
          'Efficient mixture-of-experts model for reasoning, coding, and vision.',
      url:
          'https://huggingface.co/unsloth/gemma-4-26B-A4B-it-GGUF/resolve/main/gemma-4-26B-A4B-it-UD-Q4_K_S.gguf?download=true',
      filename: 'gemma-4-26B-A4B-it-UD-Q4_K_S.gguf',
      mmprojUrl:
          'https://huggingface.co/unsloth/gemma-4-26B-A4B-it-GGUF/resolve/main/mmproj-F16.gguf?download=true',
      mmprojFilename: 'gemma-4-26B-A4B-it-mmproj-F16.gguf',
      sizeBytes: 16487608096,
      distribution: 'Unsloth',
      availability: ModelAvailability.nativeDesktop,
      minRamGb: 24,
      supportsVision: true,
      supportsVideo: true,
      supportsToolCalling: true,
      supportsThinking: true,
      preset: ModelPreset(
        temperature: 0.7,
        topK: 64,
        topP: 0.95,
        penalty: 1.0,
        contextSize: 16384,
        maxTokens: 4096,
        thinkingEnabled: false,
      ),
    ),
    DownloadableModel(
      name: 'Gemma 4 31B it',
      description:
          'Highest-quality dense Gemma tier for high-memory workstations.',
      url:
          'https://huggingface.co/unsloth/gemma-4-31B-it-GGUF/resolve/main/gemma-4-31B-it-Q4_K_S.gguf?download=true',
      filename: 'gemma-4-31B-it-Q4_K_S.gguf',
      mmprojUrl:
          'https://huggingface.co/unsloth/gemma-4-31B-it-GGUF/resolve/main/mmproj-F16.gguf?download=true',
      mmprojFilename: 'gemma-4-31B-it-mmproj-F16.gguf',
      sizeBytes: 17399833600,
      distribution: 'Unsloth',
      availability: ModelAvailability.nativeDesktop,
      minRamGb: 32,
      supportsVision: true,
      supportsVideo: true,
      supportsToolCalling: true,
      supportsThinking: true,
      preset: ModelPreset(
        temperature: 0.7,
        topK: 64,
        topP: 0.95,
        penalty: 1.0,
        contextSize: 16384,
        maxTokens: 4096,
        thinkingEnabled: false,
      ),
    ),
    DownloadableModel(
      name: 'Qwen3.6 35B A3B',
      description:
          'Fast mixture-of-experts model for coding, agentic workflows, and vision.',
      url:
          'https://huggingface.co/unsloth/Qwen3.6-35B-A3B-GGUF/resolve/main/Qwen3.6-35B-A3B-UD-Q4_K_S.gguf?download=true',
      filename: 'Qwen3.6-35B-A3B-UD-Q4_K_S.gguf',
      mmprojUrl:
          'https://huggingface.co/unsloth/Qwen3.6-35B-A3B-GGUF/resolve/main/mmproj-F16.gguf?download=true',
      mmprojFilename: 'Qwen3.6-35B-A3B-mmproj-F16.gguf',
      sizeBytes: 20893015008,
      distribution: 'Unsloth',
      availability: ModelAvailability.nativeDesktop,
      minRamGb: 32,
      supportsVision: true,
      supportsToolCalling: true,
      supportsThinking: true,
      preset: ModelPreset(
        temperature: 0.7,
        topK: 20,
        topP: 0.8,
        penalty: 1.0,
        contextSize: 16384,
        maxTokens: 4096,
        thinkingEnabled: false,
      ),
    ),
  ];
}
