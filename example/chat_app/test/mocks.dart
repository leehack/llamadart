import 'dart:async';
import 'dart:typed_data';

import 'package:llamadart/backend.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_chat_example/models/chat_settings.dart';
import 'package:llamadart_chat_example/services/chat_service.dart';
import 'package:llamadart_chat_example/services/settings_service.dart';

class MockLlamaBackend
    implements
        LlamaBackend,
        BackendAvailability,
        BackendPromptSpeechToTextSupport,
        BackendTextToSpeech {
  BackendTextToSpeechRequest? lastTextToSpeechRequest;
  bool textToSpeechCancelled = false;
  Completer<BackendTextToSpeechResult>? textToSpeechResultCompleter;
  final List<String> loadedModelPaths = <String>[];
  int modelFreeCalls = 0;
  void Function()? onModelLoad;

  @override
  bool get isReady => true;
  @override
  Future<int> modelLoad(String path, ModelParams params) async {
    onModelLoad?.call();
    loadedModelPaths.add(path);
    return 1;
  }

  @override
  Future<int> modelLoadFromUrl(
    String url,
    ModelParams params, {
    Function(double progress)? onProgress,
  }) async => 1;
  @override
  Future<void> modelFree(int modelHandle) async {
    modelFreeCalls += 1;
  }

  @override
  Future<int> contextCreate(int modelHandle, ModelParams params) async => 1;
  @override
  Future<void> contextFree(int contextHandle) async {}

  @override
  Future<int> getContextSize(int contextHandle) async => 2048;
  @override
  Stream<List<int>> generate(
    int contextHandle,
    String prompt,
    GenerationParams params, {
    List<LlamaContentPart>? parts,
  }) async* {
    yield [72, 105, 32, 116, 104, 101, 114, 101]; // "Hi there"
  }

  @override
  void cancelGeneration() {}
  @override
  Future<List<int>> tokenize(
    int modelHandle,
    String text, {
    bool addSpecial = true,
  }) async => [1, 2, 3];
  @override
  Future<String> detokenize(
    int modelHandle,
    List<int> tokens, {
    bool special = false,
  }) async => "mock";
  @override
  Future<Map<String, String>> modelMetadata(int modelHandle) async => {
    "llama.context_length": "2048",
  };
  @override
  Future<void> setLoraAdapter(
    int contextHandle,
    String path,
    double scale,
  ) async {}
  @override
  Future<void> removeLoraAdapter(int contextHandle, String path) async {}
  @override
  Future<void> clearLoraAdapters(int contextHandle) async {}
  @override
  Future<String> getBackendName() async => "Mock";
  @override
  Future<String> getAvailableBackends() async => "Mock";
  @override
  bool get supportsPromptSpeechToText => true;
  @override
  String? get promptSpeechToTextUnsupportedReason => null;
  @override
  bool get supportsUrlLoading => false;
  @override
  Future<bool> isGpuSupported() async => true;
  @override
  Future<void> setLogLevel(LlamaLogLevel level) async {}
  @override
  Future<void> dispose() async {}

  @override
  Future<int?> multimodalContextCreate(
    int modelHandle,
    String mmProjPath,
  ) async => 1;

  @override
  Future<void> multimodalContextFree(int mmContextHandle) async {}

  @override
  Future<bool> supportsAudio(int mmContextHandle) async => false;

  @override
  Future<bool> supportsVision(int mmContextHandle) async => false;

  @override
  Future<({int total, int free})> getVramInfo() async =>
      (total: 8 * 1024 * 1024 * 1024, free: 4 * 1024 * 1024 * 1024);

  @override
  Future<String> applyChatTemplate(
    int modelHandle,
    List<Map<String, dynamic>> messages, {
    String? customTemplate,
    bool addAssistant = true,
  }) async {
    return messages.map((m) => "${m['role']}: ${m['content']}").join('\n');
  }

  @override
  Future<BackendTextToSpeechCapabilities> textToSpeechCapabilities(
    int contextHandle,
    int mmContextHandle,
  ) async => const BackendTextToSpeechCapabilities(
    isSupported: true,
    model: BackendTextToSpeechModel.qwen3Tts,
    sampleRateHz: 24000,
    channelCount: 1,
    supportsLanguage: true,
    supportsSpeakerReference: true,
    supportsCancellation: true,
  );

  @override
  Future<BackendTextToSpeechResult> synthesizeTextToSpeech(
    int contextHandle,
    int mmContextHandle,
    BackendTextToSpeechRequest request, {
    void Function(BackendTextToSpeechProgress progress)? onProgress,
  }) async {
    lastTextToSpeechRequest = request;
    onProgress?.call(
      const BackendTextToSpeechProgress(
        phase: BackendTextToSpeechPhase.generating,
        promptTokensRemaining: 0,
        framesGenerated: 2,
        truncated: false,
      ),
    );
    final result = BackendTextToSpeechResult(
      samples: Float32List.fromList(const <double>[0, 0.25, -0.25, 0]),
      sampleRateHz: 24000,
      channelCount: 1,
      framesGenerated: 2,
      truncated: false,
    );
    final completer = textToSpeechResultCompleter;
    return completer == null ? result : completer.future;
  }

  @override
  void cancelTextToSpeech() {
    textToSpeechCancelled = true;
  }
}

