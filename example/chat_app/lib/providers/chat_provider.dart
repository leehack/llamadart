import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:llamadart/llamadart.dart';

import '../models/chat_conversation.dart';
import '../models/chat_message.dart';
import '../models/chat_settings.dart';
import '../models/downloadable_model.dart';
import '../services/assistant_output_service.dart';
import '../services/chat_service.dart';
import '../services/chat_generation_service.dart';
import '../services/chat_session_service.dart';
import '../services/conversation_state_service.dart';
import '../services/runtime_profile_service.dart';
import '../services/settings_service.dart';
import '../services/tool_declaration_service.dart';
import '../utils/backend_utils.dart';

class ChatProvider extends ChangeNotifier {
  static const String _defaultToolDeclarationsJson = '''
[
  {
    "name": "getWeather",
    "description": "gets the weather for a requested city",
    "parameters": {
      "type": "object",
      "properties": {
        "city": {
          "type": "string"
        }
      },
      "required": ["city"]
    }
  }
]
''';
  static const Duration _settingsSaveDebounceDelay = Duration(
    milliseconds: 220,
  );
  static const int _multimodalMaxImageEdge = 384;
  static const String _androidDebugImagePath = String.fromEnvironment(
    'LLAMADART_CHAT_APP_DEBUG_IMAGE_PATH',
    defaultValue: '',
  );

  final ChatService _chatService;
  final ChatGenerationService _chatGenerationService;
  final ChatSessionService _chatSessionService;
  final ConversationStateService _conversationStateService;
  final RuntimeProfileService _runtimeProfileService;
  final SettingsService _settingsService;
  final AssistantOutputService _assistantOutputService;
  final ToolDeclarationService _toolDeclarationService;

  final List<ChatMessage> _messages = [];
  final List<LlamaContentPart> _stagedParts = [];
  final List<ChatConversation> _conversations = [];
  ChatSettings _settings = const ChatSettings();
  String _activeConversationId = '';
  String? _loadedModelPath;
  String? _loadedMmprojPath;
  bool _mmprojLoaded = false;

  // Chat session for stateful conversation
  ChatSession? _session;

  // Tool declarations supplied by the user (schema only; no local execution).
  List<ToolDefinition> _declaredTools = const <ToolDefinition>[];
  String? _toolDeclarationsError;

  String _activeBackend = "Unknown";
  bool _isInitializing = false;
  double _loadingProgress = 0.0;
  bool _isLoaded = false;
  bool _isGenerating = false;
  bool _isShuttingDown = false;
  bool _supportsVision = false;
  bool _supportsAudio = false;
  bool _templateSupportsTools = true;
  ChatFormat? _detectedChatFormat;
  String? _error;
  Timer? _settingsSaveDebounce;

  // Telemetry
  int _contextLimit = 2048;
  int _currentTokens = 0;
  bool _isPruning = false;
  int? _runtimeGpuLayers;
  int? _runtimeThreads;
  int? _runtimeThreadPoolSize;
  String? _runtimeExecution;
  String? _runtimeCoreVariant;
  String? _runtimeWorkerFallbackReason;
  String? _runtimeNotes;
  String? _runtimeModelSource;
  String? _runtimeModelCacheState;
  int? _lastFirstTokenLatencyMs;
  int? _lastGenerationLatencyMs;
  double? _lastTokensPerSecond;
  double? _lastDecodeTokensPerSecond;
  int? _lastNativePromptEvalMs;
  int? _lastNativeEvalMs;
  int? _lastNativeSampleMs;
  int? _lastNativePromptEvalTokens;
  int? _lastNativeEvalTokens;
  int? _lastNativeReusedGraphs;

  List<String> _availableDevices = [];

  // Getters
  List<ChatMessage> get messages => List.unmodifiable(_messages);
  List<LlamaContentPart> get stagedParts => List.unmodifiable(_stagedParts);
  List<ChatConversation> get conversations {
    final sorted = List<ChatConversation>.from(_conversations)
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return List.unmodifiable(sorted);
  }

  String get activeConversationId => _activeConversationId;
  ChatSettings get settings => _settings;
  String? get modelPath => _settings.modelPath;
  GpuBackend get preferredBackend => _settings.preferredBackend;
  String get activeBackend => _activeBackend;
  bool get isInitializing => _isInitializing;
  double get loadingProgress => _loadingProgress;
  bool get isLoaded => _isLoaded;
  bool get isGenerating => _isGenerating;
  bool get supportsVision => _supportsVision;
  bool get supportsAudio => _supportsAudio;
  bool get templateSupportsTools => _templateSupportsTools;
  String? get error => _error;
  double get temperature => _settings.temperature;
  int get topK => _settings.topK;
  double get topP => _settings.topP;
  double get minP => _settings.minP;
  double get penalty => _settings.penalty;
  int get contextSize => _settings.contextSize;
  int get gpuLayers => _settings.gpuLayers;
  int get numberOfThreads => _settings.numberOfThreads;
  int get numberOfThreadsBatch => _settings.numberOfThreadsBatch;
  LlamaLogLevel get dartLogLevel => _settings.logLevel;
  LlamaLogLevel get nativeLogLevel => _settings.nativeLogLevel;
  int get contextLimit => _contextLimit; // Renamed from maxTokens
  int get maxGenerationTokens => _settings.maxTokens;
  int get currentTokens => _currentTokens;
  bool get isPruning => _isPruning;
  List<String> get availableDevices => _availableDevices;
  int? get runtimeGpuLayers => _runtimeGpuLayers;
  int? get runtimeThreads => _runtimeThreads;
  int? get runtimeThreadPoolSize => _runtimeThreadPoolSize;
  String? get runtimeExecution => _runtimeExecution;
  String? get runtimeCoreVariant => _runtimeCoreVariant;
  String? get runtimeWorkerFallbackReason => _runtimeWorkerFallbackReason;
  String? get runtimeNotes => _runtimeNotes;
  String? get runtimeModelSource => _runtimeModelSource;
  String? get runtimeModelCacheState => _runtimeModelCacheState;
  int? get lastFirstTokenLatencyMs => _lastFirstTokenLatencyMs;
  int? get lastGenerationLatencyMs => _lastGenerationLatencyMs;
  double? get lastTokensPerSecond => _lastTokensPerSecond;
  double? get lastDecodeTokensPerSecond => _lastDecodeTokensPerSecond;
  int? get lastNativePromptEvalMs => _lastNativePromptEvalMs;
  int? get lastNativeEvalMs => _lastNativeEvalMs;
  int? get lastNativeSampleMs => _lastNativeSampleMs;
  int? get lastNativePromptEvalTokens => _lastNativePromptEvalTokens;
  int? get lastNativeEvalTokens => _lastNativeEvalTokens;
  int? get lastNativeReusedGraphs => _lastNativeReusedGraphs;
  bool get hasConfiguredMmproj =>
      (_settings.mmprojPath ?? '').trim().isNotEmpty;
  bool get isMmprojLoaded => _mmprojLoaded;
  bool get canAttachMedia =>
      _supportsVision || _supportsAudio || (_isLoaded && hasConfiguredMmproj);
  String get activeModelName {
    final modelPath = _settings.modelPath;
    if (modelPath == null || modelPath.isEmpty) {
      return 'No model';
    }
    final normalized = modelPath.replaceAll('\\', '/');
    final pieces = normalized.split('/');
    final file = pieces.isNotEmpty ? pieces.last : modelPath;
    return file.split('?').first;
  }

  bool get toolsEnabled => _settings.toolsEnabled;
  String get toolDeclarations => _settings.toolDeclarations;
  String get defaultToolDeclarations => _defaultToolDeclarationsJson;
  String? get toolDeclarationsError => _toolDeclarationsError;
  int get declaredToolCount => _declaredTools.length;
  bool get thinkingEnabled => _settings.thinkingEnabled;
  int get thinkingBudgetTokens => _settings.thinkingBudgetTokens;
  bool get singleTurnMode => _settings.singleTurnMode;

