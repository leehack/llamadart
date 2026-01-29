import 'package:flutter/foundation.dart';
import 'dart:io'
    if (dart.library.js_interop) '../stub/io_stub.dart'; // Stub for web
import 'package:flutter/services.dart';
import 'package:llamadart/llamadart.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_picker/file_picker.dart';

class ChatMessage {
  final String text;
  final bool isUser;
  final DateTime timestamp;

  ChatMessage({
    required this.text,
    required this.isUser,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();
}

class ChatProvider extends ChangeNotifier {
  final LlamaService _service = LlamaService();

  final List<ChatMessage> _messages = [];
  String? _modelPath;
  GpuBackend _preferredBackend = GpuBackend.auto;
  String _activeBackend = "Unknown";
  bool _gpuSupported = false;
  bool _isInitializing = false;
  bool _isLoaded = false;
  bool _needsReload = false;
  bool _isGenerating = false;
  String? _error;

  // Advanced settings
  double _temperature = 0.7;
  int _topK = 40;
  double _topP = 0.9;
  int _contextSize = 0; // 0 = Auto

  // Telemetry
  int _maxTokens = 2048;
  int _currentTokens = 0;
  bool _isPruning = false;

  // Metadata based stops
  List<String> _autoStopSequences = [];

  List<ChatMessage> get messages => List.unmodifiable(_messages);
  String? get modelPath => _modelPath;
  GpuBackend get preferredBackend => _preferredBackend;
  String get activeBackend => _activeBackend;
  bool get gpuSupported => _gpuSupported;
  bool get isInitializing => _isInitializing;
  bool get isLoaded => _isLoaded;
  bool get isGenerating => _isGenerating;
  String? get error => _error;

  double get temperature => _temperature;
  int get topK => _topK;
  double get topP => _topP;
  int get contextSize => _contextSize;
  int get maxTokens => _maxTokens;
  int get currentTokens => _currentTokens;
  bool get isPruning => _isPruning;

  bool get isReady =>
      _error == null && !_isInitializing && _isLoaded; // simplified ready state

  ChatProvider() {
    _loadSettings();
  }

  List<String> _availableDevices = [];
  List<String> get availableDevices => _availableDevices;

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _modelPath = prefs.getString('model_path');
    _preferredBackend =
        GpuBackend.values[prefs.getInt('preferred_backend') ?? 0];
    _temperature = prefs.getDouble('temperature') ?? 0.7;
    _topK = prefs.getInt('top_k') ?? 40;
    _topP = prefs.getDouble('top_p') ?? 0.9;
    _contextSize = prefs.getInt('context_size') ?? 0;

    // Fetch available devices
    try {
      _availableDevices = await LlamaService.getAvailableDevices();
    } catch (e) {
      debugPrint("Error fetching devices: $e");
    }

    notifyListeners();
  }

  Future<void> loadModel() async {
    if (_isInitializing) {
      _needsReload = true;
      return;
    }
    if (_modelPath == null || _modelPath!.isEmpty) {
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
      debugPrint('Loading model from $_modelPath...');

      // If it's a URL, use initFromUrl
      if (_modelPath!.startsWith('http')) {
        await _service.initFromUrl(_modelPath!);
      } else {
        // On Web, validation of file existence is different/skipped
        if (!kIsWeb) {
          final file = File(_modelPath!);
          if (!file.existsSync()) {
            _error =
                'Model file not found at local path. Please check settings.';
            notifyListeners();
            _isInitializing = false;
            return;
          }
        }
        await _service.init(_modelPath!,
            modelParams: ModelParams(
              gpuLayers: 99,
              preferredBackend: _preferredBackend,
              contextSize: _contextSize,
            ));
      }

      // Fetch active backend info
      final rawBackend = await _service.getBackendName();
      if (_preferredBackend == GpuBackend.cpu) {
        _activeBackend = "CPU";
      } else if (_preferredBackend == GpuBackend.blas) {
        _activeBackend = "CPU (BLAS)";
      } else {
        _activeBackend = rawBackend;
      }
      _maxTokens = await _service.getContextSize();
      debugPrint("Active Backend: $_activeBackend");
      debugPrint("Resolved Context Size: $_maxTokens");

      // Auto-detect stop sequences from metadata
      final metadata = await _service.getAllMetadata();
      _autoStopSequences = _detectStopSequences(metadata);
      debugPrint("Auto-detected stop sequences: $_autoStopSequences");
      final libSupported = await _service.isGpuSupported();

      // If library supports GPU, or we explicitly found GPU devices (excluding CPU)
      _gpuSupported = libSupported ||
          _availableDevices.any((d) =>
              !d.toLowerCase().contains("cpu") &&
              !d.toLowerCase().contains("llvm"));

      debugPrint(
          "GPU Support Check: Lib=$libSupported, Devices=$_availableDevices, Result=$_gpuSupported");

      _messages.add(ChatMessage(
        text: 'Model loaded successfully! Ready to chat.',
        isUser: false,
      ));
      _isLoaded = true;
    } catch (e, stackTrace) {
      debugPrint('Error loading model: $e');
      debugPrint(stackTrace.toString());
      _error = e.toString();
    } finally {
      _isInitializing = false;
      notifyListeners();

      if (_needsReload) {
        _needsReload = false;
        loadModel(); // Queue next load
      }
    }
  }

  void clearConversation() {
    _messages.clear();
    _currentTokens = 0;
    _isPruning = false;
    _isGenerating = false;
    _messages.add(ChatMessage(
      text: 'Conversation cleared. Ready for a new topic!',
      isUser: false,
    ));
    notifyListeners();
  }

  Future<String> _buildConversationPrompt(String newMessage) async {
    final lowerPath = _modelPath?.toLowerCase() ?? "";
    final isGemma = lowerPath.contains('gemma');
    final assistantRole = isGemma ? 'model' : 'assistant';

    // 1. Filter out UI placeholders
    final conversationMessages = _messages
        .where((m) =>
            m.text != 'Model loaded successfully! Ready to chat.' &&
            m.text != '...')
        .toList();

    // 2. Tokenize and implement sliding window
    final List<LlamaChatMessage> finalMessages = [];
    int totalTokens = 0;
    const safetyMargin =
        1024; // Larger room for long generations + template overhead

    // We iterate through all current messages to implement sliding window.
    // Note: newMessage is already in conversationMessages because it was added to _messages before calling this.

    bool pruningHappened = false;
    for (int i = conversationMessages.length - 1; i >= 0; i--) {
      final m = conversationMessages[i];
      final tokens = await _service.getTokenCount(m.text);

      if (totalTokens + tokens > (_maxTokens - safetyMargin)) {
        pruningHappened = true;
        continue;
      }

      totalTokens += tokens;
      finalMessages.insert(
        0,
        LlamaChatMessage(
          role: m.isUser ? 'user' : assistantRole,
          content: m.text,
        ),
      );
    }

    _isPruning = pruningHappened;
    _currentTokens = totalTokens;
    notifyListeners();

    return await _service.applyChatTemplate(finalMessages);
  }

  Future<void> sendMessage(String text) async {
    if (_isGenerating) return;

    _messages.add(ChatMessage(text: text, isUser: true));
    notifyListeners();

    _isGenerating = true;
    notifyListeners();

    try {
      final prompt = await _buildConversationPrompt(text);

      // Create a placeholder message for the AI response
      final responseMessageIndex = _messages.length;
      String fullResponse = "";
      _messages.add(ChatMessage(text: "...", isUser: false));
      notifyListeners();

      DateTime lastUpdate = DateTime.now();
      await for (final token in _service.generate(
        prompt,
        params: GenerationParams(
          temp: _temperature,
          topK: _topK,
          topP: _topP,
          penalty: 1.1,
          stopSequences: [
            ..._autoStopSequences,
            '<|user|>',
            '<|im_end|>',
            '<|im_start|>',
            '<|end_of_turn|>',
            '### Instruction:',
          ],
        ),
      )) {
        if (!_isGenerating) break;
        fullResponse += token;

        // Basic cleanup
        var cleanText = fullResponse;

        // Remove common prompt/response markers
        final markersToRemove = [
          "<|im_end|>",
          "<|im_start|>",
          "<|end_of_turn|>",
          "<start_of_turn>",
          "<|eot_id|>",
          "<|start_header_id|>",
          "<|end_header_id|>",
          "<|user|>",
          "<|assistant|>",
          "</s>",
          "<s>",
        ];

        for (final marker in markersToRemove) {
          cleanText = cleanText.replaceAll(marker, "");
        }

        // Remove role headers that models sometimes leak
        cleanText = cleanText.replaceFirst(
            RegExp(
                r'^(?:[\|\><\s]*)?(model|assistant|user|system|thought)[:\n\s]*',
                caseSensitive: false),
            "");

        // Strip any stop sequences if they appear at the very end
        for (final stop in [
          '<|user|>',
          '<|im_end|>',
          '<|im_start|>',
          '<|end_of_turn|>',
          '### Instruction:',
        ]) {
          if (cleanText.endsWith(stop)) {
            cleanText = cleanText.substring(0, cleanText.length - stop.length);
          }
        }

        // Final cleanup of common hallucinated headers mid-generation
        cleanText = cleanText.replaceAll(
            RegExp(r'\n(?:[\|\><\s]*)?(model|assistant|user|system|thought):',
                caseSensitive: false),
            "\n");

        cleanText = cleanText.replaceFirst(
            RegExp(r'(?:\<|\||\>|im_|end_|start_)+$'), "");

        // Update the last message
        if (_messages.length > responseMessageIndex) {
          _messages[responseMessageIndex] = ChatMessage(
            text: cleanText.trim(),
            isUser: false,
            timestamp: _messages[responseMessageIndex].timestamp,
          );

          // Throttle updates to UI (max 20fps for text streaming)
          if (DateTime.now().difference(lastUpdate).inMilliseconds > 50) {
            notifyListeners();
            lastUpdate = DateTime.now();
          }
        }
      }
    } catch (e) {
      _messages.add(ChatMessage(
        text: 'Error: $e',
        isUser: false,
      ));
    } finally {
      _isGenerating = false;
      notifyListeners();
    }
  }

  void stopGeneration() {
    if (_isGenerating) {
      _service.cancelGeneration();
      _isGenerating = false;
      notifyListeners();
    }
  }

  void updateModelPath(String path) {
    _modelPath = path;
    _saveSettings();
  }

  Future<void> updatePreferredBackend(GpuBackend backend) async {
    _preferredBackend = backend;
    notifyListeners();
    await _saveSettings();
    _messages.add(ChatMessage(
      text: 'Switching backend to ${backend.name}...',
      isUser: false,
    ));
    notifyListeners(); // Second notify for the message and starting loadModel
    await loadModel();
  }

  void updateTemperature(double value) {
    _temperature = value;
    _saveSettings();
    notifyListeners();
  }

  void updateTopK(int value) {
    _topK = value;
    _saveSettings();
    notifyListeners();
  }

  void updateTopP(double value) {
    _topP = value;
    _saveSettings();
    notifyListeners();
  }

  void updateContextSize(int value) {
    _contextSize = value;
    _saveSettings();
    notifyListeners();
  }

  Future<void> selectModelFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: false,
        type: FileType.any, // Allow any for now to avoid extension issues
      );