/// Resolves every source without touching the file system or the network: a
/// local path to itself and a remote file to a cache path.
class FakeModelDownloadManager extends ThrowingModelDownloadManager {
  @override
  Future<ModelCacheEntry> ensureModel(
    ModelSource source, {
    ModelLoadOptions options = ModelLoadOptions.defaults,
    ModelDownloadProgressCallback? onProgress,
  }) async {
    final now = DateTime.utc(2026);
    return ModelCacheEntry(
      sourceCanonicalKey: source.metadataSourceKey,
      cacheKey: source.cacheKey,
      fileName: source.fileName,
      filePath: source.path ?? '/cache/${source.fileName}',
      bytes: 1,
      createdAt: now,
      updatedAt: now,
    );
  }
}

class MockLlamaEngine extends LlamaEngine {
  bool initialized = false;
  bool mmprojLoaded = false;
  int loadMultimodalProjectorCalls = 0;
  int unloadMultimodalProjectorCalls = 0;
  int createCalls = 0;
  ModelParams? lastModelParams;
  GenerationParams? lastCreateParams;
  bool? lastCreateEnableThinking;
  Map<String, dynamic>? lastCreateChatTemplateKwargs;
  List<LlamaChatMessage>? lastCreateMessages;
  BackendPerfContextData? performanceContext;
  List<String> createChunkContents = const ['Hi there'];
  bool rejectMediaWithoutProjector = false;
  String? lastLoadedModelPath;
  String? lastLoadedMmprojPath;
  String? lastLoadedModelUrl;

  LlamaEngineCapabilities loadedCapabilities = const LlamaEngineCapabilities(
    isSupported: true,
    runtime: LlamaRuntime.llamaCpp,
    supportsMultiTurnChat: true,
    supportsToolCalling: true,
    supportsStructuredOutput: true,
    supportsGrammar: true,
    supportsLazyGrammar: true,
    supportsPenalty: true,
    supportsPresencePenalty: true,
    supportsMinP: true,
    supportsThinkingBudget: true,
    supportsStreamBatching: true,
  );

  MockLlamaEngine()
    : super(
        MockLlamaBackend(),
        modelDownloadManager: FakeModelDownloadManager(),
      );

  MockLlamaBackend get mockBackend => backend as MockLlamaBackend;

  @override
  Future<LlamaEngineCapabilities> get capabilities async => initialized
      ? loadedCapabilities
      : const LlamaEngineCapabilities(isSupported: false);

  @override
  LlamaRuntime? get runtime => initialized ? loadedCapabilities.runtime : null;

  @override
  bool get isReady => initialized;

  @override
  Future<void> setModel(
    LlamaModel model, {
    ModelParams params = const ModelParams(),
    ModelLoadOptions download = ModelLoadOptions.defaults,
    ModelDownloadProgressCallback? onProgress,
  }) async {
    final source = model.source;
    if (source.isLocal) {
      lastLoadedModelPath = source.path;
    } else {
      lastLoadedModelUrl = source.resolvedUri.toString();
    }
    lastModelParams = params;
    await super.setModel(
      model,
      params: params,
      download: download,
      onProgress: onProgress,
    );
    initialized = true;
  }

  @override
  Future<void> loadMultimodalProjectorSource(
    ModelSource source, {
    ModelLoadOptions? download,
    ModelLoadOptions? options,
    ModelDownloadProgressCallback? onProgress,
  }) async {
    loadMultimodalProjectorCalls += 1;
    lastLoadedMmprojPath = source.path ?? source.resolvedUri.toString();
    await super.loadMultimodalProjectorSource(
      source,
      download: download,
      onProgress: onProgress,
    );
    mmprojLoaded = true;
  }

  @override
  Future<void> unloadMultimodalProjector() async {
    unloadMultimodalProjectorCalls += 1;
    await super.unloadMultimodalProjector();
    mmprojLoaded = false;
  }