  bool get isReady => _error == null && !_isInitializing && _isLoaded;

  ChatProvider({
    ChatService? chatService,
    ChatGenerationService? chatGenerationService,
    ChatSessionService? chatSessionService,
    ConversationStateService? conversationStateService,
    RuntimeProfileService? runtimeProfileService,
    SettingsService? settingsService,
    AssistantOutputService? assistantOutputService,
    ToolDeclarationService? toolDeclarationService,
    ChatSettings? initialSettings,
  }) : _chatService = chatService ?? ChatService(),
       _chatGenerationService =
           chatGenerationService ?? const ChatGenerationService(),
       _chatSessionService = chatSessionService ?? const ChatSessionService(),
       _conversationStateService =
           conversationStateService ?? const ConversationStateService(),
       _runtimeProfileService =
           runtimeProfileService ?? const RuntimeProfileService(),
       _settingsService = settingsService ?? SettingsService(),
       _assistantOutputService =
           assistantOutputService ?? const AssistantOutputService(),
       _toolDeclarationService =
           toolDeclarationService ?? const ToolDeclarationService(),
       _settings = initialSettings ?? const ChatSettings() {
    _createInitialConversation();
    _rebuildDeclaredToolsFromSettings();
    if (chatService == null && settingsService == null) {
      _init();
    }
  }

  void _createInitialConversation() {
    final id = _conversationStateService.newConversationId();
    _activeConversationId = id;
    _conversations.add(
      _conversationStateService.createEmptyConversation(
        id: id,
        settings: _settings,
      ),
    );
  }

  void _syncActiveConversationSnapshot({bool touchUpdatedAt = true}) {
    final index = _conversationStateService.activeConversationIndex(
      conversations: _conversations,
      activeConversationId: _activeConversationId,
    );
    if (index < 0) {
      return;
    }

    final existing = _conversations[index];
    _conversations[index] = _conversationStateService.buildSnapshot(
      existing: existing,
      messages: _messages,
      settings: _settings,
      currentTokens: _currentTokens,
      isPruning: _isPruning,
      touchUpdatedAt: touchUpdatedAt,
    );
  }

  void _restoreSessionFromMessages() {
    if (!_chatService.engine.isReady || !_isLoaded) {
      _session = null;
      return;
    }

    _session?.reset();
    _session = _chatSessionService.rebuildFromMessages(
      engine: _chatService.engine,
      contextSize: _settings.contextSize,
      systemPrompt: _sessionSystemPrompt(),
      messages: _messages,
    );
  }

  void createConversation() {
    _syncActiveConversationSnapshot();

    final id = _conversationStateService.newConversationId();
    final copiedSettings = _settings.copyWith();

    _messages.clear();
    _stagedParts.clear();
    _currentTokens = 0;
    _isPruning = false;
    _error = null;
    _isGenerating = false;
    _settings = copiedSettings;
    _rebuildDeclaredToolsFromSettings();

    _conversations.insert(
      0,
      _conversationStateService.createEmptyConversation(
        id: id,
        settings: copiedSettings,
      ),
    );
    _activeConversationId = id;

    if (_chatService.engine.isReady && _isLoaded) {
      _session?.reset();
      _session = _chatSessionService.createSession(
        engine: _chatService.engine,
        contextSize: _settings.contextSize,
        systemPrompt: _sessionSystemPrompt(),
      );
    } else {
      _session = null;
    }

    notifyListeners();
  }

  Future<void> switchConversation(String conversationId) async {
    if (conversationId == _activeConversationId) {
      return;
    }

    final index = _conversations.indexWhere((c) => c.id == conversationId);
    if (index < 0) {
      return;
    }

    _syncActiveConversationSnapshot();
    final target = _conversations[index];

    _activeConversationId = target.id;
    _settings = target.settings;
    _rebuildDeclaredToolsFromSettings();
    _messages
      ..clear()
      ..addAll(target.messages);
    _currentTokens = target.currentTokens;
    _isPruning = target.isPruning;
    _stagedParts.clear();
    _error = null;
    _isGenerating = false;

    final targetModelPath = _settings.modelPath;
    final targetMmprojPath = _settings.mmprojPath;
    final requiresLoad =
        targetModelPath != null &&
        targetModelPath.isNotEmpty &&
        (!_isLoaded ||
            _loadedModelPath != targetModelPath ||
            (_loadedMmprojPath ?? '') != (targetMmprojPath ?? ''));

    if (requiresLoad) {
      await loadModel();
      return;
    }

    if (targetModelPath == null || targetModelPath.isEmpty) {
      _session = null;
      _isLoaded = false;
      _supportsVision = false;
      _supportsAudio = false;
      _mmprojLoaded = false;
      _runtimeGpuLayers = null;
      _runtimeThreads = null;
      _runtimeThreadPoolSize = null;
      _runtimeExecution = null;
      _runtimeCoreVariant = null;
      _runtimeWorkerFallbackReason = null;
      _runtimeNotes = null;
      _runtimeModelSource = null;
      _runtimeModelCacheState = null;
      notifyListeners();
      return;
    }

    _isLoaded = _chatService.engine.isReady;
    _restoreSessionFromMessages();
    notifyListeners();
  }

  Future<void> deleteConversation(String conversationId) async {
    final index = _conversations.indexWhere((c) => c.id == conversationId);
    if (index < 0) {
      return;
    }

    final wasActive = _activeConversationId == conversationId;
    _conversations.removeAt(index);

    if (_conversations.isEmpty) {
      createConversation();
      return;
    }

    if (!wasActive) {
      notifyListeners();
      return;
    }

    await switchConversation(_conversations.first.id);
  }

  void _rebuildDeclaredToolsFromSettings() {
    final raw = _toolDeclarationService.normalizeDeclarations(
      _settings.toolDeclarations,
    );
    try {
      _declaredTools = _toolDeclarationService.parseDefinitions(
        raw,
        handler: _declarationOnlyToolHandler,
      );
      _toolDeclarationsError = null;
    } catch (error) {
      _declaredTools = const <ToolDefinition>[];
      _toolDeclarationsError = _toolDeclarationService.formatError(
        error,
        fallback: 'Tool declarations are invalid.',
      );
    }
  }

  static Future<Object?> _declarationOnlyToolHandler(ToolParams _) async {
    return 'Tool execution is disabled in this chat app.';
  }

  Future<void> _init() async {
    _settings = await _settingsService.loadSettings();
    _rebuildDeclaredToolsFromSettings();
    final index = _conversationStateService.activeConversationIndex(
      conversations: _conversations,
      activeConversationId: _activeConversationId,
    );
    if (index >= 0) {
      _conversations[index] = _conversations[index].copyWith(
        settings: _settings,
      );
    }

    String? availableBackendInfo;
    String? activeBackendInfo;
    try {
      availableBackendInfo = await _chatService.engine.getAvailableBackends();
    } catch (e) {
      debugPrint("Error fetching available backends: $e");
    }

    try {
      activeBackendInfo = await _chatService.engine.getBackendName();
    } catch (e) {
      debugPrint("Error fetching active backend: $e");
    }

    if (availableBackendInfo != null) {
      _availableDevices = BackendUtils.parseBackendDevices(
        availableBackendInfo,
      );
    }

    final backendInfoForLabel = activeBackendInfo ?? availableBackendInfo;
    if (backendInfoForLabel != null) {
      _activeBackend = BackendUtils.deriveActiveBackendLabel(
        backendInfoForLabel,
        preferredBackend: _settings.preferredBackend,
        gpuLayers: _settings.gpuLayers,
      );
    } else {
      _activeBackend = _settings.preferredBackend == GpuBackend.cpu
          ? 'CPU'
          : _settings.preferredBackend.name.toUpperCase();
    }
    _syncActiveConversationSnapshot(touchUpdatedAt: false);
    notifyListeners();
  }

