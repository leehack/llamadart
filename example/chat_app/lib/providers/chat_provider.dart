import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:llamadart/llamadart.dart';
import 'package:path/path.dart' as p;

import '../models/chat_conversation.dart';
import '../models/chat_message.dart';
import '../models/chat_settings.dart';
import '../models/downloadable_model.dart';
import '../services/assistant_output_service.dart';
import '../services/audio_recording_service.dart';
import '../services/chat_service.dart';
import '../services/chat_generation_service.dart';
import '../services/chat_session_service.dart';
import '../services/conversation_state_service.dart';
import '../services/runtime_profile_service.dart';
import '../services/settings_service.dart';
import '../services/model_service_base.dart' as model_service;
import '../services/tool_declaration_service.dart';
import '../utils/backend_utils.dart';

/// The chat app's microphone capture lifecycle.
enum ChatAudioRecordingState {
  /// No microphone operation is active.
  idle,

  /// Permission and recorder startup are pending.
  starting,

  /// Audio is being captured.
  recording,

  /// The WAV file is being finalized before transcription or chat input.
  stopping,

  /// An active or pending capture is being discarded.
  cancelling,
}

/// The action performed after a microphone recording is finalized.
enum ChatAudioRecordingPurpose {
  /// Run the dedicated whole-file speech-to-text workflow.
  transcription,

  /// Send the recording to a general audio-capable chat model for an answer.
  voiceQuestion,
}

typedef _VoiceQuestionContext = ({
  int operationId,
  int conversationRevision,
  String? modelPath,
  String? mmprojPath,
  String conversationId,
});

typedef _GenerationContext = ({
  int operationId,
  int conversationRevision,
  String? modelPath,
  String? mmprojPath,
  String conversationId,
  ChatSession session,
});

