import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:llamadart/llamadart.dart';

class GgufModelOption {
  const GgufModelOption({
    required this.id,
    required this.label,
    required this.url,
    required this.sizeLabel,
    required this.sizeBytes,
    required this.contextSize,
    required this.note,
    this.warning,
  });

  final String id;
  final String label;
  final String url;
  final String sizeLabel;
  final int sizeBytes;
  final int contextSize;
  final String note;
  final String? warning;
}

const smolLmModelUrl =
    'https://huggingface.co/unsloth/SmolLM2-135M-Instruct-GGUF/resolve/'
    '9e6855bc4be717fca1ef21360a1db4b29d5c559a/'
    'SmolLM2-135M-Instruct-Q4_K_M.gguf';

const ggufModels = <GgufModelOption>[
  GgufModelOption(
    id: 'smollm2-135m',
    label: 'SmolLM2 135M',
    url: smolLmModelUrl,
    sizeLabel: '~105 MB',
    sizeBytes: 105454144,
    contextSize: 2048,
    note: 'Fastest download; good for quick tests.',
  ),
  GgufModelOption(
    id: 'qwen3.5-0.8b',
    label: 'Qwen3.5 0.8B',
    url:
        'https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/resolve/'
        '6ab461498e2023f6e3c1baea90a8f0fe38ab64d0/'
        'Qwen3.5-0.8B-Q4_K_M.gguf',
    sizeLabel: '~533 MB',
    sizeBytes: 532517120,
    contextSize: 2048,
    note: 'Stronger responses; thinking disabled for quick replies.',
  ),
  GgufModelOption(
    id: 'gemma-4-e2b',
    label: 'Gemma 4 E2B',
    url:
        'https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/'
        '0314792d7f1f7e229411f620751375812bb9faf2/'
        'gemma-4-E2B-it-Q4_K_S.gguf',
    sizeLabel: 'desktop Chrome, ~3 GB',
    sizeBytes: 3043934304,
    contextSize: 2048,
    note: 'Higher quality; thinking disabled for quick replies.',
    warning:
        'Large download (~3 GB). Requires desktop Chrome with WebAssembly '
        'memory64 and 8+ GB RAM; not supported on Safari or mobile browsers.',
  ),
];

ModelParams buildGgufModelParams(GgufModelOption model, {bool isWeb = kIsWeb}) {
  return ModelParams(
    contextSize: model.contextSize,
    modelBytesHint: isWeb ? model.sizeBytes : null,
  );
}

class ChatMessage {
  const ChatMessage(this.role, this.text);

  final LlamaChatRole role;
  final String text;
}

class ChatSettings {
  const ChatSettings({
    this.temperature = 0.7,
    this.maxTokens = 256,
    this.systemPrompt = 'You are a concise, helpful assistant.',
  });

  final double temperature;
  final int maxTokens;
  final String systemPrompt;
}

class ChatStats {
  const ChatStats({
    this.backendName,
    this.outputTokens,
    this.tokensPerSecond,
    this.elapsed,
  });

  final String? backendName;
  final int? outputTokens;
  final double? tokensPerSecond;
  final Duration? elapsed;
}

class ChatPreset {
  const ChatPreset(this.label, this.prompt);

  final String label;
  final String prompt;
}

const chatPresets = [
  ChatPreset(
    'Summarize',
    'Summarize how WebGPU speeds up browser AI in 3 short bullet points.',
  ),
  ChatPreset(
    'Translate',
    'Translate to Spanish and French: "Local AI runs privately in your browser."',
  ),
  ChatPreset(
    'Explain code',
    'Explain what this Dart line does: '
        'final nums = [1, 2, 3].map((n) => n * 2).toList();',
  ),
  ChatPreset(
    'Brainstorm',
    'Give 3 concise app ideas that use an offline LLM on a phone.',
  ),
];

class ChatController extends ChangeNotifier {
  ChatController(this.createEngine);

  final Future<LlamaEngine> Function() createEngine;
  final _messages = <ChatMessage>[];
  final _clock = Stopwatch();
  LlamaEngine? _engine;
  ChatSession? _session;
  GgufModelOption _selectedModel = ggufModels.first;
  ChatSettings _settings = const ChatSettings();
  ChatStats _stats = const ChatStats();
  Timer? _ticker;
  double? _progress;
  bool _loading = false;
  bool _generating = false;
  bool _stopRequested = false;
  bool _disposed = false;
  String _status = 'Load ${ggufModels.first.label} to begin.';

  List<ChatMessage> get messages => List.unmodifiable(_messages);
  GgufModelOption get selectedModel => _selectedModel;
  ChatSettings get settings => _settings;
  ChatStats get stats => _generating
      ? ChatStats(backendName: _stats.backendName, elapsed: _clock.elapsed)
      : _stats;
  double? get progress => _progress;
  bool get loading => _loading;
  bool get ready => _session != null;
  bool get generating => _generating;
  String get status => _status;