  Future<void> loadModel() async {
    if (_isInitializing) return;
    if (_settings.modelPath == null || _settings.modelPath!.isEmpty) {
      _error = 'Model path not set. Please configure in settings.';
      _syncActiveConversationSnapshot(touchUpdatedAt: false);
      notifyListeners();
      return;
    }

    _isInitializing = true;
    _isLoaded = false;
    _error = null;
    _loadingProgress = 0.0;
    _activeBackend = 'Loading model...';
    _supportsVision = false;
    _supportsAudio = false;
    _mmprojLoaded = false;
    _runtimeGpuLayers = null;
    _runtimeThreads = null;
    _runtimeThreadPoolSize = null;
    _runtimeExecution = null;
    _runtimeCoreVariant = null;
    _runtimeWorkerFallbackReason = null;
    _runtimeNotes = null;
    _runtimeModelSource = null;
    _runtimeModelCacheState = null;
    notifyListeners();

    DateTime lastProgressNotifyAt = DateTime.now();
    double lastProgressNotified = 0.0;

    void updateLoadingUi(
      double value, {
      String? backendLabel,
      bool forceNotify = false,
    }) {
      final double clamped = value.clamp(0.0, 1.0);
      var changed = false;

      if (clamped > _loadingProgress) {
        _loadingProgress = clamped;
        changed = true;
      }

      if (backendLabel != null) {
        _activeBackend = backendLabel;
        changed = true;
      }

      if (!changed) {
        return;
      }

      final now = DateTime.now();
      final shouldNotify =
          forceNotify ||
          _loadingProgress >= 1.0 ||
          (_loadingProgress - lastProgressNotified) >= 0.01 ||
          now.difference(lastProgressNotifyAt) >=
              const Duration(milliseconds: 80);

      if (!shouldNotify) {
        return;
      }

      lastProgressNotifyAt = now;
      lastProgressNotified = _loadingProgress;
      notifyListeners();
    }

    updateLoadingUi(0.04, forceNotify: true);

    // Estimate dynamic settings only when backend preference remains Auto.
    if (_settings.preferredBackend == GpuBackend.auto &&
        (_settings.gpuLayers == 32 || _settings.gpuLayers == 99)) {
      try {
        await estimateDynamicSettings();
      } catch (e) {
        debugPrint("Dynamic estimation failed: $e");
      }
    }

    updateLoadingUi(0.1);

    try {
      final eagerLoadMmproj =
          (_settings.mmprojPath?.trim().isNotEmpty ?? false);

      await _chatService.engine.setDartLogLevel(_settings.logLevel);
      await _chatService.engine.setNativeLogLevel(_settings.nativeLogLevel);
      updateLoadingUi(0.14);
      await _chatService.init(
        _settings,
        eagerLoadMultimodalProjector: eagerLoadMmproj,
        onProgress: (progress) {
          final normalized = progress.clamp(0.0, 1.0);
          final staged = 0.14 + (normalized * 0.7);
          updateLoadingUi(
            staged,
            backendLabel:
                'Loading model ${(normalized * 100).toStringAsFixed(0)}%',
          );
        },
      );

      updateLoadingUi(0.72);

      if (!_chatService.engine.isReady) {
        throw Exception('Engine initialization did not complete.');
      }

      _session = _chatSessionService.createSession(
        engine: _chatService.engine,
        contextSize: _settings.contextSize,
        systemPrompt: _sessionSystemPrompt(),
      );
      updateLoadingUi(0.8);

      final availableBackendInfo = await _getAvailableBackendInfoBestEffort();
      if (availableBackendInfo != null) {
        _availableDevices = BackendUtils.parseBackendDevices(
          availableBackendInfo,
        );
      }

      final activeBackendInfo = await _getBackendInfoBestEffort();
      final backendInfoForLabel = activeBackendInfo ?? availableBackendInfo;
      if (backendInfoForLabel != null) {
        _activeBackend = BackendUtils.deriveActiveBackendLabel(
          backendInfoForLabel,
          preferredBackend: _settings.preferredBackend,
          gpuLayers: _settings.gpuLayers,
        );
      } else {
        _activeBackend = _settings.preferredBackend == GpuBackend.cpu
            ? 'CPU'
            : _settings.preferredBackend.name.toUpperCase();
      }

      _contextLimit = await _chatService.engine.getContextSize();
      _mmprojLoaded =
          eagerLoadMmproj && (_settings.mmprojPath?.trim().isNotEmpty ?? false);
      final metadata = await _chatService.engine.getMetadata();
      final inferredCapabilities = _inferMultimodalCapabilities(metadata);
      final runtimeSupportsVision = await _chatService.engine.supportsVision;
      final runtimeSupportsAudio = await _chatService.engine.supportsAudio;
      _supportsVision =
          runtimeSupportsVision ||
          (!_mmprojLoaded && inferredCapabilities.supportsVision);
      _supportsAudio =
          runtimeSupportsAudio ||
          (!_mmprojLoaded && inferredCapabilities.supportsAudio);
      _updateToolTemplateSupport(metadata);
      updateLoadingUi(0.9);

      final runtimeDiagnostics = _runtimeProfileService.buildDiagnostics(
        metadata: metadata,
      );
      _runtimeGpuLayers =
          await _getResolvedGpuLayersBestEffort() ??
          runtimeDiagnostics.runtimeGpuLayers;
      _runtimeThreads = runtimeDiagnostics.runtimeThreads;
      _runtimeThreadPoolSize = runtimeDiagnostics.runtimeThreadPoolSize;
      _runtimeExecution = runtimeDiagnostics.runtimeExecution;
      _runtimeCoreVariant = runtimeDiagnostics.runtimeCoreVariant;
      _runtimeWorkerFallbackReason =
          runtimeDiagnostics.runtimeWorkerFallbackReason;
      _runtimeNotes = runtimeDiagnostics.runtimeNotes;
      _runtimeModelSource = runtimeDiagnostics.runtimeModelSource;
      _runtimeModelCacheState = runtimeDiagnostics.runtimeModelCacheState;
      _publishWebRuntimeDiagnosticsHints();

      if (!kIsWeb &&
          defaultTargetPlatform == TargetPlatform.android &&
          (_runtimeGpuLayers ?? 0) > 0 &&
          _activeBackend.toUpperCase().contains('VULKAN')) {
        _addInfoMessage(
          'Android Vulkan stability mode is active. Prompt batching is reduced to avoid driver crashes, so first-token latency can be higher.',
        );
      }

      final normalizedModelPath = (_settings.modelPath ?? '').toLowerCase();
      final isGemma4 =
          normalizedModelPath.contains('gemma-4') ||
          normalizedModelPath.contains('gemma_4') ||
          normalizedModelPath.contains('gemma4');
      if (isGemma4 && _mmprojLoaded && _supportsVision && !_supportsAudio) {
        _addInfoMessage(
          'This Gemma 4 GGUF projector currently exposes vision only in the '
          'llama.cpp mtmd runtime. Image input is available, but audio input is disabled.',
        );
      }

      _addInfoMessage('Model loaded successfully! Ready to chat.');
      _isLoaded = true;
      _loadedModelPath = _settings.modelPath;
      _loadedMmprojPath = _settings.mmprojPath;
      _restoreSessionFromMessages();
      _syncActiveConversationSnapshot(touchUpdatedAt: false);
      updateLoadingUi(1.0, forceNotify: true);
    } catch (e, stackTrace) {
      debugPrint('Error loading model: $e');
      debugPrint(stackTrace.toString());
      _error = _formatDisplayError(e);
      _loadedModelPath = null;
      _loadedMmprojPath = null;
      _supportsVision = false;
      _supportsAudio = false;
      _mmprojLoaded = false;
    } finally {
      _isInitializing = false;
      notifyListeners();
    }
  }