typedef _TextToSpeechContext = ({
  int operationId,
  int conversationRevision,
  String? modelPath,
  String? mmprojPath,
  String conversationId,
});

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

  /// The maximum microphone recording length before automatic transcription.
  static const Duration maxAudioRecordingDuration = Duration(minutes: 5);

  /// The maximum voice-question recording accepted by Gemma 4 audio input.
  static const Duration maxVoiceQuestionRecordingDuration = Duration(
    seconds: 30,
  );

  static const String _voiceQuestionPrompt =
      'Listen carefully to every spoken word. Determine what the speaker is '
      'asking, solve that request, and return only the final answer. Do not '
      'merely repeat a word from the recording.';
  static const String _androidDebugImagePath = String.fromEnvironment(
    'LLAMADART_CHAT_APP_DEBUG_IMAGE_PATH',
    defaultValue: '',
  );

  final ChatService _chatService;
  final AudioRecordingService _audioRecordingService;
  final ChatGenerationService _chatGenerationService;
  final ChatSessionService _chatSessionService;
  final ConversationStateService _conversationStateService;
  final RuntimeProfileService _runtimeProfileService;
  final SettingsService _settingsService;
  final model_service.ModelService _modelService;
  final AssistantOutputService _assistantOutputService;
  final ToolDeclarationService _toolDeclarationService;
  final bool _enableWebModelPrefetch;

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
  bool _isTranscribing = false;
  ChatAudioRecordingState _audioRecordingState = ChatAudioRecordingState.idle;
  bool _isShuttingDown = false;
  bool _supportsVision = false;
  bool _supportsAudio = false;
  bool _templateSupportsTools = true;
  bool _thinkingControlsSupported = true;
  ChatFormat? _detectedChatFormat;
  String? _error;
  Timer? _settingsSaveDebounce;
  CancelToken? _activeModelPrefetchCancelToken;
  SpeechToTextTask? _activeSpeechToTextTask;
  Completer<void>? _activeTranscriptionDone;
  TextToSpeechTask? _activeTextToSpeechTask;
  Completer<void>? _activeTextToSpeechDone;
  TextToSpeechResult? _textToSpeechResult;
  TextToSpeechProgressEvent? _textToSpeechProgress;
  String? _textToSpeechError;
  bool _isSynthesizingSpeech = false;
  int _textToSpeechOperationSequence = 0;
  int? _activeTextToSpeechOperationId;
  Completer<void>? _activeRecordingTransitionDone;
  Completer<void>? _activeRecordingCancellationDone;
  Timer? _audioRecordingTimer;
  Duration _audioRecordingElapsed = Duration.zero;
  ChatAudioRecordingPurpose? _audioRecordingPurpose;
  int _voiceQuestionOperationSequence = 0;
  int? _activeVoiceQuestionOperationId;
  int _generationOperationSequence = 0;
  int? _activeGenerationOperationId;
  String? _audioRecordingModelPath;
  String? _audioRecordingMmprojPath;
  String? _audioRecordingConversationId;
  int _audioRecordingRevision = 0;
  int _conversationRevision = 0;
  bool _isDisposed = false;

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
  bool get isTranscribing => _isTranscribing;

  /// Whether a text-to-speech task is currently generating audio.
  bool get isSynthesizingSpeech => _isSynthesizingSpeech;

  /// Latest complete synthesized audio for the active conversation and model.
  TextToSpeechResult? get textToSpeechResult => _textToSpeechResult;

  /// Latest synthesis progress reported by the native runtime.
  TextToSpeechProgressEvent? get textToSpeechProgress => _textToSpeechProgress;

  /// Latest actionable text-to-speech failure.
  String? get textToSpeechError => _textToSpeechError;

  /// The current microphone capture phase.
  ChatAudioRecordingState get audioRecordingState => _audioRecordingState;

  /// Whether the microphone is actively capturing audio frames.
  bool get isRecordingAudio =>
      _audioRecordingState == ChatAudioRecordingState.recording;

  /// Whether microphone startup, capture, stop, or cancellation is active.
  bool get hasActiveAudioRecording =>
      _audioRecordingState != ChatAudioRecordingState.idle;

  /// The elapsed duration of the active microphone recording.
  Duration get audioRecordingElapsed => _audioRecordingElapsed;

  /// The action frozen when the current microphone recording began.
  ChatAudioRecordingPurpose? get audioRecordingPurpose =>
      _audioRecordingPurpose;

  /// Whether the latest plain assistant response can be generated again.
  bool get canRegenerateLastResponse {
    if (_isGenerating ||
        _isTranscribing ||
        hasActiveAudioRecording ||
        _session == null ||
        !_chatService.engine.isReady ||
        _messages.length < 2) {
      return false;
    }

    final assistant = _messages.last;
    if (assistant.isUser ||
        assistant.isInfo ||
        assistant.isToolCall ||
        assistant.isTranscription ||
        assistant.role == LlamaChatRole.tool) {
      return false;
    }

    return _messages
        .take(_messages.length - 1)
        .any((message) => message.isUser && !message.isInfo);
  }

  bool get supportsVision => _supportsVision;
  bool get supportsAudio => _supportsAudio;
  bool get canTranscribeAudio =>
      !kIsWeb &&
      _isLoaded &&
      !_isInitializing &&
      !_isGenerating &&
      !_isTranscribing &&
      !hasActiveAudioRecording &&
      _supportsAudio &&
      _settings.modelSupportsSpeechToText;

  /// Whether the selected profile exposes the dedicated synthesis experience.
  bool get supportsTextToSpeech =>
      !kIsWeb && _settings.modelSupportsTextToSpeech;

  /// Whether a new utterance can be synthesized now.
  bool get canSynthesizeSpeech =>
      supportsTextToSpeech &&
      _isLoaded &&
      !_isInitializing &&
      !_isGenerating &&
      !_isTranscribing &&
      !_isSynthesizingSpeech &&
      !hasActiveAudioRecording &&
      _mmprojLoaded &&
      _chatService.engine.isReady;

  bool get _supportsVoiceQuestionInput {
    if (!_settings.modelSupportsAudio || _settings.modelSupportsSpeechToText) {
      return false;
    }
    if (_settings.directMediaInput) {
      return true;
    }

    final configuredMmproj = (_settings.mmprojPath ?? '').trim();
    final loadedMmproj = (_loadedMmprojPath ?? '').trim();
    return configuredMmproj.isNotEmpty &&
        _mmprojLoaded &&
        loadedMmproj == configuredMmproj &&
        _supportsAudio;
  }

  /// Whether the active audio-chat model can answer a recorded question.
  ///
  /// Direct-media models use their declared audio capability. External-media
  /// models additionally require a configured, loaded projector and a positive
  /// runtime audio capability probe. Dedicated ASR profiles remain separate.
  bool get canAskWithVoice =>
      !kIsWeb &&
      _isLoaded &&
      !_isInitializing &&
      !_isGenerating &&
      !_isTranscribing &&
      !hasActiveAudioRecording &&
      _supportsAudio &&
      _supportsVoiceQuestionInput;

  /// Whether the selected model/platform exposes a microphone action.
  ///
  /// This remains true while the model is busy so the composer can keep the
  /// control visible but disabled instead of shifting its layout.
  bool get supportsMicrophoneRecording =>
      !kIsWeb &&
      _audioRecordingService.isSupported &&
      (_settings.modelSupportsSpeechToText || _supportsVoiceQuestionInput);

  /// Whether the active model can start a supported microphone workflow.
  bool get canStartAudioRecording =>
      _audioRecordingService.isSupported &&
      (canTranscribeAudio || canAskWithVoice);
  bool get templateSupportsTools => _templateSupportsTools;
  bool get thinkingControlsSupported => _thinkingControlsSupported;
  String? get error => _error;
  double get temperature => _settings.temperature;
  int get topK => _settings.topK;
  double get topP => _settings.topP;
  double get minP => _settings.minP;
  double get penalty => _settings.penalty;
  int get contextSize => _settings.contextSize;
  int get gpuLayers => _settings.gpuLayers;
  bool get autoTuneModelParams => _settings.autoTuneModelParams;
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
    final withoutSensitiveSuffix = modelPath.split('?').first.split('#').first;
    final normalized = withoutSensitiveSuffix.replaceAll('\\', '/');
    final pieces = normalized.split('/').where((part) => part.isNotEmpty);
    return pieces.isEmpty ? 'Selected model' : pieces.last;
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
    AudioRecordingService? audioRecordingService,
    ChatGenerationService? chatGenerationService,
    ChatSessionService? chatSessionService,
    ConversationStateService? conversationStateService,
    RuntimeProfileService? runtimeProfileService,
    SettingsService? settingsService,
    model_service.ModelService? modelService,
    AssistantOutputService? assistantOutputService,
    ToolDeclarationService? toolDeclarationService,
    ChatSettings? initialSettings,
    bool? enableWebModelPrefetch,
  }) : _chatService = chatService ?? ChatService(),
       _audioRecordingService =
           audioRecordingService ?? AudioRecordingService(),
       _chatGenerationService =
           chatGenerationService ?? const ChatGenerationService(),
       _chatSessionService = chatSessionService ?? const ChatSessionService(),
       _conversationStateService =
           conversationStateService ?? const ConversationStateService(),
       _runtimeProfileService =
           runtimeProfileService ?? const RuntimeProfileService(),
       _settingsService = settingsService ?? SettingsService(),
       _modelService = modelService ?? model_service.ModelService(),
       _assistantOutputService =
           assistantOutputService ?? const AssistantOutputService(),
       _toolDeclarationService =
           toolDeclarationService ?? const ToolDeclarationService(),
       _enableWebModelPrefetch = enableWebModelPrefetch ?? kIsWeb,
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
    unawaited(_cancelAndAwaitAudioRecording());
    _invalidateActiveTextToSpeech(clearOutput: true);
    final hadActiveGeneration = _activeGenerationOperationId != null;
    _invalidateActiveVoiceQuestion(releaseGeneration: true);
    _invalidateActiveGeneration(cancelNative: true);
    if (hadActiveGeneration) {
      _removeEmptyAssistantPlaceholder();
    }
    _invalidateActiveTranscription();
    _syncActiveConversationSnapshot();

    final id = _conversationStateService.newConversationId();
    final copiedSettings = _settings.copyWith();

    _messages.clear();
    _stagedParts.clear();
    _currentTokens = 0;
    _isPruning = false;
    _error = null;
    _isGenerating = _isTranscribing || _isSynthesizingSpeech;
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

    final hadActiveGeneration = _activeGenerationOperationId != null;
    _invalidateActiveVoiceQuestion(releaseGeneration: true);
    _invalidateActiveGeneration(cancelNative: true);
    if (hadActiveGeneration) {
      _removeEmptyAssistantPlaceholder();
      _restoreSessionFromMessages();
    }
    await _cancelAndAwaitAudioRecording();
    await _cancelAndAwaitActiveTranscription();
    await _cancelAndAwaitActiveTextToSpeech();
    _clearTextToSpeechOutput();

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
      _resetRuntimeCapabilities();
      _clearRuntimeDiagnostics();
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
      _logDart(LlamaLogLevel.warn, "Error fetching available backends: $e");
    }

    try {
      activeBackendInfo = await _chatService.engine.getBackendName();
    } catch (e) {
      _logDart(LlamaLogLevel.warn, "Error fetching active backend: $e");
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

  void _logDart(LlamaLogLevel level, String message) {
    final configured = _settings.logLevel;
    if (configured == LlamaLogLevel.none || level.index < configured.index) {
      return;
    }
    debugPrint(message);
  }

  bool _isRemoteUrl(String? value) {
    if (value == null || value.isEmpty) {
      return false;
    }
    final uri = Uri.tryParse(value);
    return uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
  }

  bool _isLiteRtLmModelPath(String? value) {
    if (value == null || value.isEmpty) {
      return false;
    }
    final withoutQuery = value.split('?').first.split('#').first;
    return withoutQuery.toLowerCase().endsWith('.litertlm');
  }

  bool _webCachePrefetchWouldPersistSensitiveUrl() {
    return hasPersistentCacheSensitiveUrlParts(_settings.modelPath ?? '');
  }

  String _filenameFromPathOrUrl(
    String value, {
    String fallback = 'model.gguf',
  }) {
    final uri = Uri.tryParse(value);
    final path = (uri?.hasScheme ?? false) ? uri!.path : value;
    final normalized = path.replaceAll('\\', '/');
    final pieces = normalized.split('/').where((part) => part.isNotEmpty);
    final filename = pieces.isEmpty ? fallback : pieces.last;
    return filename.isEmpty ? fallback : filename;
  }

  DownloadableModel? _downloadableModelForCurrentSettings() {
    final modelPath = _settings.modelPath;
    if (!_isRemoteUrl(modelPath)) {
      return null;
    }

    return DownloadableModel(
      name: _filenameFromPathOrUrl(modelPath!),
      description: 'Chat startup model cache prefetch',
      url: modelPath,
      filename: _filenameFromPathOrUrl(modelPath),
      sizeBytes: 0,
    );
  }

  bool _sameLocalPath(String first, String second) {
    return p.equals(
      p.normalize(p.absolute(first)),
      p.normalize(p.absolute(second)),
    );
  }

  Future<bool> _isRelocatableIosCatalogPath(
    String configuredPath, {
    required String expectedFilename,
  }) async {
    if (kIsWeb ||
        defaultTargetPlatform != TargetPlatform.iOS ||
        !p.isAbsolute(configuredPath) ||
        !p.equals(p.basename(configuredPath), expectedFilename) ||
        await File(configuredPath).exists()) {
      return false;
    }

    final components = p
        .normalize(configuredPath)
        .split(p.separator)
        .where((component) => component.isNotEmpty)
        .toList(growable: false);
    if (components.length < 10) {
      return false;
    }
    final tail = components.sublist(components.length - 10);
    return p.equals(tail[0], 'var') &&
        p.equals(tail[1], 'mobile') &&
        p.equals(tail[2], 'Containers') &&
        p.equals(tail[3], 'Data') &&
        p.equals(tail[4], 'Application') &&
        tail[5].isNotEmpty &&
        p.equals(tail[6], 'Library') &&
        p.equals(tail[7], 'Caches') &&
        p.equals(tail[8], 'models') &&
        p.equals(tail[9], expectedFilename);
  }

  Future<void> _preflightManagedCatalogModel() async {
    final configuredModelPath = _settings.modelPath?.trim();
    if (kIsWeb ||
        configuredModelPath == null ||
        configuredModelPath.isEmpty ||
        !p.isAbsolute(configuredModelPath) ||
        _isRemoteUrl(configuredModelPath)) {
      return;
    }

    final configuredFilename = p.basename(configuredModelPath);
    final matchingCatalogModels = <DownloadableModel>[];
    for (final candidate in DownloadableModel.defaultModels) {
      final source = candidate.modelSource;
      if (source is RemoteModelAssetSource &&
          p.equals(source.filename, configuredFilename)) {
        matchingCatalogModels.add(candidate);
      }
    }
    if (matchingCatalogModels.isEmpty) {
      return;
    }

    final modelsDir = await _modelService.getModelsDirectory();
    DownloadableModel? catalogModel;
    var shouldRelocateModelPath = false;
    for (final candidate in matchingCatalogModels) {
      final source = candidate.modelSource as RemoteModelAssetSource;
      final managedPath = p.join(modelsDir, source.filename);
      if (_sameLocalPath(configuredModelPath, managedPath)) {
        catalogModel = candidate;
        break;
      }
      if (await _isRelocatableIosCatalogPath(
        configuredModelPath,
        expectedFilename: source.filename,
      )) {
        catalogModel = candidate;
        shouldRelocateModelPath = true;
        break;
      }
    }
    if (catalogModel == null) {
      return;
    }

    final cacheState = await _modelService.getModelCacheState(catalogModel);
    if (!cacheState.model.isAvailable) {
      throw LlamaModelException(
        'The cached ${catalogModel.name} model is incomplete or does not '
        'match the pinned catalog artifact. Open Manage models, remove its '
        'cached assets, and download it again.',
      );
    }

    final projectorSource = catalogModel.multimodalProjectorSource;
    final configuredProjectorPath = _settings.mmprojPath?.trim();
    var shouldRelocateProjectorPath = false;
    var usesManagedCatalogProjector = false;
    String? managedProjectorPath;
    if (projectorSource is RemoteModelAssetSource &&
        configuredProjectorPath != null &&
        configuredProjectorPath.isNotEmpty) {
      managedProjectorPath = p.join(modelsDir, projectorSource.filename);
      usesManagedCatalogProjector = _sameLocalPath(
        configuredProjectorPath,
        managedProjectorPath,
      );
      if (!usesManagedCatalogProjector) {
        shouldRelocateProjectorPath = await _isRelocatableIosCatalogPath(
          configuredProjectorPath,
          expectedFilename: projectorSource.filename,
        );
        usesManagedCatalogProjector = shouldRelocateProjectorPath;
      }
    }
    if (usesManagedCatalogProjector &&
        !(cacheState.multimodalProjector?.isAvailable ?? false)) {
      throw LlamaModelException(
        'The cached ${catalogModel.name} multimodal projector is incomplete '
        'or does not match the pinned catalog artifact. Open Manage models, '
        'remove its cached assets, and download it again.',
      );
    }

    final catalogSizeBytes = catalogModel.sizeBytesFor(web: false);
    final usesCompleteManagedCatalogProfile =
        projectorSource == null || usesManagedCatalogProjector;
    final shouldUpdateSizeHint =
        usesCompleteManagedCatalogProfile &&
        catalogSizeBytes > 0 &&
        _settings.modelBytesHint != catalogSizeBytes;
    if (shouldRelocateModelPath ||
        shouldRelocateProjectorPath ||
        shouldUpdateSizeHint) {
      _settings = _settings.copyWith(
        modelPath: shouldRelocateModelPath
            ? p.join(
                modelsDir,
                (catalogModel.modelSource as RemoteModelAssetSource).filename,
              )
            : _settings.modelPath,
        mmprojPath: shouldRelocateProjectorPath
            ? managedProjectorPath
            : _settings.mmprojPath,
        modelBytesHint: shouldUpdateSizeHint
            ? catalogSizeBytes
            : _settings.modelBytesHint,
      );
      _syncActiveConversationSnapshot(touchUpdatedAt: false);
      await _saveSettingsNow();
    }
  }

  void _cancelActiveModelPrefetch() {
    final cancelToken = _activeModelPrefetchCancelToken;
    if (cancelToken != null && !cancelToken.isCancelled) {
      cancelToken.cancel('Model prefetch cancelled');
    }
    _activeModelPrefetchCancelToken = null;
  }

  void _resetRuntimeCapabilities() {
    _supportsVision = false;
    _supportsAudio = false;
    _mmprojLoaded = false;
    _templateSupportsTools = true;
    _thinkingControlsSupported = true;
  }

  void _clearRuntimeDiagnostics() {
    _runtimeGpuLayers = null;
    _runtimeThreads = null;
    _runtimeThreadPoolSize = null;
    _runtimeExecution = null;
    _runtimeCoreVariant = null;
    _runtimeWorkerFallbackReason = null;
    _runtimeNotes = null;
    _runtimeModelSource = null;
    _runtimeModelCacheState = null;
  }

  void _clearGenerationMetrics() {
    _lastTokensPerSecond = null;
    _lastDecodeTokensPerSecond = null;
    _lastNativePromptEvalMs = null;
    _lastNativeEvalMs = null;
    _lastNativeSampleMs = null;
    _lastNativePromptEvalTokens = null;
    _lastNativeEvalTokens = null;
    _lastNativeReusedGraphs = null;
  }

  void _clearLoadedRuntimeState({String? activeBackend, int? contextLimit}) {
    _isLoaded = false;
    if (activeBackend != null) {
      _activeBackend = activeBackend;
    }
    if (contextLimit != null) {
      _contextLimit = contextLimit;
    }
    _loadedModelPath = null;
    _loadedMmprojPath = null;
    _resetRuntimeCapabilities();
    _clearRuntimeDiagnostics();
  }

  Future<bool> _prefetchWebRemoteModelIfNeeded(
    void Function(double value, {String? backendLabel, bool forceNotify})
    updateLoadingUi,
  ) async {
    if (!_enableWebModelPrefetch || !_isRemoteUrl(_settings.modelPath)) {
      return false;
    }
    if (_webCachePrefetchWouldPersistSensitiveUrl()) {
      updateLoadingUi(
        0.14,
        backendLabel:
            'Browser cache skipped for credentialed URL; loading from network...',
        forceNotify: true,
      );
      return false;
    }
    if (_modelService is! model_service.WebCachePrefetchModelService) {
      return false;
    }
    final prefetchService =
        _modelService as model_service.WebCachePrefetchModelService;
    if (!await prefetchService.supportsWebCachePrefetch()) {
      return false;
    }

    final model = _downloadableModelForCurrentSettings();
    if (model == null) {
      return false;
    }

    final cancelToken = CancelToken();
    _activeModelPrefetchCancelToken = cancelToken;
    final modelsDir = await _modelService.getModelsDirectory();
    Object? downloadError;
    var completed = false;

    try {
      updateLoadingUi(
        0.14,
        backendLabel: 'Downloading model 0%',
        forceNotify: true,
      );

      await _modelService.downloadModel(
        model: model,
        modelsDir: modelsDir,
        cancelToken: cancelToken,
        onProgress: (progress) {
          if (cancelToken.isCancelled || _isDisposed) {
            return;
          }
          final normalized = progress.clamp(0.0, 1.0);
          updateLoadingUi(
            0.14 + (normalized * 0.58),
            backendLabel:
                'Downloading model ${(normalized * 100).toStringAsFixed(0)}%',
            forceNotify: normalized >= 1.0,
          );
        },
        onProgressDetail: (progress) {
          if (cancelToken.isCancelled || _isDisposed) {
            return;
          }
          final normalized = progress.overallProgress.clamp(0.0, 1.0);
          updateLoadingUi(
            0.14 + (normalized * 0.58),
            backendLabel:
                'Downloading model ${(normalized * 100).toStringAsFixed(0)}%',
            forceNotify: normalized >= 1.0,
          );
        },
        onSuccess: (_) {
          completed = true;
        },
        onError: (error) {
          downloadError = error;
        },
      );
    } finally {
      if (identical(_activeModelPrefetchCancelToken, cancelToken)) {
        _activeModelPrefetchCancelToken = null;
      }
    }

    if (cancelToken.isCancelled) {
      throw DioException(
        requestOptions: RequestOptions(path: 'web-cache-prefetch'),
        type: DioExceptionType.cancel,
        message: 'Model prefetch cancelled',
      );
    }
    if (downloadError != null) {
      if (_isNonFatalWebCachePrefetchFailure(downloadError!)) {
        updateLoadingUi(
          0.14,
          backendLabel: 'Browser cache unavailable; loading from network...',
          forceNotify: true,
        );
        return false;
      }
      throw downloadError!;
    }
    if (!completed) {
      throw Exception('Model download did not complete.');
    }

    updateLoadingUi(
      0.72,
      backendLabel: _isLiteRtLmModelPath(_settings.modelPath)
          ? 'Preparing LiteRT-LM runtime...'
          : 'Preparing WebGPU runtime...',
      forceNotify: true,
    );
    return true;
  }

  Future<void> loadModel() async {
    if (_isDisposed || _isInitializing) return;
    if (_settings.modelPath == null || _settings.modelPath!.isEmpty) {
      _error = 'Model path not set. Please configure in settings.';
      _syncActiveConversationSnapshot(touchUpdatedAt: false);
      notifyListeners();
      return;
    }

    await _cancelAndAwaitAudioRecording();
    await _cancelAndAwaitActiveTextToSpeech();

    _isInitializing = true;
    _isLoaded = false;
    _error = null;
    _loadingProgress = 0.0;
    _activeBackend = 'Loading model...';
    _resetRuntimeCapabilities();
    _clearRuntimeDiagnostics();
    notifyListeners();

    DateTime lastProgressNotifyAt = DateTime.now();
    double lastProgressNotified = 0.0;

    void updateLoadingUi(
      double value, {
      String? backendLabel,
      bool forceNotify = false,
    }) {
      if (_isDisposed) {
        return;
      }
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

    updateLoadingUi(0.1);

    try {
      await _preflightManagedCatalogModel();
      final eagerLoadMmproj =
          (_settings.mmprojPath?.trim().isNotEmpty ?? false);

      await _chatService.engine.setDartLogLevel(_settings.logLevel);
      await _chatService.engine.setNativeLogLevel(_settings.nativeLogLevel);
      if (_chatService.engine.isReady) {
        await _chatService.unloadModel();
      }

      // Measure device headroom after unloading the previous model; otherwise
      // a model switch can make Auto look artificially memory-constrained.
      if (!_isLiteRtLmModelPath(_settings.modelPath) &&
          _settings.preferredBackend == GpuBackend.auto &&
          (_settings.autoTuneModelParams ||
              _settings.gpuLayers == 32 ||
              _settings.gpuLayers >= 99)) {
        try {
          await estimateDynamicSettings();
        } catch (e) {
          _logDart(LlamaLogLevel.warn, "Dynamic estimation failed: $e");
        }
      }
      updateLoadingUi(0.14);

      // On web the LiteRT-LM backend downloads + initializes the model through
      // @litert-lm/core and only reports 0%/100%, so a percentage would sit at
      // "0%" for the whole download and look frozen. Show an honest
      // indeterminate message there. Native/local .litertlm loads read from a
      // file path (no download), so they keep the generic progress label.
      final isLiteRtLmLoad =
          kIsWeb && _isLiteRtLmModelPath(_settings.modelPath);
      final prefetchedWebModel = await _prefetchWebRemoteModelIfNeeded(
        updateLoadingUi,
      );
      final modelLoadStart = prefetchedWebModel ? 0.72 : 0.14;
      final modelLoadSpan = prefetchedWebModel ? 0.12 : 0.7;
      const liteRtLmLoadingLabel =
          'Downloading and initializing model (first load may take a while)...';
      const liteRtLmCachedLoadingLabel =
          'Initializing cached LiteRT-LM model...';
      if (prefetchedWebModel) {
        updateLoadingUi(
          modelLoadStart,
          backendLabel: isLiteRtLmLoad
              ? liteRtLmCachedLoadingLabel
              : 'Loading model into memory...',
          forceNotify: true,
        );
      } else if (isLiteRtLmLoad) {
        updateLoadingUi(
          modelLoadStart,
          backendLabel: liteRtLmLoadingLabel,
          forceNotify: true,
        );
      }

      if (isLiteRtLmLoad) {
        await Future<void>.delayed(Duration.zero);
      }

      await _chatService.init(
        _settings,
        eagerLoadMultimodalProjector: eagerLoadMmproj,
        eagerWarmUpLiteRtLmRuntime: !isLiteRtLmLoad,
        onProgress: (progress) {
          final normalized = progress.clamp(0.0, 1.0);
          final staged = modelLoadStart + (normalized * modelLoadSpan);
          final String backendLabel;
          if (prefetchedWebModel && isLiteRtLmLoad) {
            backendLabel = liteRtLmCachedLoadingLabel;
          } else if (prefetchedWebModel) {
            backendLabel =
                'Loading model into memory ${(normalized * 100).toStringAsFixed(0)}%';
          } else if (isLiteRtLmLoad) {
            // Avoid a misleading "0%" stuck for the whole load.
            backendLabel = liteRtLmLoadingLabel;
          } else {
            backendLabel =
                'Loading model ${(normalized * 100).toStringAsFixed(0)}%';
          }
          updateLoadingUi(staged, backendLabel: backendLabel);
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
      final declaredDirectVision =
          _settings.directMediaInput && _settings.modelSupportsVision;
      final declaredDirectAudio =
          _settings.directMediaInput && _settings.modelSupportsAudio;
      _supportsVision =
          runtimeSupportsVision ||
          declaredDirectVision ||
          (!_mmprojLoaded && inferredCapabilities.supportsVision);
      _supportsAudio =
          runtimeSupportsAudio ||
          declaredDirectAudio ||
          (!_mmprojLoaded && inferredCapabilities.supportsAudio);
      _updateThinkingControlSupport(metadata);
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
      if (isGemma4 &&
          _settings.modelSupportsAudio &&
          _mmprojLoaded &&
          _supportsVision &&
          !_supportsAudio) {
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
      if (_isDisposed) {
        return;
      }
      final displayError = _formatDisplayError(e);
      _logDart(LlamaLogLevel.error, 'Error loading model: $displayError');
      _logDart(LlamaLogLevel.debug, stackTrace.toString());
      _error = displayError;
      _loadedModelPath = null;
      _loadedMmprojPath = null;
      _resetRuntimeCapabilities();
    } finally {
      _isInitializing = false;
      if (!_isDisposed) {
        notifyListeners();
      }
    }
  }

  bool _isNonFatalWebCachePrefetchFailure(Object error) {
    final normalized = error.toString().toLowerCase();
    if (normalized.contains('browser cache prefetch skipped') &&
        normalized.contains('credentialed')) {
      return true;
    }
    final mentionsCache =
        normalized.contains('browser cache') ||
        normalized.contains('cachestorage') ||
        normalized.contains('cache storage') ||
        normalized.contains('model cache') ||
        normalized.contains('quota');
    final mentionsStoreFailure =
        normalized.contains('failed to store') ||
        normalized.contains('store_failed') ||
        normalized.contains('storage') ||
        normalized.contains('quota') ||
        normalized.contains('quotaexceeded');
    return mentionsCache && mentionsStoreFailure;
  }

  String _redactPotentiallySensitiveUrls(String text) {
    final urlPattern = RegExp(r'''https?:\/\/[^\s\])}>"']+''');
    return text.replaceAllMapped(urlPattern, (match) {
      final value = match.group(0)!;
      final uri = Uri.tryParse(value);
      if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
        return value;
      }
      final redacted = Uri(
        scheme: uri.scheme,
        host: uri.host,
        port: uri.hasPort ? uri.port : null,
        path: uri.path,
      );
      return redacted.toString();
    });
  }

  String _formatDisplayError(Object error) {
    final raw = _redactPotentiallySensitiveUrls(error.toString().trim());
    const prefixes = <String>['LlamaException: ', 'Exception: '];
    for (final prefix in prefixes) {
      if (raw.startsWith(prefix)) {
        return raw.substring(prefix.length).trim();
      }
    }
    return raw;
  }

  void clearConversation() {
    unawaited(_cancelAndAwaitAudioRecording());
    final wasSynthesizingSpeech = _isSynthesizingSpeech;
    _invalidateActiveTextToSpeech(clearOutput: true);
    _invalidateActiveVoiceQuestion(releaseGeneration: true);
    _invalidateActiveGeneration(cancelNative: true);
    final wasTranscribing = _isTranscribing;
    _invalidateActiveTranscription();
    _messages.clear();
    _session?.reset();
    _session = _chatService.engine.isReady && _isLoaded
        ? _chatSessionService.createSession(
            engine: _chatService.engine,
            contextSize: _settings.contextSize,
            systemPrompt: _sessionSystemPrompt(),
          )
        : null;
    _currentTokens = 0;
    _isPruning = false;
    _isGenerating = wasTranscribing || wasSynthesizingSpeech;
    _stagedParts.clear();
    _clearGenerationMetrics();
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
    if (_isGenerating ||
        _isTranscribing ||
        hasActiveAudioRecording ||
        _session == null) {
      return;
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

    final generationContext = _beginGeneration();
    if (generationContext == null) {
      return;
    }
    var generationStarted = false;
    try {
      if (_settings.singleTurnMode) {
        generationContext.session.reset();
      }

      if (!await _ensureMultimodalProjectorForMedia(parts) ||
          !_generationContextMatches(generationContext)) {
        return;
      }

      // For UI display, include text in parts
      final displayParts = [
        ...parts,
        if (text.isNotEmpty) LlamaTextContent(text),
      ];
      final userMsg = ChatMessage(
        text: text,
        isUser: true,
        parts: displayParts,
      );
      _messages.add(userMsg);
      _stagedParts.clear();
      _syncActiveConversationSnapshot();
      notifyListeners();

      await _yieldUiFrame();
      if (!_generationContextMatches(generationContext)) {
        return;
      }

      generationStarted = true;
      await _generateResponse(
        text,
        context: generationContext,
        parts: parts.isEmpty ? null : parts,
      );
    } finally {
      if (!generationStarted) {
        _releaseGeneration(generationContext);
      }
    }
  }

  /// Removes the latest plain assistant response and generates a replacement.
  Future<void> regenerateLastResponse() async {
    if (!canRegenerateLastResponse) return;

    final replacedTokenCount =
        _messages.last.generatedTokenCount ?? _messages.last.tokenCount ?? 0;
    var userIndex = -1;
    for (var index = _messages.length - 2; index >= 0; index--) {
      if (_messages[index].isUser && !_messages[index].isInfo) {
        userIndex = index;
        break;
      }
    }
    if (userIndex < 0) return;

    final userMessage = _messages[userIndex];
    final requestText = userMessage.parts
        ?.whereType<LlamaTextContent>()
        .map((part) => part.text)
        .where((text) => text.trim().isNotEmpty)
        .join('\n');
    final mediaParts = userMessage.parts
        ?.where((part) => part is! LlamaTextContent)
        .toList(growable: false);
    final expectedConversationRevision = _conversationRevision;
    final expectedModelPath = _settings.modelPath;
    final expectedMmprojPath = _settings.mmprojPath;
    final expectedConversationId = _activeConversationId;
    final expectedSession = _session;
    if (mediaParts != null &&
        mediaParts.isNotEmpty &&
        !await _ensureMultimodalProjectorForMedia(mediaParts)) {
      return;
    }
    if (expectedConversationRevision != _conversationRevision ||
        expectedModelPath != _settings.modelPath ||
        expectedMmprojPath != _settings.mmprojPath ||
        expectedConversationId != _activeConversationId ||
        !identical(expectedSession, _session)) {
      return;
    }

    _messages.removeLast();
    _currentTokens = math.max(0, _currentTokens - replacedTokenCount);
    _lastFirstTokenLatencyMs = null;
    _lastGenerationLatencyMs = null;
    _clearGenerationMetrics();

    final history = _settings.singleTurnMode
        ? const <ChatMessage>[]
        : _messages.take(userIndex);
    _session = _chatSessionService.rebuildFromMessages(
      engine: _chatService.engine,
      contextSize: _settings.contextSize,
      systemPrompt: _sessionSystemPrompt(),
      messages: history,
    );
    final generationContext = _beginGeneration();
    if (generationContext == null) {
      return;
    }
    _syncActiveConversationSnapshot();
    notifyListeners();

    var generationStarted = false;
    try {
      await _yieldUiFrame();
      if (!_generationContextMatches(generationContext)) {
        return;
      }
      generationStarted = true;
      await _generateResponse(
        requestText == null || requestText.isEmpty
            ? userMessage.text
            : requestText,
        context: generationContext,
        parts: mediaParts == null || mediaParts.isEmpty ? null : mediaParts,
      );
    } finally {
      if (!generationStarted) {
        _releaseGeneration(generationContext);
      }
    }
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

    if (_settings.directMediaInput) {
      final needsVision = parts.any((part) => part is LlamaImageContent);
      final needsAudio = parts.any((part) => part is LlamaAudioContent);
      final missing = <String>[
        if (needsVision && !_supportsVision) 'image',
        if (needsAudio && !_supportsAudio) 'audio',
      ];
      if (missing.isEmpty) {
        return true;
      }

      _addInfoMessage(
        'The active model backend does not support ${missing.join(' or ')} input on this platform.',
      );
      notifyListeners();
      return false;
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

  _GenerationContext? _beginGeneration() {
    final session = _session;
    if (session == null || !_chatService.engine.isReady) {
      return null;
    }

    final operationId = ++_generationOperationSequence;
    final context = (
      operationId: operationId,
      conversationRevision: _conversationRevision,
      modelPath: _settings.modelPath,
      mmprojPath: _settings.mmprojPath,
      conversationId: _activeConversationId,
      session: session,
    );
    _activeGenerationOperationId = operationId;
    _isGenerating = true;
    return context;
  }

  bool _generationContextMatches(_GenerationContext context) =>
      _activeGenerationOperationId == context.operationId &&
      _isGenerating &&
      context.conversationRevision == _conversationRevision &&
      context.modelPath == _settings.modelPath &&
      context.mmprojPath == _settings.mmprojPath &&
      context.conversationId == _activeConversationId &&
      identical(context.session, _session);

  void _releaseGeneration(_GenerationContext context) {
    if (_activeGenerationOperationId != context.operationId) {
      return;
    }
    _activeGenerationOperationId = null;
    if (!_isTranscribing) {
      _isGenerating = false;
    }
    if (_generationIdentityMatches(context)) {
      _syncActiveConversationSnapshot();
    }
    if (!_isDisposed) {
      notifyListeners();
    }
  }

  bool _generationIdentityMatches(_GenerationContext context) =>
      context.conversationRevision == _conversationRevision &&
      context.modelPath == _settings.modelPath &&
      context.mmprojPath == _settings.mmprojPath &&
      context.conversationId == _activeConversationId &&
      identical(context.session, _session);

  void _invalidateActiveGeneration({bool cancelNative = false}) {
    final hadActiveGeneration = _activeGenerationOperationId != null;
    _activeGenerationOperationId = null;
    if (cancelNative && hadActiveGeneration) {
      _chatService.cancelGeneration();
    }
    if (!_isTranscribing) {
      _isGenerating = false;
    }
  }

  Future<void> _generateResponse(
    String text, {
    required _GenerationContext context,
    List<LlamaContentPart>? parts,
  }) async {
    if (!_generationContextMatches(context)) {
      _releaseGeneration(context);
      return;
    }

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
    var appliedGeneratedTokenDeltas = 0;
    var hasMediaPartsInTurn = false;
    var hasAudioPartsInTurn = false;
    var isCpuMultimodalTurn = false;

    try {
      if (!_generationContextMatches(context)) {
        return;
      }
      _messages.add(ChatMessage(text: "...", isUser: false));
      notifyListeners();

      await _yieldUiFrame();
      if (!_generationContextMatches(context)) {
        return;
      }

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
      context.session.systemPrompt = _sessionSystemPrompt();

      generationResult = await _chatGenerationService
          .consumeStream(
            stream: context.session.create(
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
            shouldContinue: () => _generationContextMatches(context),
            stallTimeout: streamStallTimeout,
            onUpdate: (update) {
              if (!_generationContextMatches(context)) {
                return;
              }
              _currentTokens += update.generatedTokenDelta;
              appliedGeneratedTokenDeltas += update.generatedTokenDelta;

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
              if (_generationContextMatches(context)) {
                _chatService.cancelGeneration();
              }
              throw TimeoutException(
                'Generation exceeded wall timeout.',
                streamWallTimeout,
              );
            },
          );

      if (!_generationContextMatches(context)) {
        return;
      }

      final fullResponse = generationResult.fullResponse;
      final fullThinking = generationResult.fullThinking;
      _lastFirstTokenLatencyMs = generationResult.firstTokenLatencyMs;

      // Final update
      if (_messages.isNotEmpty && !_messages.last.isUser) {
        final lastSessionMessage = context.session.history.isNotEmpty
            ? context.session.history.last
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
          // Some backends (e.g. LiteRT-LM on web) don't expose tokenizer
          // operations, so retain the generated-token count as the cache hint
          // instead of failing the turn.
          var tokenCount = generationResult.generatedTokens;
          try {
            tokenCount = await _chatService.engine.getTokenCount(finalText);
          } on LlamaUnsupportedException {
            // Keep the generated-token fallback.
          } on UnsupportedError {
            // Keep the generated-token fallback.
          }
          if (!_generationContextMatches(context)) {
            return;
          }
          if (_messages.isNotEmpty && !_messages.last.isUser) {
            _messages.last.tokenCount = tokenCount;
          }
        }
      }
      _removeEmptyAssistantPlaceholder();
    } catch (e) {
      if (!_generationContextMatches(context)) {
        return;
      }
      _removeEmptyAssistantPlaceholder();
      final errorText = e.toString();
      if (e is TimeoutException) {
        if (_generationContextMatches(context)) {
          _chatService.cancelGeneration();
        }
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
        _messages.add(
          ChatMessage(
            text: 'Error: ${_formatDisplayError(e)}',
            isUser: false,
            isInfo: true,
          ),
        );
      }
    } finally {
      if (_generationContextMatches(context)) {
        final generatedTokens = generationResult.generatedTokens;
        final elapsedMs = generationResult.elapsedMs;
        final decodeElapsedMs = generationResult.decodeElapsedMs;

        BackendPerfContextData? performance;
        try {
          performance = await _chatService.engine.getPerformanceContext();
        } catch (_) {
          performance = null;
        }

        if (_generationContextMatches(context)) {
          final nativeEvalTokens = performance?.evalTokens;
          final nativeEvalMs = performance?.evalMs;
          _lastNativePromptEvalMs = performance?.promptEvalMs.round();
          _lastNativeEvalMs = performance?.evalMs.round();
          _lastNativeSampleMs = performance?.sampleMs.round();
          _lastNativePromptEvalTokens = performance?.promptEvalTokens;
          _lastNativeEvalTokens = nativeEvalTokens;
          _lastNativeReusedGraphs = performance?.reusedGraphs;

          final effectiveGeneratedTokens = nativeEvalTokens ?? generatedTokens;
          if (_messages.isNotEmpty &&
              !_messages.last.isUser &&
              !_messages.last.isInfo) {
            _messages.last.generatedTokenCount = effectiveGeneratedTokens;
          }
          if (nativeEvalTokens != null &&
              nativeEvalTokens != appliedGeneratedTokenDeltas) {
            _currentTokens = math.max(
              0,
              _currentTokens + nativeEvalTokens - appliedGeneratedTokenDeltas,
            );
          }

          if (effectiveGeneratedTokens > 0 && elapsedMs > 0) {
            _lastTokensPerSecond =
                effectiveGeneratedTokens / (elapsedMs / 1000);
          } else {
            _lastTokensPerSecond = null;
          }

          final effectiveDecodeElapsedMs =
              nativeEvalMs != null && nativeEvalMs > 0
              ? nativeEvalMs
              : decodeElapsedMs.toDouble();
          if (effectiveGeneratedTokens > 0 && effectiveDecodeElapsedMs > 0) {
            _lastDecodeTokensPerSecond =
                effectiveGeneratedTokens / (effectiveDecodeElapsedMs / 1000);
          } else {
            _lastDecodeTokensPerSecond = null;
          }

          if (generationResult.firstTokenLatencyMs != null ||
              generationResult.fullResponse.isNotEmpty ||
              generationResult.fullThinking.isNotEmpty) {
            _lastGenerationLatencyMs = elapsedMs;
          }
        }
      }
      _releaseGeneration(context);
    }
  }

  void _removeEmptyAssistantPlaceholder() {
    if (_messages.isEmpty) {
      return;
    }

    final last = _messages.last;
    final hasContentParts = last.parts?.isNotEmpty ?? false;
    final text = last.text.trim();
    if (!last.isUser &&
        !last.isInfo &&
        !hasContentParts &&
        (text.isEmpty || text == '...' || text == 'Transcribing…')) {
      _messages.removeLast();
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

  /// Prepares image [bytes] and stages them for the next message.
  Future<bool> stageImageAttachment(Uint8List bytes) async {
    final prepared = await _prepareImagePartFromBytes(bytes);
    if (prepared == null) {
      return false;
    }
    _addStagedPart(prepared);
    return true;
  }

  /// Stages audio [bytes] for the next message.
  bool stageAudioAttachment(Uint8List bytes) {
    if (bytes.isEmpty) {
      return false;
    }
    _addStagedPart(LlamaAudioContent(bytes: bytes));
    return true;
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

  /// Starts foreground microphone capture for the active model's voice flow.
  Future<void> startAudioRecording({ChatAudioRecordingPurpose? purpose}) async {
    if (!_audioRecordingService.isSupported) {
      _addInfoMessage('Microphone recording is unavailable on this platform.');
      notifyListeners();
      return;
    }

    final selectedPurpose =
        purpose ??
        (canTranscribeAudio
            ? ChatAudioRecordingPurpose.transcription
            : ChatAudioRecordingPurpose.voiceQuestion);
    final canStartSelectedPurpose = switch (selectedPurpose) {
      ChatAudioRecordingPurpose.transcription => canTranscribeAudio,
      ChatAudioRecordingPurpose.voiceQuestion => canAskWithVoice,
    };
    if (!canStartSelectedPurpose || hasActiveAudioRecording) {
      return;
    }

    final revision = ++_audioRecordingRevision;
    final transitionDone = Completer<void>();
    _activeRecordingTransitionDone = transitionDone;
    _audioRecordingState = ChatAudioRecordingState.starting;
    _audioRecordingElapsed = Duration.zero;
    _audioRecordingPurpose = selectedPurpose;
    _audioRecordingModelPath = _settings.modelPath;
    _audioRecordingMmprojPath = _settings.mmprojPath;
    _audioRecordingConversationId = _activeConversationId;
    notifyListeners();

    try {
      await _audioRecordingService.start();
      if (revision != _audioRecordingRevision || _isDisposed) {
        return;
      }

      _audioRecordingState = ChatAudioRecordingState.recording;
      _startAudioRecordingTimer(revision);
    } catch (error) {
      if (revision != _audioRecordingRevision || _isDisposed) {
        return;
      }
      _addInfoMessage(
        error is AudioRecordingException
            ? error.message
            : 'Could not start microphone recording.',
      );
      _resetAudioRecordingState();
    } finally {
      if (identical(_activeRecordingTransitionDone, transitionDone)) {
        _activeRecordingTransitionDone = null;
      }
      if (!transitionDone.isCompleted) {
        transitionDone.complete();
      }
      if (revision == _audioRecordingRevision &&
          _audioRecordingState == ChatAudioRecordingState.starting) {
        _resetAudioRecordingState();
      }
      if (!_isDisposed) {
        notifyListeners();
      }
    }
  }

  Future<String?> _finishAudioRecording(
    ChatAudioRecordingPurpose purpose,
  ) async {
    if (_audioRecordingState != ChatAudioRecordingState.recording ||
        _audioRecordingPurpose != purpose) {
      return null;
    }

    final revision = _audioRecordingRevision;
    final transitionDone = Completer<void>();
    _activeRecordingTransitionDone = transitionDone;
    _audioRecordingTimer?.cancel();
    _audioRecordingTimer = null;
    _audioRecordingState = ChatAudioRecordingState.stopping;
    notifyListeners();

    String? path;
    try {
      path = await _audioRecordingService.stop();
      if (revision != _audioRecordingRevision || _isDisposed) {
        await _audioRecordingService.deleteRecording(path);
        return null;
      }
    } catch (error) {
      await _audioRecordingService.cancel();
      if (revision == _audioRecordingRevision && !_isDisposed) {
        _addInfoMessage(
          error is AudioRecordingException
              ? error.message
              : 'Could not finish the microphone recording.',
        );
      }
    } finally {
      if (identical(_activeRecordingTransitionDone, transitionDone)) {
        _activeRecordingTransitionDone = null;
      }
      if (!transitionDone.isCompleted) {
        transitionDone.complete();
      }
    }

    if (revision != _audioRecordingRevision || _isDisposed || path == null) {
      if (revision == _audioRecordingRevision) {
        _resetAudioRecordingState();
        if (!_isDisposed) {
          notifyListeners();
        }
      }
      return null;
    }

    final contextMatches =
        _audioRecordingModelPath == _settings.modelPath &&
        _audioRecordingMmprojPath == _settings.mmprojPath &&
        _audioRecordingConversationId == _activeConversationId;
    _resetAudioRecordingState();
    notifyListeners();

    if (!contextMatches) {
      await _audioRecordingService.deleteRecording(path);
      _addInfoMessage(
        'Recording discarded because the active model or conversation changed.',
      );
      notifyListeners();
      return null;
    }

    return path;
  }

  /// Stops microphone capture and runs dedicated whole-file transcription.
  Future<void> stopAudioRecordingAndTranscribe() async {
    final path = await _finishAudioRecording(
      ChatAudioRecordingPurpose.transcription,
    );
    if (path == null) {
      return;
    }

    try {
      await transcribeAudio(
        SpeechAudioFileInput(path),
        displayName: 'Microphone recording',
      );
    } finally {
      await _audioRecordingService.deleteRecording(path);
    }
  }

  /// Stops microphone capture and asks the active audio-chat model to answer.
  Future<void> stopAudioRecordingAndAsk() async {
    final path = await _finishAudioRecording(
      ChatAudioRecordingPurpose.voiceQuestion,
    );
    if (path == null) {
      return;
    }

    final context = _reserveVoiceQuestion();
    if (context == null) {
      await _audioRecordingService.deleteRecording(path);
      if (!_isDisposed) {
        _addInfoMessage(
          'The active model can no longer accept a recorded voice question.',
        );
        notifyListeners();
      }
      return;
    }

    Uint8List? audioBytes;
    try {
      audioBytes = await _audioRecordingService.readRecording(path);
    } catch (error) {
      if (_voiceQuestionContextMatches(context) && !_isDisposed) {
        _addInfoMessage(
          error is AudioRecordingException
              ? error.message
              : 'The microphone recording could not be read.',
        );
      }
    } finally {
      await _audioRecordingService.deleteRecording(path);
    }

    if (audioBytes == null) {
      _releaseVoiceQuestionReservation(context);
      return;
    }
    await _submitVoiceQuestion(audioBytes, context);
  }

  /// Sends encoded [audioBytes] as a spoken question to the active chat model.
  ///
  /// Existing staged composer attachments are intentionally left untouched.
  Future<void> askWithVoice(Uint8List audioBytes) async {
    final context = _reserveVoiceQuestion();
    if (context == null) {
      return;
    }
    await _submitVoiceQuestion(audioBytes, context);
  }

  _VoiceQuestionContext? _reserveVoiceQuestion() {
    if (!canAskWithVoice || _session == null || !_chatService.engine.isReady) {
      return null;
    }
    final operationId = ++_voiceQuestionOperationSequence;
    final context = (
      operationId: operationId,
      conversationRevision: _conversationRevision,
      modelPath: _settings.modelPath,
      mmprojPath: _settings.mmprojPath,
      conversationId: _activeConversationId,
    );
    _activeVoiceQuestionOperationId = operationId;
    _isGenerating = true;
    notifyListeners();
    return context;
  }

  bool _voiceQuestionContextMatches(_VoiceQuestionContext context) =>
      _activeVoiceQuestionOperationId == context.operationId &&
      _isGenerating &&
      context.conversationRevision == _conversationRevision &&
      context.modelPath == _settings.modelPath &&
      context.mmprojPath == _settings.mmprojPath &&
      context.conversationId == _activeConversationId;

  Future<void> _submitVoiceQuestion(
    Uint8List audioBytes,
    _VoiceQuestionContext context,
  ) async {
    _GenerationContext? generationContext;
    var generationStarted = false;
    try {
      if (!_voiceQuestionContextMatches(context)) {
        return;
      }
      if (audioBytes.isEmpty) {
        _addInfoMessage('The microphone recording did not contain any audio.');
        return;
      }

      final audio = LlamaAudioContent(bytes: audioBytes);
      if (!await _ensureMultimodalProjectorForMedia(<LlamaContentPart>[
            audio,
          ]) ||
          !_voiceQuestionContextMatches(context)) {
        return;
      }

      generationContext = _beginGeneration();
      if (generationContext == null) {
        return;
      }

      if (_settings.singleTurnMode) {
        generationContext.session.reset();
      }

      _messages.add(
        ChatMessage(
          text: 'Voice question',
          isUser: true,
          parts: <LlamaContentPart>[
            audio,
            const LlamaTextContent(_voiceQuestionPrompt),
          ],
        ),
      );
      _syncActiveConversationSnapshot();
      notifyListeners();
      await _yieldUiFrame();

      if (!_voiceQuestionContextMatches(context)) {
        return;
      }
      generationStarted = true;
      await _generateResponse(
        _voiceQuestionPrompt,
        context: generationContext,
        parts: <LlamaContentPart>[audio],
      );
    } catch (error) {
      if (_voiceQuestionContextMatches(context) && !_isDisposed) {
        _addInfoMessage('Voice question failed: ${_formatDisplayError(error)}');
      }
    } finally {
      final reservedGeneration = generationContext;
      if (!generationStarted && reservedGeneration != null) {
        _releaseGeneration(reservedGeneration);
      }
      _releaseVoiceQuestionReservation(
        context,
        releaseGeneration: generationContext == null,
      );
    }
  }

  void _releaseVoiceQuestionReservation(
    _VoiceQuestionContext context, {
    bool releaseGeneration = true,
  }) {
    if (_activeVoiceQuestionOperationId != context.operationId) {
      return;
    }
    _activeVoiceQuestionOperationId = null;
    if (releaseGeneration &&
        _activeGenerationOperationId == null &&
        !_isTranscribing) {
      _isGenerating = false;
      _syncActiveConversationSnapshot();
      if (!_isDisposed) {
        notifyListeners();
      }
    }
  }

  void _invalidateActiveVoiceQuestion({bool releaseGeneration = false}) {
    final hadActiveVoiceQuestion = _activeVoiceQuestionOperationId != null;
    _activeVoiceQuestionOperationId = null;
    if (releaseGeneration &&
        hadActiveVoiceQuestion &&
        _activeGenerationOperationId == null &&
        !_isTranscribing) {
      _isGenerating = false;
    }
  }

  /// Discards an active microphone recording without processing it.
  Future<void> cancelAudioRecording({bool showMessage = true}) async {
    await _cancelAndAwaitAudioRecording(showMessage: showMessage);
  }

  void _startAudioRecordingTimer(int revision) {
    _audioRecordingTimer?.cancel();
    _audioRecordingTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (revision != _audioRecordingRevision ||
          _audioRecordingState != ChatAudioRecordingState.recording) {
        _audioRecordingTimer?.cancel();
        _audioRecordingTimer = null;
        return;
      }

      _audioRecordingElapsed = Duration(seconds: timer.tick);
      final purpose = _audioRecordingPurpose;
      final maximumDuration = purpose == ChatAudioRecordingPurpose.voiceQuestion
          ? maxVoiceQuestionRecordingDuration
          : maxAudioRecordingDuration;
      if (_audioRecordingElapsed >= maximumDuration) {
        _audioRecordingElapsed = maximumDuration;
        if (purpose == ChatAudioRecordingPurpose.voiceQuestion) {
          _addInfoMessage('30-second limit reached. Asking the model now.');
          unawaited(stopAudioRecordingAndAsk());
        } else {
          _addInfoMessage(
            'Maximum recording length reached. Transcribing the recording now.',
          );
          unawaited(stopAudioRecordingAndTranscribe());
        }
        return;
      }
      if (!_isDisposed) {
        notifyListeners();
      }
    });
  }

  void _resetAudioRecordingState() {
    _audioRecordingTimer?.cancel();
    _audioRecordingTimer = null;
    _audioRecordingState = ChatAudioRecordingState.idle;
    _audioRecordingElapsed = Duration.zero;
    _audioRecordingPurpose = null;
    _audioRecordingModelPath = null;
    _audioRecordingMmprojPath = null;
    _audioRecordingConversationId = null;
  }

  /// Picks one complete audio file and transcribes it with the loaded model.
  Future<void> pickAudioForTranscription() async {
    if (kIsWeb) {
      _addInfoMessage(
        'Dedicated speech-to-text is not available in the Web chat app yet.',
      );
      notifyListeners();
      return;
    }

    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const <String>['wav', 'mp3', 'flac'],
        allowMultiple: false,
      );
      if (result == null || result.files.isEmpty) {
        return;
      }

      final file = result.files.single;
      final path = file.path;
      if (path != null && path.isNotEmpty) {
        await transcribeAudio(
          SpeechAudioFileInput(path),
          displayName: file.name,
        );
        return;
      }

      final bytes = file.bytes;
      if (bytes != null && bytes.isNotEmpty) {
        await transcribeAudio(
          SpeechAudioBytesInput(bytes),
          displayName: file.name,
        );
        return;
      }

      _addInfoMessage('Could not read the selected audio file.');
      notifyListeners();
    } catch (error) {
      _logDart(
        LlamaLogLevel.warn,
        'Error picking audio for transcription: $error',
      );
      _addInfoMessage('Could not open the selected audio file.');
      notifyListeners();
    }
  }

  /// Transcribes one complete [audio] input and displays the result in chat.
  ///
  /// This is intentionally separate from attaching audio to a generic chat
  /// turn. The current native backend emits only a final transcript.
  Future<void> transcribeAudio(
    SpeechAudioInput audio, {
    String? displayName,
  }) async {
    if (_isGenerating ||
        _isTranscribing ||
        _session == null ||
        !_chatService.engine.isReady) {
      return;
    }
    if (kIsWeb) {
      _addInfoMessage(
        'Dedicated speech-to-text is not available in the Web chat app yet.',
      );
      notifyListeners();
      return;
    }
    if (!_settings.modelSupportsSpeechToText) {
      _addInfoMessage(
        'The selected model is audio-capable but is not declared as a '
        'speech-to-text model.',
      );
      notifyListeners();
      return;
    }

    final conversationRevision = _conversationRevision;
    final operationDone = Completer<void>();
    _activeTranscriptionDone = operationDone;
    _isGenerating = true;
    _isTranscribing = true;
    notifyListeners();

    try {
      final llamaAudio = switch (audio) {
        SpeechAudioFileInput(:final path) => LlamaAudioContent(path: path),
        SpeechAudioBytesInput(:final bytes) => LlamaAudioContent(bytes: bytes),
      };
      if (!await _ensureMultimodalProjectorForMedia(<LlamaContentPart>[
        llamaAudio,
      ])) {
        return;
      }
      if (conversationRevision != _conversationRevision) {
        return;
      }

      if (_settings.singleTurnMode) {
        _session!.reset();
      }

      final sourceLabel = (displayName ?? '').trim().isEmpty
          ? 'selected audio'
          : displayName!.trim();
      _messages.add(
        ChatMessage(text: 'Transcribe audio: $sourceLabel', isUser: true),
      );
      _messages.add(ChatMessage(text: 'Transcribing…', isUser: false));
      _syncActiveConversationSnapshot();
      notifyListeners();
      await _yieldUiFrame();

      final recognizer = SpeechToTextEngine(
        _chatService.engine,
        modelProfile: SpeechToTextModelProfile.qwen3Asr,
      );
      final task = await recognizer.transcribe(
        SpeechToTextRequest(
          audio: audio,
          maxOutputTokens: math.min(1024, math.max(64, _settings.maxTokens)),
        ),
      );
      _activeSpeechToTextTask = task;
      if (!_isGenerating || conversationRevision != _conversationRevision) {
        task.cancel();
      }

      SpeechToTextResult? result;
      await for (final event in task.events) {
        if (event is SpeechToTextFinalEvent) {
          result = event.result;
        }
      }
      final completion = await task.done;

      if (conversationRevision != _conversationRevision) {
        return;
      }

      if (completion.state == SpeechToTextCompletionState.cancelled) {
        _removeEmptyAssistantPlaceholder();
        _addInfoMessage('Transcription cancelled.');
        return;
      }
      if (completion.state == SpeechToTextCompletionState.failed) {
        throw completion.error ?? LlamaSpeechException('Transcription failed.');
      }

      final transcript = (result ?? completion.result)?.text.trim() ?? '';
      if (transcript.isEmpty) {
        throw LlamaSpeechException(
          'The model completed without returning transcript text.',
        );
      }

      int? transcriptTokens;
      try {
        transcriptTokens = await _chatService.engine.getTokenCount(transcript);
      } on LlamaUnsupportedException {
        // Token counting is optional for transcription display.
      } on UnsupportedError {
        // Token counting is optional for transcription display.
      }
      if (conversationRevision != _conversationRevision) {
        return;
      }

      if (_messages.isNotEmpty && !_messages.last.isUser) {
        _messages[_messages.length - 1] = _messages.last.copyWith(
          text: transcript,
          parts: <LlamaContentPart>[LlamaTextContent(transcript)],
          debugBadges: const <String>['Transcription'],
        );
      }
      _session!.addMessage(
        LlamaChatMessage.fromText(
          role: LlamaChatRole.user,
          text: 'Transcribe audio: $sourceLabel',
        ),
      );
      _session!.addMessage(
        LlamaChatMessage.fromText(
          role: LlamaChatRole.assistant,
          text: transcript,
        ),
      );
      if (transcriptTokens != null) {
        _messages.last.tokenCount = transcriptTokens;
        _messages.last.generatedTokenCount = transcriptTokens;
        _currentTokens += transcriptTokens;
      }
    } catch (error) {
      if (conversationRevision != _conversationRevision) {
        return;
      }
      _removeEmptyAssistantPlaceholder();
      _addInfoMessage(
        error is LlamaUnsupportedException
            ? error.message
            : 'Transcription failed: ${_formatDisplayError(error)}',
      );
    } finally {
      _activeSpeechToTextTask = null;
      if (identical(_activeTranscriptionDone, operationDone)) {
        _activeTranscriptionDone = null;
      }
      if (!operationDone.isCompleted) {
        operationDone.complete();
      }
      _isTranscribing = false;
      _isGenerating = false;
      _syncActiveConversationSnapshot();
      if (!_isDisposed) {
        notifyListeners();
      }
    }
  }

  /// Synthesizes [text] with the selected dedicated text-to-speech model.
  ///
  /// The current native runtime reports progress while generating, then makes
  /// one complete PCM buffer available for playback or WAV export.
  Future<bool> synthesizeSpeech(
    String text, {
    String? language,
    SpeechAudioInput? speakerReference,
  }) async {
    final normalizedText = text.trim();
    if (normalizedText.isEmpty || !canSynthesizeSpeech) {
      return false;
    }

    final context = (
      operationId: ++_textToSpeechOperationSequence,
      conversationRevision: _conversationRevision,
      modelPath: _settings.modelPath,
      mmprojPath: _settings.mmprojPath,
      conversationId: _activeConversationId,
    );
    final operationDone = Completer<void>();
    _activeTextToSpeechOperationId = context.operationId;
    _activeTextToSpeechDone = operationDone;
    _isGenerating = true;
    _isSynthesizingSpeech = true;
    _textToSpeechResult = null;
    _textToSpeechProgress = null;
    _textToSpeechError = null;
    notifyListeners();

    TextToSpeechTask? task;
    StreamSubscription<TextToSpeechEvent>? eventSubscription;
    try {
      final synthesizer = TextToSpeechEngine(
        _chatService.engine,
        modelProfile: TextToSpeechModelProfile.qwen3Tts,
      );
      task = await synthesizer.synthesize(
        TextToSpeechRequest(
          text: normalizedText,
          language: (language?.trim().isEmpty ?? true)
              ? null
              : language!.trim(),
          speakerReference: speakerReference,
          maxFrames: _settings.maxTokens.clamp(1, 4096).toInt(),
          topK: _settings.topK.clamp(1, 1000).toInt(),
          topP: _settings.topP.clamp(0.000001, 1).toDouble(),
          minP: _settings.minP.clamp(0, 1).toDouble(),
          temperature: math.max(0, _settings.temperature),
        ),
      );
      if (!_textToSpeechContextMatches(context)) {
        task.cancel();
        await task.done;
        return false;
      }
      _activeTextToSpeechTask = task;
      eventSubscription = task.events.listen(
        (event) {
          if (event is TextToSpeechProgressEvent &&
              identical(_activeTextToSpeechTask, task) &&
              _textToSpeechContextMatches(context)) {
            _textToSpeechProgress = event;
            if (!_isDisposed) {
              notifyListeners();
            }
          }
        },
        onError: (Object _, StackTrace _) {
          // The typed completion below carries the same failure.
        },
      );

      final completion = await task.done;
      if (!_textToSpeechContextMatches(context)) {
        return false;
      }
      switch (completion.state) {
        case TextToSpeechCompletionState.completed:
          final result = completion.result;
          if (result == null || result.samples.isEmpty) {
            throw LlamaTextToSpeechException(
              'The model completed without returning audio samples.',
            );
          }
          _textToSpeechResult = result;
          return true;
        case TextToSpeechCompletionState.cancelled:
          _textToSpeechError = 'Speech synthesis cancelled.';
          return false;
        case TextToSpeechCompletionState.failed:
          throw completion.error ??
              LlamaTextToSpeechException('Speech synthesis failed.');
      }
    } catch (error) {
      if (_textToSpeechContextMatches(context)) {
        _textToSpeechError = error is LlamaUnsupportedException
            ? error.message
            : 'Speech synthesis failed: ${_formatDisplayError(error)}';
      }
      return false;
    } finally {
      await eventSubscription?.cancel();
      if (identical(_activeTextToSpeechTask, task)) {
        _activeTextToSpeechTask = null;
      }
      final ownsActiveDone = identical(_activeTextToSpeechDone, operationDone);
      if (ownsActiveDone) {
        _activeTextToSpeechDone = null;
      }
      if (!operationDone.isCompleted) {
        operationDone.complete();
      }
      if (_activeTextToSpeechOperationId == context.operationId ||
          (_activeTextToSpeechOperationId == null && ownsActiveDone)) {
        _activeTextToSpeechOperationId = null;
        _isSynthesizingSpeech = false;
        if (_activeGenerationOperationId == null &&
            _activeVoiceQuestionOperationId == null &&
            !_isTranscribing) {
          _isGenerating = false;
        }
        if (!_isDisposed) {
          notifyListeners();
        }
      }
    }
  }

  /// Cancels an active text-to-speech task.
  void cancelSpeechSynthesis() {
    _activeTextToSpeechTask?.cancel();
  }

  /// Removes the retained synthesized output from the example UI.
  void clearSynthesizedSpeech() {
    _clearTextToSpeechOutput();
    notifyListeners();
  }

  void _clearTextToSpeechOutput() {
    _textToSpeechResult = null;
    _textToSpeechProgress = null;
    _textToSpeechError = null;
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
      _logDart(LlamaLogLevel.warn, 'Error picking $debugLabel: $error');
    }
  }

  Future<LlamaImageContent?> _prepareImagePartFromPath(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      return await _prepareImagePartFromBytes(bytes);
    } catch (error) {
      _logDart(
        LlamaLogLevel.warn,
        'Error preparing image bytes from path: $error',
      );
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
    if (_isSynthesizingSpeech) {
      cancelSpeechSynthesis();
      notifyListeners();
      return;
    }
    if (_isTranscribing) {
      _invalidateActiveTranscription();
      notifyListeners();
      return;
    }
    if (_isGenerating) {
      final hadActiveGeneration = _activeGenerationOperationId != null;
      _invalidateActiveVoiceQuestion(releaseGeneration: true);
      _invalidateActiveGeneration(cancelNative: true);
      if (hadActiveGeneration) {
        _removeEmptyAssistantPlaceholder();
        _restoreSessionFromMessages();
      }
      notifyListeners();
    }
  }

  void _updateSettings(ChatSettings newSettings) {
    final declarationsChanged =
        _settings.toolDeclarations != newSettings.toolDeclarations;
    final modelContextChanged =
        _settings.modelPath != newSettings.modelPath ||
        _settings.mmprojPath != newSettings.mmprojPath ||
        _settings.directMediaInput != newSettings.directMediaInput ||
        _settings.modelSupportsAudio != newSettings.modelSupportsAudio ||
        _settings.modelSupportsSpeechToText !=
            newSettings.modelSupportsSpeechToText ||
        _settings.modelSupportsTextToSpeech !=
            newSettings.modelSupportsTextToSpeech;
    final hadActiveGeneration = _activeGenerationOperationId != null;
    if (modelContextChanged) {
      _invalidateActiveTextToSpeech(clearOutput: true);
      _invalidateActiveVoiceQuestion(releaseGeneration: true);
      _invalidateActiveGeneration(cancelNative: true);
    }
    _settings = newSettings;
    if (modelContextChanged && hadActiveGeneration) {
      _removeEmptyAssistantPlaceholder();
      _restoreSessionFromMessages();
    }
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
    _updateSettings(
      _settings.copyWith(
        contextSize: effectiveContextSize,
        autoTuneRequestedContextSize: effectiveContextSize,
      ),
    );
  }

  void updateMaxTokens(int value) =>
      _updateSettings(_settings.copyWith(maxTokens: value.clamp(512, 32768)));
  void updateGpuLayers(int value) {
    final normalized = value >= 99 ? 99 : value.clamp(0, 98);
    _updateSettings(
      _settings.copyWith(
        gpuLayers: normalized,
        autoTuneModelParams:
            _settings.preferredBackend == GpuBackend.auto && normalized >= 99,
        autoTuneRequestedContextSize: normalized >= 99
            ? _settings.autoTuneRequestedContextSize ?? _settings.contextSize
            : _settings.autoTuneRequestedContextSize,
      ),
    );
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
    if (value && !_templateSupportsTools) {
      _addInfoMessage(
        'Tool calling is unavailable for this loaded runtime/template.',
      );
      notifyListeners();
      return;
    }
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
    if (value && !_thinkingControlsSupported) {
      _addInfoMessage(
        'Thinking controls are unavailable for this loaded runtime.',
      );
      notifyListeners();
      return;
    }
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
    await _cancelAndAwaitAudioRecording();
    await _cancelAndAwaitActiveTranscription();
    await _cancelAndAwaitActiveTextToSpeech();
    _clearTextToSpeechOutput();
    stopGeneration();
    _cancelActiveModelPrefetch();
    _session?.reset();
    _session = null;
    await _chatService.unloadModel();

    _isInitializing = false;
    _loadingProgress = 0.0;
    _error = null;
    _clearLoadedRuntimeState(activeBackend: 'Unloaded', contextLimit: 0);
    _syncActiveConversationSnapshot(touchUpdatedAt: false);
    notifyListeners();
  }

  void updateModelPath(String path) {
    unawaited(_cancelAndAwaitAudioRecording());
    _updateSettings(
      _settings.copyWith(
        modelPath: path,
        modelSupportsVision: false,
        modelSupportsAudio: false,
        modelSupportsSpeechToText: false,
        modelSupportsTextToSpeech: false,
        directMediaInput: false,
      ),
    );
  }

  /// Apply model-specific recommended generation and runtime parameters.
  void applyModelPreset(DownloadableModel model) {
    unawaited(_cancelAndAwaitAudioRecording());
    final shouldKeepToolsEnabled =
        model.supportsToolCalling && _settings.toolsEnabled;
    final shouldUseReducedAndroidContext =
        !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.android &&
        model.name == 'Qwen3.5 0.8B Instruct';
    final shouldPreferCpuOnAndroid =
        !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.android &&
        model.name == 'Qwen3.5 0.8B Instruct' &&
        (_settings.preferredBackend == GpuBackend.auto ||
            _settings.preferredBackend == GpuBackend.vulkan ||
            _settings.preferredBackend == GpuBackend.cpu);
    final mediaInputMode = model.mediaInputModeFor(web: kIsWeb);

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
        autoTuneModelParams:
            !shouldPreferCpuOnAndroid &&
            _settings.preferredBackend == GpuBackend.auto &&
            model.preset.gpuLayers >= 99,
        autoTuneRequestedContextSize: shouldUseReducedAndroidContext
            ? 2048
            : model.preset.contextSize,
        preferredBackend: shouldPreferCpuOnAndroid
            ? GpuBackend.cpu
            : _settings.preferredBackend,
        toolsEnabled: shouldKeepToolsEnabled,
        thinkingEnabled: model.preset.thinkingEnabled,
        thinkingBudgetTokens: model.preset.thinkingBudgetTokens,
        singleTurnMode: false,
        modelSupportsVision: model.supportsVisionFor(web: kIsWeb),
        modelSupportsAudio: model.supportsAudioFor(web: kIsWeb),
        modelSupportsSpeechToText: model.supportsSpeechToTextFor(web: kIsWeb),
        modelSupportsTextToSpeech: model.supportsTextToSpeechFor(web: kIsWeb),
        directMediaInput: mediaInputMode == ModelMediaInputMode.direct,
        // Auto uses the size for native memory planning; WebGPU also uses it
        // to select the mem64 core before loading large models.
        modelBytesHint: model.sizeBytesFor(web: kIsWeb),
      ),
    );

    if (shouldPreferCpuOnAndroid) {
      _addInfoMessage(
        'On Android, Qwen3.5 0.8B currently runs faster and more reliably in CPU mode than Vulkan. You can switch back manually in Inference settings if you want to compare.',
      );
      notifyListeners();
    }
  }

  bool _isSingleTurnTextOnlyRuntime(Map<String, String> metadata) {
    final structuredChat = metadata['llamadart.litert_lm_web.structured_chat']
        ?.trim()
        .toLowerCase();
    final chatScope = metadata['llamadart.litert_lm_web.chat_scope']
        ?.trim()
        .toLowerCase();
    return structuredChat == 'false' || chatScope == 'single-turn-text';
  }

  void _updateThinkingControlSupport(Map<String, String> metadata) {
    _thinkingControlsSupported = !_isSingleTurnTextOnlyRuntime(metadata);
    if (_thinkingControlsSupported || !_settings.thinkingEnabled) {
      return;
    }

    _settings = _settings.copyWith(thinkingEnabled: false);
    unawaited(_saveSettingsNow());
    _addInfoMessage(
      'Thinking controls disabled for this runtime: LiteRT-LM Web currently exposes single-turn text generation only.',
    );
  }

  void _updateToolTemplateSupport(Map<String, String> metadata) {
    if (_isSingleTurnTextOnlyRuntime(metadata)) {
      _detectedChatFormat = ChatFormat.contentOnly;
      _templateSupportsTools = false;
      if (_settings.toolsEnabled) {
        _settings = _settings.copyWith(toolsEnabled: false);
        unawaited(_saveSettingsNow());
      }
      _addInfoMessage(
        'Tool calling disabled for this runtime: LiteRT-LM Web currently exposes single-turn text generation only. Use GGUF/WebGPU or a native LiteRT-LM target for structured tool calls.',
      );
      return;
    }

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
    unawaited(_cancelAndAwaitAudioRecording());
    _updateSettings(_settings.copyWith(mmprojPath: path));
  }

  Future<bool> loadConfiguredMmproj({
    String successMessage = 'Multimodal projector loaded.',
  }) async {
    await _cancelAndAwaitAudioRecording();
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
    await _cancelAndAwaitAudioRecording();
    if ((_settings.mmprojPath ?? '').isEmpty && !_mmprojLoaded) {
      return;
    }

    if (_mmprojLoaded) {
      try {
        await _chatService.unloadMultimodalProjector();
      } catch (error) {
        _logDart(LlamaLogLevel.warn, 'Failed to unload active mmproj: $error');
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
    final restoresGpuOffload =
        backend != GpuBackend.cpu && _settings.gpuLayers == 0;
    _updateSettings(
      _settings.copyWith(
        preferredBackend: backend,
        gpuLayers: restoresGpuOffload ? 99 : _settings.gpuLayers,
        autoTuneModelParams:
            backend == GpuBackend.auto &&
            (restoresGpuOffload || _settings.autoTuneModelParams),
        autoTuneRequestedContextSize: backend == GpuBackend.auto
            ? _settings.autoTuneRequestedContextSize ?? _settings.contextSize
            : _settings.autoTuneRequestedContextSize,
      ),
    );
    _messages.add(
      ChatMessage(
        text: restoresGpuOffload
            ? 'Backend preference set to ${backend.name}. GPU offload restored to Max; reload model to apply.'
            : 'Backend preference set to ${backend.name}. Reload model to apply.',
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
    _isDisposed = true;
    _settingsSaveDebounce?.cancel();
    _settingsSaveDebounce = null;
    unawaited(_settingsService.saveSettings(_settings));
    final recordingDone = _cancelAndAwaitAudioRecording();
    final transcriptionDone = _cancelAndAwaitActiveTranscription();
    final textToSpeechDone = _cancelAndAwaitActiveTextToSpeech();
    stopGeneration();
    _cancelActiveModelPrefetch();
    _session?.reset();
    _session = null;
    unawaited(() async {
      await recordingDone;
      await transcriptionDone;
      await textToSpeechDone;
      await _audioRecordingService.dispose();
      await _chatService.dispose();
    }());
    super.dispose();
  }

  Future<void> shutdown() async {
    if (_isShuttingDown) {
      return;
    }

    _isShuttingDown = true;
    try {
      await _saveSettingsNow();
      await _cancelAndAwaitAudioRecording();
      await _cancelAndAwaitActiveTranscription();
      await _cancelAndAwaitActiveTextToSpeech();
      stopGeneration();
      _cancelActiveModelPrefetch();
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
      await _audioRecordingService.dispose();
      await _chatService.dispose();
    } finally {
      _isShuttingDown = false;
    }
  }

  void _invalidateActiveTranscription() {
    _conversationRevision += 1;
    _activeSpeechToTextTask?.cancel();
  }

  Future<void> _cancelAndAwaitActiveTranscription() async {
    final task = _activeSpeechToTextTask;
    final done = _activeTranscriptionDone;
    if (!_isTranscribing && task == null && done == null) {
      return;
    }
    _conversationRevision += 1;
    task?.cancel();
    if (task != null) {
      await task.done;
    }
    if (done != null) {
      await done.future;
    }
  }

  Future<void> _cancelAndAwaitActiveTextToSpeech() async {
    final task = _activeTextToSpeechTask;
    final done = _activeTextToSpeechDone;
    if (!_isSynthesizingSpeech && task == null && done == null) {
      return;
    }
    task?.cancel();
    if (task != null) {
      await task.done;
    }
    if (done != null) {
      await done.future;
    }
  }

  bool _textToSpeechContextMatches(_TextToSpeechContext context) =>
      _activeTextToSpeechOperationId == context.operationId &&
      _isSynthesizingSpeech &&
      context.conversationRevision == _conversationRevision &&
      context.modelPath == _settings.modelPath &&
      context.mmprojPath == _settings.mmprojPath &&
      context.conversationId == _activeConversationId;

  void _invalidateActiveTextToSpeech({bool clearOutput = false}) {
    _activeTextToSpeechOperationId = null;
    _activeTextToSpeechTask?.cancel();
    if (clearOutput) {
      _clearTextToSpeechOutput();
    }
  }

  Future<void> _cancelAndAwaitAudioRecording({bool showMessage = false}) async {
    final activeCancellation = _activeRecordingCancellationDone;
    if (activeCancellation != null) {
      await activeCancellation.future;
      return;
    }

    final transition = _activeRecordingTransitionDone;
    if (_audioRecordingState == ChatAudioRecordingState.idle &&
        transition == null) {
      return;
    }

    final cancellationDone = Completer<void>();
    _activeRecordingCancellationDone = cancellationDone;
    final conversationRevision = _conversationRevision;
    final revision = ++_audioRecordingRevision;
    _audioRecordingTimer?.cancel();
    _audioRecordingTimer = null;
    _audioRecordingState = ChatAudioRecordingState.cancelling;
    if (!_isDisposed) {
      notifyListeners();
    }

    try {
      if (transition != null) {
        await transition.future;
      }
      await _audioRecordingService.cancel();
    } finally {
      if (revision == _audioRecordingRevision) {
        _resetAudioRecordingState();
        if (showMessage &&
            !_isDisposed &&
            conversationRevision == _conversationRevision) {
          _addInfoMessage('Microphone recording cancelled.');
        }
      }
      if (identical(_activeRecordingCancellationDone, cancellationDone)) {
        _activeRecordingCancellationDone = null;
      }
      if (!cancellationDone.isCompleted) {
        cancellationDone.complete();
      }
      if (!_isDisposed) {
        notifyListeners();
      }
    }
  }

  Future<void> estimateDynamicSettings() async {
    try {
      final vram = await _chatService.engine.getVramInfo();
      final backendInfo = await _getAvailableBackendInfoBestEffort();
      final catalogModel = _downloadableModelForCurrentSettings();
      final modelBytes =
          _settings.modelBytesHint ??
          catalogModel?.sizeBytesFor(web: kIsWeb) ??
          0;
      final estimate = _runtimeProfileService.estimateDynamicSettings(
        totalVramBytes: vram.total,
        freeVramBytes: vram.free,
        isWeb: kIsWeb,
        preferredBackend: _settings.preferredBackend,
        currentContextSize:
            _settings.autoTuneRequestedContextSize ?? _settings.contextSize,
        modelBytes: modelBytes,
        backendInfo: backendInfo,
      );

      _updateSettings(
        _settings.copyWith(
          gpuLayers: estimate.gpuLayers,
          contextSize: estimate.contextSize,
        ),
      );
    } catch (e) {
      _logDart(LlamaLogLevel.warn, "Error estimating dynamic settings: $e");
    }
  }
}