  Future<void> selectModel(GgufModelOption model) async {
    if (_loading || _generating || model.id == _selectedModel.id) return;
    final engine = _engine;
    _engine = null;
    _session = null;
    _selectedModel = model;
    _messages.clear();
    _stats = const ChatStats();
    _progress = null;
    _status = 'Load ${model.label} to begin.';
    notifyListeners();
    if (engine != null) {
      _loading = true;
      notifyListeners();
      try {
        await engine.dispose();
      } finally {
        _loading = false;
        if (!_disposed) notifyListeners();
      }
    }
  }

  Future<void> load() async {
    if (_loading || ready) return;
    final model = _selectedModel;
    _loading = true;
    _progress = null;
    _status = 'Loading ${model.label}…';
    notifyListeners();
    try {
      final engine = _engine ?? await createEngine();
      if (_disposed) {
        await engine.dispose();
        return;
      }
      _engine = engine;
      await engine.setModel(
        LlamaModel(ModelSource.url(Uri.parse(model.url))),
        params: buildGgufModelParams(model),
        onProgress: (progress) {
          if (_disposed) return;
          _progress = progress.fraction;
          notifyListeners();
        },
      );
      if (_disposed) return;
      final backendName = await engine.getBackendName();
      if (_disposed) return;
      _stats = ChatStats(backendName: backendName);
      _session = ChatSession(engine, maxContextTokens: model.contextSize);
      _status = 'Model ready.';
    } on LlamaException catch (error) {
      _status = error.message;
    } finally {
      _loading = false;
      if (!_disposed) notifyListeners();
    }
  }

  void updateSettings({
    double? temperature,
    int? maxTokens,
    String? systemPrompt,
  }) {
    _settings = ChatSettings(
      temperature: temperature ?? _settings.temperature,
      maxTokens: maxTokens ?? _settings.maxTokens,
      systemPrompt: systemPrompt ?? _settings.systemPrompt,
    );
    notifyListeners();
  }

  Future<void> send(String text) async {
    final session = _session;
    final prompt = text.trim();
    if (session == null || _generating || prompt.isEmpty) return;

    final systemPrompt = _settings.systemPrompt.trim();
    session.systemPrompt = systemPrompt.isEmpty ? null : systemPrompt;
    _messages.addAll([
      ChatMessage(LlamaChatRole.user, prompt),
      const ChatMessage(LlamaChatRole.assistant, ''),
    ]);
    _generating = true;
    _stopRequested = false;
    _status = 'Generating…';
    _clock
      ..reset()
      ..start();
    _ticker = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => notifyListeners(),
    );
    notifyListeners();

    final reply = StringBuffer();
    String? committedReply;
    LlamaGenerationUsage? usage;
    String? errorMessage;
    try {
      await for (final chunk in session.create(
        [LlamaTextContent(prompt)],
        params: GenerationParams(
          temp: _settings.temperature,
          maxTokens: _settings.maxTokens,
        ),
        enableThinking: false,
        onMessageAdded: (message) {
          if (message.role == LlamaChatRole.assistant) {
            committedReply = message.content;
          }
        },
      )) {
        if (_disposed) return;
        reply.write(chunk.text);
        usage = chunk.usage ?? usage;
        _messages.last = ChatMessage(LlamaChatRole.assistant, reply.toString());
        notifyListeners();
      }
    } on LlamaException catch (error) {
      errorMessage = error.message;
    } finally {
      _ticker?.cancel();
      _clock.stop();
    }
    if (_disposed) return;

    // ChatSession decides whether this turn survives and normalizes its reply.
    final answer = committedReply;
    if (answer == null) {
      _messages.removeRange(_messages.length - 2, _messages.length);
    } else {
      _messages.last = ChatMessage(LlamaChatRole.assistant, answer);
    }

    final duration = usage?.duration ?? Duration.zero;
    final elapsed = duration > Duration.zero ? duration : _clock.elapsed;
    var tokens = usage?.completionTokens;
    if (tokens == null &&
        _stopRequested &&
        answer != null &&
        answer.isNotEmpty) {
      try {
        tokens = await session.engine.getTokenCount(answer);
      } on LlamaException {
        // Some runtimes do not expose a tokenizer.
      }
    }
    if (_disposed) return;
    _stats = ChatStats(
      backendName: _stats.backendName,
      outputTokens: tokens,
      tokensPerSecond: tokens != null && elapsed > Duration.zero
          ? tokens * Duration.microsecondsPerSecond / elapsed.inMicroseconds
          : null,
      elapsed: elapsed,
    );
    _status = _stopRequested ? 'Stopped.' : errorMessage ?? 'Model ready.';
    _generating = false;
    notifyListeners();
  }

  void stop() {
    if (!_generating || _stopRequested) return;
    _stopRequested = true;
    _status = 'Stopping…';
    // The runtime can flush text before the stream ends and commits the reply.
    _engine?.cancelGeneration();
    notifyListeners();
  }

  void clearChat() {
    if (_generating) return;
    _session?.reset();
    _messages.clear();
    _stats = ChatStats(backendName: _stats.backendName);
    _status = 'Model ready.';
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _ticker?.cancel();
    _engine?.cancelGeneration();
    unawaited(_engine?.dispose());
    super.dispose();
  }
}