  String _formatDisplayError(Object error) {
    final raw = error.toString().trim();
    const prefixes = <String>['LlamaException: ', 'Exception: '];
    for (final prefix in prefixes) {
      if (raw.startsWith(prefix)) {
        return raw.substring(prefix.length).trim();
      }
    }
    return raw;
  }

  void clearConversation() {
    _messages.clear();
    _session?.reset();
    _currentTokens = 0;
    _isPruning = false;
    _isGenerating = false;
    _stagedParts.clear();
    _lastTokensPerSecond = null;
    _lastDecodeTokensPerSecond = null;
    _lastNativePromptEvalMs = null;
    _lastNativeEvalMs = null;
    _lastNativeSampleMs = null;
    _lastNativePromptEvalTokens = null;
    _lastNativeEvalTokens = null;
    _lastNativeReusedGraphs = null;
    _messages.add(
      ChatMessage(
        text: 'Conversation cleared. Ready for a new topic!',
        isUser: false,
        isInfo: true,
      ),
    );
    _syncActiveConversationSnapshot();
    notifyListeners();
  }

  Future<void> sendMessage(String text) async {
    if (_isGenerating || _session == null) return;

    if (_settings.singleTurnMode) {
      _session!.reset();
    }

    if (!_chatService.engine.isReady) {
      _messages.add(
        ChatMessage(
          text: 'Model is not ready yet. Please reload and try again.',
          isUser: false,
          isInfo: true,
        ),
      );
      notifyListeners();
      return;
    }

    final parts = List<LlamaContentPart>.from(_stagedParts);
    // Don't add text here - ChatSession.chat will handle it

    if (parts.isEmpty && text.isEmpty) return;

    if (!await _ensureMultimodalProjectorForMedia(parts)) {
      return;
    }

    // For UI display, include text in parts
    final displayParts = [
      ...parts,
      if (text.isNotEmpty) LlamaTextContent(text),
    ];
    final userMsg = ChatMessage(text: text, isUser: true, parts: displayParts);
    _messages.add(userMsg);
    _stagedParts.clear();
    _isGenerating = true;
    _syncActiveConversationSnapshot();
    notifyListeners();

    await _yieldUiFrame();

    await _generateResponse(text, parts: parts.isEmpty ? null : parts);
  }

  Map<String, dynamic>? _thinkingTemplateKwargs() {
    if (_settings.thinkingEnabled && _settings.thinkingBudgetTokens <= 0) {
      return null;
    }

    final kwargs = <String, dynamic>{
      'enable_thinking': _settings.thinkingEnabled,
      'thinking': _settings.thinkingEnabled,
      'reasoning': _settings.thinkingEnabled,
    };

    if (_settings.thinkingBudgetTokens > 0) {
      kwargs['thinking_budget'] = _settings.thinkingBudgetTokens;
      kwargs['reasoning_budget'] = _settings.thinkingBudgetTokens;
      kwargs['max_thinking_tokens'] = _settings.thinkingBudgetTokens;
    }

    return kwargs;
  }

  String? _sessionSystemPrompt() {
    if (!_settings.toolsEnabled) {
      return null;
    }

    return 'When function declarations are available, call tools only when '
        'they are needed. If no tool is needed, answer directly.';
  }

  bool _containsAnyNeedle(String haystack, List<String> needles) {
    for (final needle in needles) {
      if (haystack.contains(needle)) {
        return true;
      }
    }
    return false;
  }

  ({bool supportsVision, bool supportsAudio}) _inferMultimodalCapabilities(
    Map<String, String> metadata,
  ) {
    final mmprojPath = (_settings.mmprojPath ?? '').trim();
    if (mmprojPath.isEmpty) {
      return (supportsVision: false, supportsAudio: false);
    }

    final modelHint =
        '${_settings.modelPath ?? ''} ${_settings.mmprojPath ?? ''}'
            .toLowerCase();
    final metadataHint = metadata.entries
        .map((entry) => '${entry.key}:${entry.value}')
        .join(' ')
        .toLowerCase();

    const audioNeedles = <String>[
      'ultravox',
      'audio',
      'speech',
      'whisper',
      'conformer',
      'asr',
    ];
    const visionNeedles = <String>[
      'vision',
      'image',
      'qwen2vl',
      'qwen3vl',
      'llava',
      'glm4v',
      'internvl',
      'pixtral',
      'cogvlm',
      'minicpmv',
      'smolvlm',
      'lfm2-vl',
    ];

    final supportsAudio =
        _containsAnyNeedle(modelHint, audioNeedles) ||
        _containsAnyNeedle(metadataHint, audioNeedles);
    final supportsVision =
        _containsAnyNeedle(modelHint, visionNeedles) ||
        _containsAnyNeedle(metadataHint, visionNeedles) ||
        !supportsAudio;

    return (supportsVision: supportsVision, supportsAudio: supportsAudio);
  }

  Future<bool> _ensureMultimodalProjectorForMedia(
    List<LlamaContentPart> parts,
  ) async {
    final needsMultimodal = parts.any(
      (part) => part is LlamaImageContent || part is LlamaAudioContent,
    );
    if (!needsMultimodal) {
      return true;
    }

    if (_mmprojLoaded) {
      final runtimeSupportsVision = await _chatService.engine.supportsVision;
      final runtimeSupportsAudio = await _chatService.engine.supportsAudio;
      if (runtimeSupportsVision || runtimeSupportsAudio) {
        _supportsVision = runtimeSupportsVision;
        _supportsAudio = runtimeSupportsAudio;
        return true;
      }

      _mmprojLoaded = false;
    }

    if (!hasConfiguredMmproj) {
      _addInfoMessage(
        'This model was loaded without an mmproj. Configure a matching mmproj in Manage models to send media.',
      );
      notifyListeners();
      return false;
    }

    return loadConfiguredMmproj(
      successMessage: 'Multimodal projector loaded on demand.',
    );
  }

  List<ToolDefinition>? _toolsForTurn() {
    if (!_settings.toolsEnabled || !_templateSupportsTools) {
      return null;
    }
    if (_declaredTools.isEmpty) {
      return null;
    }
    return _declaredTools;
  }