      if (result == null || result.files.isEmpty) return;

      final selectedPath = result.files.single.path;
      if (selectedPath == null) throw Exception('No file path');

      _modelPath = selectedPath;
      _error = null;
      await _saveSettings();
      notifyListeners();

      await loadModel();
    } catch (e) {
      if (e is PlatformException) {
        throw PlatformException(
            code: e.code, message: e.message, details: e.details);
      } else {
        throw Exception('Error selecting model file: $e');
      }
    }
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (_modelPath != null) {
      await prefs.setString('model_path', _modelPath!);
    }
    await prefs.setInt('preferred_backend', _preferredBackend.index);
    await prefs.setDouble('temperature', _temperature);
    await prefs.setInt('top_k', _topK);
    await prefs.setDouble('top_p', _topP);
    await prefs.setInt('context_size', _contextSize);
  }

  List<String> _detectStopSequences(Map<String, String> metadata) {
    final stops = <String>[];
    // Check common metadata keys
    final template = metadata['tokenizer.chat_template']?.toLowerCase() ?? "";

    if (template.contains('im_end')) stops.add('<|im_end|>');
    if (template.contains('end_of_turn')) stops.add('<end_of_turn>');
    if (template.contains('eot_id')) stops.add('<|eot_id|>');
    if (template.contains('assistant')) stops.add('<|assistant|>');

    // Check arch specific stops
    final arch = metadata['general.architecture']?.toLowerCase() ?? "";
    if (arch.contains('llama')) {
      stops.add('</s>');
      stops.add('<|eot_id|>');
    }
    if (arch.contains('gemma')) {
      stops.add('<end_of_turn>');
    }

    return stops.toSet().toList(); // Unique ones
  }

  @override
  void dispose() {
    _service.dispose();
    super.dispose();
  }
}
