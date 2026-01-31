import 'package:flutter/foundation.dart';
import 'package:llamadart/llamadart.dart';
import 'package:file_picker/file_picker.dart';

import '../models/chat_message.dart';
import '../models/chat_settings.dart';
import '../services/chat_service.dart';
import '../services/settings_service.dart';

class ChatProvider extends ChangeNotifier {
  final ChatService _chatService = ChatService();
  final SettingsService _settingsService = SettingsService();

  final List<ChatMessage> _messages = [];
  ChatSettings _settings = const ChatSettings();

  String _activeBackend = "Unknown";
  bool _gpuSupported = false;
  bool _isInitializing = false;
  bool _isLoaded = false;
  bool _isGenerating = false;
  String? _error;

  // Telemetry
  int _maxTokens = 2048;
  int _currentTokens = 0;
  bool _isPruning = false;

  List<String> _autoStopSequences = [];
  List<String> _availableDevices = [];

  // Getters
  List<ChatMessage> get messages => List.unmodifiable(_messages);
  ChatSettings get settings => _settings;
  String? get modelPath => _settings.modelPath;
  GpuBackend get preferredBackend => _settings.preferredBackend;
  String get activeBackend => _activeBackend;
  bool get gpuSupported => _gpuSupported;
  bool get isInitializing => _isInitializing;
  bool get isLoaded => _isLoaded;
  bool get isGenerating => _isGenerating;
  String? get error => _error;
  double get temperature => _settings.temperature;
  int get topK => _settings.topK;
  double get topP => _settings.topP;
  int get contextSize => _settings.contextSize;
  int get maxTokens => _maxTokens;
  int get currentTokens => _currentTokens;
  bool get isPruning => _isPruning;
  List<String> get availableDevices => _availableDevices;

  bool get isReady => _error == null && !_isInitializing && _isLoaded;

  ChatProvider() {
    _init();
  }

  Future<void> _init() async {
    _settings = await _settingsService.loadSettings();
    try {
      _availableDevices = await LlamaService.getAvailableDevices();
    } catch (e) {
      debugPrint("Error fetching devices: $e");
    }
    notifyListeners();
  }

  Future<void> loadModel() async {
    if (_isInitializing) return;
    if (_settings.modelPath == null || _settings.modelPath!.isEmpty) {
      _error = 'Model path not set. Please configure in settings.';
      notifyListeners();
      return;
    }

    _isInitializing = true;
    _isLoaded = false;
    _error = null;
    _activeBackend = "Refreshing...";
    notifyListeners();

    try {
      await _chatService.init(_settings);

      final rawBackend = await _chatService.llama.getBackendName();
      _activeBackend = _settings.preferredBackend == GpuBackend.cpu
          ? "CPU"
          : (_settings.preferredBackend == GpuBackend.blas
                ? "CPU (BLAS)"
                : rawBackend);

      _maxTokens = await _chatService.llama.getContextSize();

      final metadata = await _chatService.llama.getAllMetadata();
      _autoStopSequences = _chatService.detectStopSequences(metadata);

      final libSupported = await _chatService.llama.isGpuSupported();

      _gpuSupported =
          libSupported ||
          _availableDevices.any(
            (d) =>
                !d.toLowerCase().contains("cpu") &&
                !d.toLowerCase().contains("llvm"),
          );

      _messages.add(
        ChatMessage(
          text: 'Model loaded successfully! Ready to chat.',
          isUser: false,
        ),
      );
      _isLoaded = true;
    } catch (e, stackTrace) {
      debugPrint('Error loading model: $e');
      debugPrint(stackTrace.toString());
      _error = e.toString();
    } finally {
      _isInitializing = false;
      notifyListeners();
    }
  }

  void clearConversation() {
    _messages.clear();
    _currentTokens = 0;
    _isPruning = false;
    _isGenerating = false;
    _messages.add(
      ChatMessage(
        text: 'Conversation cleared. Ready for a new topic!',
        isUser: false,
      ),
    );
    notifyListeners();
  }

  Future<void> sendMessage(String text) async {
    if (_isGenerating) return;

    final userMsg = ChatMessage(text: text, isUser: true);
    _messages.add(userMsg);
    _isGenerating = true;
    notifyListeners();

    try {
      final prompt = await _chatService.buildPrompt(
        _messages,
        _settings.modelPath!,
        _maxTokens,
      );

      final responseMessageIndex = _messages.length;
      _messages.add(ChatMessage(text: "...", isUser: false));
      notifyListeners();

      String fullResponse = "";
      DateTime lastUpdate = DateTime.now();

      await for (final token in _chatService.generate(
        prompt,
        _settings,
        _autoStopSequences,
      )) {
        if (!_isGenerating) break;
        fullResponse += token;

        final cleanText = _chatService.cleanResponse(fullResponse);

        if (_messages.length > responseMessageIndex) {
          _messages[responseMessageIndex] = _messages[responseMessageIndex]
              .copyWith(text: cleanText);

          // UI Throttling: only notify listeners if 50ms have passed since last update
          if (DateTime.now().difference(lastUpdate).inMilliseconds > 50) {
            notifyListeners();
            lastUpdate = DateTime.now();
          }
        }
      }

      // Final update to ensure UI is in sync and token counts are refreshed for next turn
      if (_messages.length > responseMessageIndex) {
        _messages[responseMessageIndex].tokenCount = await _chatService.llama
            .getTokenCount(_messages[responseMessageIndex].text);
      }
    } catch (e) {
      _messages.add(ChatMessage(text: 'Error: $e', isUser: false));
    } finally {
      _isGenerating = false;
      notifyListeners();
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
    _settings = newSettings;
    _settingsService.saveSettings(_settings);
    notifyListeners();
  }

  void updateTemperature(double value) =>
      _updateSettings(_settings.copyWith(temperature: value));
  void updateTopK(int value) =>
      _updateSettings(_settings.copyWith(topK: value));
  void updateTopP(double value) =>
      _updateSettings(_settings.copyWith(topP: value));
  void updateContextSize(int value) =>
      _updateSettings(_settings.copyWith(contextSize: value));
  void updateLogLevel(LlamaLogLevel value) =>
      _updateSettings(_settings.copyWith(logLevel: value));

  void updateModelPath(String path) {
    _settings = _settings.copyWith(modelPath: path);
    _settingsService.saveSettings(_settings);
    notifyListeners();
  }

  Future<void> updatePreferredBackend(GpuBackend backend) async {
    _settings = _settings.copyWith(preferredBackend: backend);
    await _settingsService.saveSettings(_settings);
    _messages.add(
      ChatMessage(
        text: 'Switching backend to ${backend.name}...',
        isUser: false,
      ),
    );
    notifyListeners();
    await loadModel();
  }

  Future<void> selectModelFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: false,
        type: FileType.any,
      );
      if (result == null || result.files.isEmpty) return;

      final selectedPath = result.files.single.path;
      if (selectedPath == null) throw Exception('No file path');

      _settings = _settings.copyWith(modelPath: selectedPath);
      _error = null;
      await _settingsService.saveSettings(_settings);
      notifyListeners();
      await loadModel();
    } catch (e) {
      rethrow;
    }
  }

  @override
  void dispose() {
    _chatService.dispose();
    super.dispose();
  }

  Future<void> shutdown() async {
    await _chatService.dispose();
  }
}