  Future<void> _yieldUiFrame() async {
    await Future<void>.delayed(Duration.zero);
    if (kIsWeb) {
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
  }

  Future<void> _generateResponse(
    String text, {
    List<LlamaContentPart>? parts,
  }) async {
    var generationResult = const GenerationStreamResult(
      fullResponse: '',
      fullThinking: '',
      generatedTokens: 0,
      firstTokenLatencyMs: null,
      elapsedMs: 0,
      decodeElapsedMs: 0,
    );
    _lastFirstTokenLatencyMs = null;
    final toolsForTurn = _toolsForTurn();
    var hasMediaPartsInTurn = false;
    var hasAudioPartsInTurn = false;
    var isCpuMultimodalTurn = false;

    try {
      _messages.add(ChatMessage(text: "...", isUser: false));
      notifyListeners();

      await _yieldUiFrame();

      final params = _chatGenerationService.buildParams(_settings);
      final chatParts = _chatGenerationService.buildChatParts(
        text: text,
        stagedParts: parts,
      );
      hasMediaPartsInTurn = chatParts.any(
        (part) => part is LlamaImageContent || part is LlamaAudioContent,
      );
      hasAudioPartsInTurn = chatParts.any((part) => part is LlamaAudioContent);
      final resolvedGpuLayers = _runtimeGpuLayers;
      final runtimeLooksCpu = resolvedGpuLayers != null
          ? resolvedGpuLayers <= 0
          : _settings.preferredBackend == GpuBackend.cpu;
      isCpuMultimodalTurn = hasMediaPartsInTurn && runtimeLooksCpu;
      final effectiveParams = isCpuMultimodalTurn
          ? params.copyWith(maxTokens: math.min(params.maxTokens, 192))
          : params;
      final streamStallTimeout = kIsWeb
          ? Duration(
              seconds: hasMediaPartsInTurn
                  ? (isCpuMultimodalTurn ? 150 : 120)
                  : 75,
            )
          : const Duration(seconds: 180);
      final cpuMultimodalWallSeconds = math.max(
        180,
        math.min(420, effectiveParams.maxTokens * 2),
      );
      final streamWallTimeout = kIsWeb
          ? Duration(
              seconds: hasMediaPartsInTurn
                  ? (isCpuMultimodalTurn ? cpuMultimodalWallSeconds : 180)
                  : 130,
            )
          : const Duration(seconds: 240);

      final templateKwargs = _thinkingTemplateKwargs();
      _session!.systemPrompt = _sessionSystemPrompt();

      generationResult = await _chatGenerationService
          .consumeStream(
            stream: _session!.create(
              chatParts,
              params: effectiveParams,
              tools: toolsForTurn,
              toolChoice: toolsForTurn != null ? ToolChoice.auto : null,
              enableThinking: _settings.thinkingEnabled,
              chatTemplateKwargs: templateKwargs,
            ),
            thinkingEnabled: _settings.thinkingEnabled,
            uiNotifyIntervalMs: 16,
            cleanResponse: (response) => response,
            shouldContinue: () => _isGenerating,
            stallTimeout: streamStallTimeout,
            onUpdate: (update) {
              _currentTokens += update.generatedTokenDelta;

              final shouldRefreshStreamingMessage =
                  update.shouldNotify || update.generatedTokenDelta == 0;
              var streamingMessageChanged = false;
              if (shouldRefreshStreamingMessage) {
                streamingMessageChanged = _updateStreamingAssistantMessage(
                  cleanText: update.cleanText,
                  fullThinking: update.fullThinking,
                );
              }

              if (update.shouldNotify) {
                if (streamingMessageChanged ||
                    update.generatedTokenDelta != 0) {
                  notifyListeners();
                }
              }
            },
          )
          .timeout(
            streamWallTimeout,
            onTimeout: () {
              _chatService.cancelGeneration();
              throw TimeoutException(
                'Generation exceeded wall timeout.',
                streamWallTimeout,
              );
            },
          );

      final fullResponse = generationResult.fullResponse;
      final fullThinking = generationResult.fullThinking;
      _lastFirstTokenLatencyMs = generationResult.firstTokenLatencyMs;

      // Final update
      if (_messages.isNotEmpty && !_messages.last.isUser) {
        final lastSessionMessage = _session!.history.isNotEmpty
            ? _session!.history.last
            : null;
        var toolCalls = lastSessionMessage == null
            ? const <LlamaToolCallContent>[]
            : lastSessionMessage.parts.whereType<LlamaToolCallContent>().toList(
                growable: false,
              );
        if (toolCalls.isEmpty) {
          toolCalls = _assistantOutputService.parseToolCallsForDisplay(
            streamedContent: fullResponse,
            detectedChatFormat: _detectedChatFormat,
          );
        }

        final hadRawThinkingTags = _assistantOutputService.containsReasoningTag(
          fullResponse,
        );
        final hadThinkingStream = fullThinking.trim().isNotEmpty;
        final normalized = _assistantOutputService.normalizeAssistantOutput(
          streamedContent: fullResponse,
          streamedThinking: fullThinking,
          toolsEnabled: _settings.toolsEnabled,
          detectedChatFormat: _detectedChatFormat,
          cleanResponse: _chatService.cleanResponse,
        );
        var finalText = normalized.text;
        var finalThinking = normalized.thinking;
        if (!_settings.thinkingEnabled) {
          finalThinking = '';
        }

        final debugBadges = kDebugMode
            ? _assistantOutputService.buildAssistantDebugBadges(
                detectedChatFormat: _detectedChatFormat,
                hadRawThinkingTags: hadRawThinkingTags,
                hadThinkingStream: hadThinkingStream,
                finalThinking: finalThinking,
                finalText: finalText,
              )
            : <String>[];

        if (_messages.isNotEmpty && !_messages.last.isUser) {
          final messageParts = <LlamaContentPart>[];
          if (finalThinking.isNotEmpty) {
            messageParts.add(LlamaThinkingContent(finalThinking));
          }
          if (toolCalls.isNotEmpty) {
            messageParts.addAll(toolCalls);
            if (finalText.isEmpty) {
              finalText = toolCalls.map((call) => call.rawJson).join('\n');
            }
          } else if (finalText.isNotEmpty) {
            messageParts.add(LlamaTextContent(finalText));
          }

          _messages[_messages.length - 1] = _messages.last.copyWith(
            text: finalText,
            parts: messageParts,
            debugBadges: debugBadges,
          );
          _messages.last.tokenCount = await _chatService.engine.getTokenCount(
            finalText,
          );
        }
      }
    } catch (e) {
      final errorText = e.toString();
      if (e is TimeoutException) {
        _chatService.cancelGeneration();
        _messages.add(
          ChatMessage(
            text: hasMediaPartsInTurn && isCpuMultimodalTurn
                ? 'CPU multimodal generation timed out before completion. '
                      'Try lowering Max generated tokens or sending a smaller image and retrying.'
                : 'Generation timed out waiting for model output. The request was cancelled. '
                      'Try lowering Max generated tokens for multimodal prompts and resending.',
            isUser: false,
            isInfo: true,
          ),
        );
      } else if (errorText.contains('Multimodal worker')) {
        _messages.add(
          ChatMessage(
            text:
                'Multimodal worker failed in this browser session. '
                'Reload model and retry with a smaller image, or disable mmproj for text-only chat.',
            isUser: false,
            isInfo: true,
          ),
        );
      } else if (errorText.contains('CPU multimodal request failed')) {
        _messages.add(
          ChatMessage(
            text:
                'CPU multimodal inference failed before producing tokens. '
                'Reload model and retry with a smaller image.',
            isUser: false,
            isInfo: true,
          ),
        );
      } else if (errorText.contains('mtmd_tokenize failed')) {
        _messages.add(
          ChatMessage(
            text:
                'Vision processing failed for this prompt. Try reloading the '
                'model, using the bundled mmproj, or reducing image size.',
            isUser: false,
            isInfo: true,
          ),
        );
      } else if (errorText.contains('Failed to load media part')) {
        _messages.add(
          ChatMessage(
            text: hasAudioPartsInTurn
                ? 'Audio preprocessing failed before the prompt reached the model. '
                      'The current native mtmd path is strict about input formats; '
                      'WAV/PCM is the safest option, while voice-note containers like '
                      '`.m4a` often fail here. Try converting the clip to `.wav` and retrying.'
                : 'Media preprocessing failed before the prompt reached the model. '
                      'Try a different file or reload the matching mmproj and retry.',
            isUser: false,
            isInfo: true,
          ),
        );
      } else if (errorText.contains('Multimodal prompt evaluation failed') ||
          errorText.contains('produced no logits for sampling')) {
        _messages.add(
          ChatMessage(
            text:
                'This multimodal turn exceeded the active context window before decoding could finish. '
                'Try a smaller image, a larger Context size, or clearing earlier image turns.',
            isUser: false,
            isInfo: true,
          ),
        );
      } else {
        _messages.add(ChatMessage(text: 'Error: $e', isUser: false));
      }
    } finally {
      final generatedTokens = generationResult.generatedTokens;
      final elapsedMs = generationResult.elapsedMs;
      final decodeElapsedMs = generationResult.decodeElapsedMs;
      if (generatedTokens > 0 && elapsedMs > 0) {
        _lastTokensPerSecond = generatedTokens / (elapsedMs / 1000);
      } else {
        _lastTokensPerSecond = null;
      }

      if (generatedTokens > 0 && decodeElapsedMs > 0) {
        _lastDecodeTokensPerSecond = generatedTokens / (decodeElapsedMs / 1000);
      } else {
        _lastDecodeTokensPerSecond = null;
      }

      try {
        final perf = await _chatService.engine.getPerformanceContext();
        if (perf != null) {
          _lastNativePromptEvalMs = perf.promptEvalMs.round();
          _lastNativeEvalMs = perf.evalMs.round();
          _lastNativeSampleMs = perf.sampleMs.round();
          _lastNativePromptEvalTokens = perf.promptEvalTokens;
          _lastNativeEvalTokens = perf.evalTokens;
          _lastNativeReusedGraphs = perf.reusedGraphs;
        } else {
          _lastNativePromptEvalMs = null;
          _lastNativeEvalMs = null;
          _lastNativeSampleMs = null;
          _lastNativePromptEvalTokens = null;
          _lastNativeEvalTokens = null;
          _lastNativeReusedGraphs = null;
        }
      } catch (_) {
        _lastNativePromptEvalMs = null;
        _lastNativeEvalMs = null;
        _lastNativeSampleMs = null;
        _lastNativePromptEvalTokens = null;
        _lastNativeEvalTokens = null;
        _lastNativeReusedGraphs = null;
      }

      if (generationResult.firstTokenLatencyMs != null ||
          generationResult.fullResponse.isNotEmpty ||
          generationResult.fullThinking.isNotEmpty) {
        _lastGenerationLatencyMs = elapsedMs;
      }
      _isGenerating = false;
      _syncActiveConversationSnapshot();
      notifyListeners();
    }
  }

  bool _updateStreamingAssistantMessage({
    required String cleanText,
    required String fullThinking,
  }) {
    if (_messages.isEmpty || _messages.last.isUser) {
      return false;
    }

    final lastMessage = _messages.last;
    final currentThinking = lastMessage.thinkingText ?? '';
    if (lastMessage.text == cleanText && currentThinking == fullThinking) {
      return false;
    }

    final parts = <LlamaContentPart>[];
    if (fullThinking.isNotEmpty) {
      parts.add(LlamaThinkingContent(fullThinking));
    }
    if (cleanText.isNotEmpty) {
      parts.add(LlamaTextContent(cleanText));
    }

    _messages[_messages.length - 1] = _messages.last.copyWith(
      text: cleanText,
      parts: parts,
    );
    return true;
  }

  void _addInfoMessage(String text) {
    final last = _messages.isNotEmpty ? _messages.last : null;
    if (last != null && last.isInfo && last.text == text) {
      return;
    }

    _messages.add(ChatMessage(text: text, isUser: false, isInfo: true));
    _syncActiveConversationSnapshot();
  }

  void _publishWebRuntimeDiagnosticsHints() {
    if (!kIsWeb) {
      return;
    }

    final runtimeNotes = (_runtimeNotes ?? '')
        .split(';')
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toSet();

    if (runtimeNotes.contains('threads_capped_no_coi')) {
      _addInfoMessage(
        'Web runtime is not cross-origin isolated, so inference threads are capped to 1. '
        'Enable COOP/COEP headers for better throughput.',
      );
    }

    if (runtimeNotes.contains('threads_capped_no_pthread')) {
      _addInfoMessage(
        'Loaded bridge core does not include pthread support, so runtime threads are capped to 1. '
        'Use pthread-enabled bridge assets for faster text and multimodal generation.',
      );
    }

    final runtimeThreads = _runtimeThreads;
    if (runtimeThreads != null && runtimeThreads <= 1) {
      if (_settings.thinkingEnabled && _settings.contextSize > 4096) {
        _addInfoMessage(
          'Single-thread web runtime detected. For faster text generation, disable thinking and lower context to 4096.',
        );
      } else if (_settings.thinkingEnabled) {
        _addInfoMessage(
          'Single-thread web runtime detected. Disable thinking mode to improve text throughput.',
        );
      } else if (_settings.contextSize > 4096) {
        _addInfoMessage(
          'Single-thread web runtime detected. Reducing context size to 4096 usually improves throughput.',
        );
      }
    }

    final runtimeGpuLayers = _runtimeGpuLayers;
    if (_settings.preferredBackend != GpuBackend.cpu &&
        runtimeGpuLayers != null &&
        runtimeGpuLayers <= 0) {
      _addInfoMessage(
        'Web runtime is currently operating in CPU mode (resolved GPU layers = 0). '
        'Reload model after backend changes or lower context/GPU layers to avoid fallback.',
      );
    }

    final poolCapNote = runtimeNotes.firstWhere(
      (note) => note.startsWith('threads_capped_pool:'),
      orElse: () => '',
    );
    if (poolCapNote.isNotEmpty) {
      final poolSize = poolCapNote.split(':').last;
      _addInfoMessage(
        'Web runtime threads were capped to $poolSize to match pthread pool size and avoid deadlock risks.',
      );
    }

    final workerFallbackReason = _runtimeWorkerFallbackReason;
    if (workerFallbackReason != null && workerFallbackReason.isNotEmpty) {
      _addInfoMessage(
        'Web bridge worker fallback detected ($workerFallbackReason). '
        'Model load/generation may be slower in this mode.',
      );
    }
  }

  void _addStagedPart(LlamaContentPart part) {
    _stagedParts.add(part);
    notifyListeners();
  }

  void removeStagedPart(int index) {
    if (index >= 0 && index < _stagedParts.length) {
      _stagedParts.removeAt(index);
      notifyListeners();
    }
  }

  Future<void> pickImage() async {
    if (!kIsWeb &&
        defaultTargetPlatform == TargetPlatform.android &&
        _androidDebugImagePath.isNotEmpty) {
      final prepared = await _prepareImagePartFromPath(_androidDebugImagePath);
      if (prepared != null) {
        _addStagedPart(prepared);
        return;
      }
    }

    await _pickMediaPart(
      type: FileType.image,
      fromPath: (path) async {
        final prepared = await _prepareImagePartFromPath(path);
        if (prepared != null) {
          return prepared;
        }
        return LlamaImageContent(path: path);
      },
      fromBytes: (bytes) async {
        final prepared = await _prepareImagePartFromBytes(bytes);
        if (prepared != null) {
          return prepared;
        }
        return LlamaImageContent(bytes: bytes);
      },
      browserReadError:
          'Could not read image bytes in browser. Try a different image file.',
      fileReadError: 'Could not read selected image file.',
      debugLabel: 'image',
    );
  }

  Future<void> pickAudio() async {
    await _pickMediaPart(
      type: FileType.audio,
      fromPath: (path) async => LlamaAudioContent(path: path),
      fromBytes: (bytes) async => LlamaAudioContent(bytes: bytes),
      browserReadError:
          'Could not read audio bytes in browser. Try a different audio file.',
      fileReadError: 'Could not read selected audio file.',
      debugLabel: 'audio',
    );
  }

  Future<void> _pickMediaPart({
    required FileType type,
    required Future<LlamaContentPart> Function(String path) fromPath,
    required Future<LlamaContentPart> Function(Uint8List bytes) fromBytes,
    required String browserReadError,
    required String fileReadError,
    required String debugLabel,
  }) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: type,
        allowMultiple: false,
        withData: kIsWeb,
      );
      if (result == null || result.files.isEmpty) {
        return;
      }

