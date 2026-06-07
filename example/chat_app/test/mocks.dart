import 'dart:async';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_chat_example/models/chat_settings.dart';
import 'package:llamadart_chat_example/services/chat_service.dart';
import 'package:llamadart_chat_example/services/settings_service.dart';

class MockLlamaBackend implements LlamaBackend, BackendAvailability {
  @override
  bool get isReady => true;
  @override
  Future<int> modelLoad(String path, ModelParams params) async => 1;
  @override
  Future<int> modelLoadFromUrl(
    String url,
    ModelParams params, {
    Function(double progress)? onProgress,
  }) async => 1;
  @override
  Future<void> modelFree(int modelHandle) async {}
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
}

class MockLlamaEngine extends LlamaEngine {
  bool initialized = false;
  bool mmprojLoaded = false;
  int loadMultimodalProjectorCalls = 0;
  int unloadMultimodalProjectorCalls = 0;
  int createCalls = 0;
  ModelParams? lastModelParams;
  GenerationParams? lastCreateParams;
  BackendPerfContextData? performanceContext;
  List<String> createChunkContents = const ['Hi there'];
  String? lastLoadedModelPath;
  String? lastLoadedModelUrl;

  MockLlamaEngine() : super(MockLlamaBackend());

  @override
  bool get isReady => initialized;

  @override
  Future<void> loadModel(
    String path, {
    ModelParams modelParams = const ModelParams(),
  }) async {
    lastLoadedModelPath = path;
    lastModelParams = modelParams;
    initialized = true;
  }

  @override
  Future<void> loadModelFromUrl(
    String url, {
    ModelParams modelParams = const ModelParams(),
    Function(double progress)? onProgress,
  }) async {
    lastLoadedModelUrl = url;
    lastModelParams = modelParams;
    initialized = true;
  }

  @override
  Future<void> loadMultimodalProjector(String mmProjPath) async {
    loadMultimodalProjectorCalls += 1;
    mmprojLoaded = true;
  }

  @override
  Future<void> unloadMultimodalProjector() async {
    unloadMultimodalProjectorCalls += 1;
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

  @override
  Future<ChatSettings> loadSettings() async => settings;

  @override
  Future<void> saveSettings(ChatSettings newSettings) async {
    settings = newSettings;
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
  }) async {
    if (settings.modelPath == null || settings.modelPath!.isEmpty) {
      throw Exception("Invalid model path");
    }
    await mockEngine.loadModel(settings.modelPath!);
    if (eagerLoadMultimodalProjector &&
        settings.mmprojPath != null &&
        settings.mmprojPath!.isNotEmpty) {
      await mockEngine.loadMultimodalProjector(settings.mmprojPath!);
    }
  }

  @override
  String cleanResponse(String response) => response;
}