  @override
  Future<bool> get supportsVision async => mmprojLoaded;

  @override
  Future<bool> get supportsAudio async => false;

  @override
  Future<LlamaChatTemplateResult> chatTemplate(
    List<LlamaChatMessage> messages, {
    bool addAssistant = true,
    Map<String, dynamic>? jsonSchema,
    List<ToolDefinition>? tools,
    ToolChoice toolChoice = ToolChoice.auto,
    bool parallelToolCalls = false,
    bool enableThinking = true,
    Map<String, dynamic>? responseFormat,
    String? customTemplate,
    String? sourceLangCode,
    String? targetLangCode,
    bool includeTokenCount = true,
    Map<String, dynamic>? chatTemplateKwargs,
    DateTime? templateNow,
  }) async {
    return const LlamaChatTemplateResult(
      prompt: "mock prompt",
      additionalStops: [],
      tokenCount: 5,
    );
  }

  @override
  Stream<LlamaCompletionChunk> create(
    List<LlamaChatMessage> messages, {
    GenerationParams? params,
    List<ToolDefinition>? tools,
    ToolChoice? toolChoice,
    bool parallelToolCalls = false,
    bool enableThinking = true,
    Map<String, dynamic>? responseFormat,
    String? sourceLangCode,
    String? targetLangCode,
    Map<String, dynamic>? chatTemplateKwargs,
    DateTime? templateNow,
  }) async* {
    createCalls += 1;
    lastCreateParams = params;
    lastCreateEnableThinking = enableThinking;
    lastCreateChatTemplateKwargs = chatTemplateKwargs == null
        ? null
        : Map<String, dynamic>.from(chatTemplateKwargs);
    lastCreateMessages = List<LlamaChatMessage>.from(messages);
    if (rejectMediaWithoutProjector &&
        !mmprojLoaded &&
        messages.any(
          (message) => message.parts.any(
            (part) => part is LlamaImageContent || part is LlamaAudioContent,
          ),
        )) {
      throw LlamaUnsupportedException(
        'Image and audio input require a loaded multimodal projector.',
      );
    }
    for (final content in createChunkContents) {
      yield LlamaCompletionChunk(
        id: "mock-id",
        object: "chat.completion.chunk",
        created: 1234567890,
        model: "mock-model",
        choices: [
          LlamaCompletionChunkChoice(
            index: 0,
            delta: LlamaCompletionChunkDelta(content: content),
          ),
        ],
      );
    }
  }

  @override
  Future<int> getContextSize() async => 2048;

  @override
  Future<int> getTokenCount(String text) async => 5;

  @override
  Future<BackendPerfContextData?> getPerformanceContext() async =>
      performanceContext;
}

class MockSettingsService implements SettingsService {
  ChatSettings settings = const ChatSettings(modelPath: "mock.gguf");
  bool liveSpeechEnabled = true;
  String? liveSpeechModelId;

  @override
  Future<ChatSettings> loadSettings() async => settings;

  @override
  Future<bool> loadLiveSpeechEnabled() async => liveSpeechEnabled;

  @override
  Future<String?> loadLiveSpeechModelId() async => liveSpeechModelId;

  @override
  Future<void> saveSettings(ChatSettings newSettings) async {
    settings = newSettings;
  }

  @override
  Future<void> saveLiveSpeechEnabled(bool enabled) async {
    liveSpeechEnabled = enabled;
  }

  @override
  Future<void> saveLiveSpeechModelId(String modelId) async {
    liveSpeechModelId = modelId;
  }
}

class MockChatService extends ChatService {
  final MockLlamaEngine mockEngine;

  MockChatService({MockLlamaEngine? engine})
    : mockEngine = engine ?? MockLlamaEngine(),
      super(engine: engine ?? MockLlamaEngine());

  @override
  LlamaEngine get engine => mockEngine;

  @override
  Future<void> init(
    ChatSettings settings, {
    Function(double progress)? onProgress,
    bool eagerLoadMultimodalProjector = true,
    bool eagerWarmUpLiteRtLmRuntime = true,
  }) async {
    if (settings.modelPath == null || settings.modelPath!.isEmpty) {
      throw Exception("Invalid model path");
    }
    await mockEngine.setModel(
      LlamaModel(ChatService.modelSourceFor(settings.modelPath!)),
    );
    if (eagerLoadMultimodalProjector &&
        settings.mmprojPath != null &&
        settings.mmprojPath!.isNotEmpty) {
      await mockEngine.loadMultimodalProjectorSource(
        ChatService.modelSourceFor(settings.mmprojPath!),
      );
    }
  }

  @override
  String cleanResponse(String response) => response;
}