      final file = result.files.single;
      if (kIsWeb) {
        final bytes = file.bytes;
        if (bytes != null && bytes.isNotEmpty) {
          _addStagedPart(await fromBytes(bytes));
          return;
        }

        _addInfoMessage(browserReadError);
        notifyListeners();
        return;
      }

      final path = file.path;
      if (path != null && path.isNotEmpty) {
        _addStagedPart(await fromPath(path));
        return;
      }

      final bytes = file.bytes;
      if (bytes != null && bytes.isNotEmpty) {
        _addStagedPart(await fromBytes(bytes));
        return;
      }

      _addInfoMessage(fileReadError);
      notifyListeners();
    } catch (error) {
      debugPrint('Error picking $debugLabel: $error');
    }
  }

  Future<LlamaImageContent?> _prepareImagePartFromPath(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      return _prepareImagePartFromBytes(bytes);
    } catch (error) {
      debugPrint('Error preparing image bytes from path: $error');
      return null;
    }
  }

  Future<LlamaImageContent?> _prepareImagePartFromBytes(Uint8List bytes) async {
    if (bytes.isEmpty) {
      return null;
    }

    final resizedBytes = await _downscaleImageBytesIfNeeded(
      bytes,
      maxEdge: _multimodalMaxImageEdge,
    );
    return LlamaImageContent(bytes: resizedBytes);
  }

  Future<Uint8List> _downscaleImageBytesIfNeeded(
    Uint8List bytes, {
    required int maxEdge,
  }) async {
    ui.Codec? probeCodec;
    ui.Codec? resizedCodec;
    ui.Image? probedImage;
    ui.Image? resizedImage;

    try {
      probeCodec = await ui.instantiateImageCodec(bytes);
      final probeFrame = await probeCodec.getNextFrame();
      probedImage = probeFrame.image;
      final width = probedImage.width;
      final height = probedImage.height;
      final longestEdge = math.max(width, height);
      if (longestEdge <= maxEdge) {
        return bytes;
      }

      final scale = maxEdge / longestEdge;
      final targetWidth = math.max(1, (width * scale).round());
      final targetHeight = math.max(1, (height * scale).round());
      resizedCodec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: targetWidth,
        targetHeight: targetHeight,
      );
      final resizedFrame = await resizedCodec.getNextFrame();
      resizedImage = resizedFrame.image;
      final byteData = await resizedImage.toByteData(
        format: ui.ImageByteFormat.png,
      );
      return byteData?.buffer.asUint8List() ?? bytes;
    } catch (_) {
      return bytes;
    } finally {
      resizedImage?.dispose();
      resizedCodec?.dispose();
      probedImage?.dispose();
      probeCodec?.dispose();
    }
  }

  void stopGeneration() {
    if (_isGenerating) {
      _chatService.cancelGeneration();
      _isGenerating = false;
      notifyListeners();
    }
  }

  void _updateSettings(ChatSettings newSettings) {
    final declarationsChanged =
        _settings.toolDeclarations != newSettings.toolDeclarations;
    _settings = newSettings;
    if (declarationsChanged) {
      _rebuildDeclaredToolsFromSettings();
    }
    _scheduleSettingsSave();
    _syncActiveConversationSnapshot(touchUpdatedAt: false);
    notifyListeners();
  }

  void _scheduleSettingsSave() {
    _settingsSaveDebounce?.cancel();
    _settingsSaveDebounce = Timer(_settingsSaveDebounceDelay, () {
      _settingsSaveDebounce = null;
      unawaited(_settingsService.saveSettings(_settings));
    });
  }

  Future<void> _saveSettingsNow() async {
    _settingsSaveDebounce?.cancel();
    _settingsSaveDebounce = null;
    await _settingsService.saveSettings(_settings);
  }

  void updateTemperature(double value) =>
      _updateSettings(_settings.copyWith(temperature: value));
  void updateTopK(int value) =>
      _updateSettings(_settings.copyWith(topK: value));
  void updateTopP(double value) =>
      _updateSettings(_settings.copyWith(topP: value));
  void updateMinP(double value) =>
      _updateSettings(_settings.copyWith(minP: value.clamp(0.0, 1.0)));
  void updatePenalty(double value) =>
      _updateSettings(_settings.copyWith(penalty: value.clamp(0.8, 2.0)));
  void updateContextSize(int value) {
    final effectiveContextSize = value == 0 ? 0 : value.clamp(512, 32768);
    _updateSettings(_settings.copyWith(contextSize: effectiveContextSize));
  }

  void updateMaxTokens(int value) =>
      _updateSettings(_settings.copyWith(maxTokens: value.clamp(512, 32768)));
  void updateGpuLayers(int value) {
    final normalized = value >= 99 ? 99 : value.clamp(0, 98);
    _updateSettings(_settings.copyWith(gpuLayers: normalized));
  }

  void updateNumberOfThreads(int value) =>
      _updateSettings(_settings.copyWith(numberOfThreads: value.clamp(0, 64)));
  void updateNumberOfThreadsBatch(int value) => _updateSettings(
    _settings.copyWith(numberOfThreadsBatch: value.clamp(0, 128)),
  );
  void updateLogLevel(LlamaLogLevel value) {
    _updateSettings(_settings.copyWith(logLevel: value));
    _chatService.engine.setDartLogLevel(value);
  }

  void updateNativeLogLevel(LlamaLogLevel value) {
    _updateSettings(_settings.copyWith(nativeLogLevel: value));
    _chatService.engine.setNativeLogLevel(value);
  }

  void updateToolsEnabled(bool value) {
    _updateSettings(_settings.copyWith(toolsEnabled: value));
  }

  bool updateToolDeclarations(String declarationsJson) {
    final normalized = _toolDeclarationService.normalizeDeclarations(
      declarationsJson,
    );
    try {
      final parsed = _toolDeclarationService.parseDefinitions(
        normalized,
        handler: _declarationOnlyToolHandler,
      );
      _declaredTools = parsed;
      _toolDeclarationsError = null;
      _updateSettings(_settings.copyWith(toolDeclarations: normalized));
      return true;
    } catch (error) {
      _toolDeclarationsError = _toolDeclarationService.formatError(
        error,
        fallback: 'Tool declarations are invalid.',
      );
      notifyListeners();
      return false;
    }
  }

  void resetToolDeclarations() {
    updateToolDeclarations(_defaultToolDeclarationsJson);
  }

  void updateThinkingEnabled(bool value) {
    _updateSettings(_settings.copyWith(thinkingEnabled: value));
  }

  void updateThinkingBudgetTokens(int value) {
    _updateSettings(
      _settings.copyWith(thinkingBudgetTokens: value.clamp(0, 8192)),
    );
  }

  void updateSingleTurnMode(bool value) {
    _updateSettings(_settings.copyWith(singleTurnMode: value));
  }

  Future<void> unloadModel() async {
    stopGeneration();
    _session?.reset();
    _session = null;
    await _chatService.unloadModel();

    _isInitializing = false;
    _loadingProgress = 0.0;
    _isLoaded = false;
    _error = null;
    _activeBackend = 'Unloaded';
    _contextLimit = 0;
    _loadedModelPath = null;
    _loadedMmprojPath = null;
    _supportsVision = false;
    _supportsAudio = false;
    _mmprojLoaded = false;
    _runtimeGpuLayers = null;
    _runtimeThreads = null;
    _runtimeThreadPoolSize = null;
    _runtimeExecution = null;
    _runtimeCoreVariant = null;
    _runtimeWorkerFallbackReason = null;
    _runtimeNotes = null;
    _runtimeModelSource = null;
    _runtimeModelCacheState = null;
    _syncActiveConversationSnapshot(touchUpdatedAt: false);
    notifyListeners();
  }

  void updateModelPath(String path) {
    _updateSettings(_settings.copyWith(modelPath: path));
  }

  /// Apply model-specific recommended generation and runtime parameters.
  void applyModelPreset(DownloadableModel model) {
    final shouldKeepToolsEnabled =
        model.supportsToolCalling && _settings.toolsEnabled;
    const androidCpuPreferredQwenModels = <String>{
      'Qwen3.5 0.8B Instruct',
      'Qwen3.5 2B Instruct',
    };
    final shouldUseReducedAndroidContext =
        !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.android &&
        model.name == 'Qwen3.5 0.8B Instruct';
    final shouldPreferCpuOnAndroid =
        !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.android &&
        androidCpuPreferredQwenModels.contains(model.name) &&
        (_settings.preferredBackend == GpuBackend.auto ||
            _settings.preferredBackend == GpuBackend.vulkan ||
            _settings.preferredBackend == GpuBackend.cpu);

    _updateSettings(
      _settings.copyWith(
        temperature: model.preset.temperature,
        topK: model.preset.topK,
        topP: model.preset.topP,
        minP: model.preset.minP,
        penalty: model.preset.penalty,
        contextSize: shouldUseReducedAndroidContext
            ? 2048
            : model.preset.contextSize,
        maxTokens: model.preset.maxTokens,
        gpuLayers: shouldPreferCpuOnAndroid ? 0 : model.preset.gpuLayers,
        preferredBackend: shouldPreferCpuOnAndroid
            ? GpuBackend.cpu
            : _settings.preferredBackend,
        toolsEnabled: shouldKeepToolsEnabled,
        thinkingEnabled: model.preset.thinkingEnabled,
        thinkingBudgetTokens: model.preset.thinkingBudgetTokens,
        singleTurnMode: false,
      ),
    );

    if (shouldPreferCpuOnAndroid) {
      _addInfoMessage(
        'On Android, Qwen3.5 0.8B/2B currently run faster and more reliably in CPU mode than Vulkan. You can switch back manually in Inference settings if you want to compare.',
      );
      notifyListeners();
    }
  }

  void _updateToolTemplateSupport(Map<String, String> metadata) {
    final toolTemplate = metadata['tokenizer.chat_template.tool_use'];
    final defaultTemplate = metadata['tokenizer.chat_template'];

    final effectiveTemplate =
        (toolTemplate != null && toolTemplate.trim().isNotEmpty)
        ? toolTemplate
        : defaultTemplate;

    if (effectiveTemplate == null || effectiveTemplate.trim().isEmpty) {
      _detectedChatFormat = null;
      _templateSupportsTools = true;
      return;
    }

    final format = ChatTemplateEngine.detectFormat(effectiveTemplate);
    _detectedChatFormat = format;

    final hasDedicatedToolTemplate =
        toolTemplate != null && toolTemplate.trim().isNotEmpty;

    _templateSupportsTools =
        hasDedicatedToolTemplate || format != ChatFormat.contentOnly;

    if (_settings.toolsEnabled && !_templateSupportsTools) {
      _settings = _settings.copyWith(toolsEnabled: false);
      unawaited(_saveSettingsNow());
      _messages.add(
        ChatMessage(
          text:
              'Tool calling disabled for this model: template is content-only.',
          isUser: false,
          isInfo: true,
        ),
      );
      _syncActiveConversationSnapshot();
    }
  }

  Future<String?> _getBackendInfoBestEffort() async {
    try {
      return await _chatService.engine.getBackendName();
    } catch (_) {
      return null;
    }
  }

  Future<String?> _getAvailableBackendInfoBestEffort() async {
    try {
      return await _chatService.engine.getAvailableBackends();
    } catch (_) {
      return null;
    }
  }

  Future<int?> _getResolvedGpuLayersBestEffort() async {
    try {
      return await _chatService.engine.getResolvedGpuLayers();
    } catch (_) {
      return null;
    }
  }

  void updateMmprojPath(String path) {
    _updateSettings(_settings.copyWith(mmprojPath: path));
  }

  Future<bool> loadConfiguredMmproj({
    String successMessage = 'Multimodal projector loaded.',
  }) async {
    final mmprojPath = (_settings.mmprojPath ?? '').trim();
    if (mmprojPath.isEmpty) {
      _addInfoMessage(
        'No mmproj is configured for the active model. Select a multimodal preset or add a matching mmproj first.',
      );
      notifyListeners();
      return false;
    }

    if (!_isLoaded || !_chatService.engine.isReady) {
      _addInfoMessage('Load the model first, then enable mmproj.');
      notifyListeners();
      return false;
    }

    if (_mmprojLoaded && _loadedMmprojPath == mmprojPath) {
      _supportsVision = await _chatService.engine.supportsVision;
      _supportsAudio = await _chatService.engine.supportsAudio;
      notifyListeners();
      return true;
    }

    try {
      await _chatService.loadMultimodalProjector(mmprojPath);
      _mmprojLoaded = true;
      _loadedMmprojPath = mmprojPath;
      _supportsVision = await _chatService.engine.supportsVision;
      _supportsAudio = await _chatService.engine.supportsAudio;
      _addInfoMessage(successMessage);
      notifyListeners();
      return true;
    } catch (error) {
      final text = error.toString();
      _addInfoMessage(
        text.startsWith('Exception: ') ? text.substring(11) : text,
      );
      notifyListeners();
      return false;
    }
  }

  Future<void> clearMmprojPath() async {
    if ((_settings.mmprojPath ?? '').isEmpty && !_mmprojLoaded) {
      return;
    }

    if (_mmprojLoaded) {
      try {
        await _chatService.unloadMultimodalProjector();
      } catch (error) {
        debugPrint('Failed to unload active mmproj: $error');
        _addInfoMessage(
          'Failed to unload the active mmproj cleanly. Reload the model if text output still looks wrong.',
        );
      }
    }

    _updateSettings(_settings.copyWith(mmprojPath: ''));
    _loadedMmprojPath = null;
    _supportsVision = false;
    _supportsAudio = false;
    _mmprojLoaded = false;
    _addInfoMessage(
      'Switched to text-only mode. Multimodal projector cleared.',
    );
    notifyListeners();
  }

  Future<void> updatePreferredBackend(GpuBackend backend) {
    _updateSettings(_settings.copyWith(preferredBackend: backend));
    _messages.add(
      ChatMessage(
        text:
            'Backend preference set to ${backend.name}. Reload model to apply.',
        isUser: false,
        isInfo: true,
      ),
    );
    _syncActiveConversationSnapshot();
    notifyListeners();
    return Future<void>.value();
  }

  @override
  void dispose() {
    _settingsSaveDebounce?.cancel();
    _settingsSaveDebounce = null;
    unawaited(_settingsService.saveSettings(_settings));
    stopGeneration();
    _session?.reset();
    _session = null;
    unawaited(_chatService.dispose());
    super.dispose();
  }

  Future<void> shutdown() async {
    if (_isShuttingDown) {
      return;
    }

    _isShuttingDown = true;
    try {
      await _saveSettingsNow();
      stopGeneration();
      _session?.reset();
      _session = null;
      _isLoaded = false;
      _loadedModelPath = null;
      _loadedMmprojPath = null;
      _supportsVision = false;
      _supportsAudio = false;
      _mmprojLoaded = false;
      _runtimeGpuLayers = null;
      _runtimeThreads = null;
      _runtimeThreadPoolSize = null;
      _runtimeExecution = null;
      _runtimeCoreVariant = null;
      _runtimeWorkerFallbackReason = null;
      _runtimeNotes = null;
      _runtimeModelSource = null;
      _runtimeModelCacheState = null;
      await _chatService.dispose();
    } finally {
      _isShuttingDown = false;
    }
  }

  Future<void> estimateDynamicSettings() async {
    try {
      final vram = await _chatService.engine.getVramInfo();
      final backendInfo = await _getAvailableBackendInfoBestEffort();
      final estimate = _runtimeProfileService.estimateDynamicSettings(
        totalVramBytes: vram.total,
        freeVramBytes: vram.free,
        isWeb: kIsWeb,
        preferredBackend: _settings.preferredBackend,
        currentContextSize: _settings.contextSize,
        backendInfo: backendInfo,
      );

      _updateSettings(
        _settings.copyWith(
          gpuLayers: estimate.gpuLayers,
          contextSize: estimate.contextSize,
        ),
      );
    } catch (e) {
      debugPrint("Error estimating dynamic settings: $e");
    }
  }
}
