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
    this.useLowMemoryWebLoad = false,
  });

  final String id;
  final String label;
  final String url;
  final String sizeLabel;
  final int sizeBytes;
  final int contextSize;
  final String note;
  final String? warning;
  final bool useLowMemoryWebLoad;
}

const ggufModels = <GgufModelOption>[
  GgufModelOption(
    id: 'smollm2-135m',
    label: 'SmolLM2 135M',
    url:
        'https://huggingface.co/unsloth/SmolLM2-135M-Instruct-GGUF/resolve/'
        '9e6855bc4be717fca1ef21360a1db4b29d5c559a/'
        'SmolLM2-135M-Instruct-Q4_K_M.gguf',
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
    note:
        'Stronger responses with thinking disabled. Measured about 4 GiB '
        'peak Chrome memory.',
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
    note: 'Higher quality with thinking disabled.',
    warning:
        'Large download (~3 GB) can take several minutes. Measured about '
        '7 GiB peak memory in desktop Chrome. Most layers run on the CPU, '
        'so replies can take longer. 16+ GB RAM recommended.',
    useLowMemoryWebLoad: true,
  ),
];

ModelParams buildGgufModelParams(GgufModelOption model, {bool isWeb = kIsWeb}) {
  final useLowMemoryLoad = isWeb && model.useLowMemoryWebLoad;
  return ModelParams(
    contextSize: model.contextSize,
    modelBytesHint: isWeb ? model.sizeBytes : null,
    preferMemory64: useLowMemoryLoad ? false : null,
    jsBackedModelStaging: useLowMemoryLoad ? true : null,
    // At most one GPU layer lets the bridge memory-map the staged GGUF.
    gpuLayers: useLowMemoryLoad ? 1 : ModelParams.maxGpuLayers,
  );
}

String formatLoadStatus(GgufModelOption model, ModelDownloadProgress progress) {
  final fraction = progress.fraction;
  if (fraction == null) return 'Loading ${model.label}…';
  if (fraction >= 0.999) return 'Initializing ${model.label}…';
  final percent = (fraction * 100).round();
  final totalBytes = progress.totalBytes ?? model.sizeBytes;
  final receivedBytes = progress.totalBytes != null
      ? progress.receivedBytes
      : (fraction * totalBytes).round();
  final prefix = progress.totalBytes != null ? '' : '~';
  return 'Downloading ${model.label}… $percent% '
      '($prefix${_formatBytePair(receivedBytes, totalBytes)})';
}

String _formatBytePair(int receivedBytes, int totalBytes) {
  if (totalBytes >= 1000 * 1000 * 1000) {
    final receivedGb = (receivedBytes / (1000 * 1000 * 1000)).toStringAsFixed(
      1,
    );
    final totalGb = (totalBytes / (1000 * 1000 * 1000)).toStringAsFixed(1);
    return '$receivedGb / $totalGb GB';
  }
  final receivedMb = (receivedBytes / (1000 * 1000)).round();
  final totalMb = (totalBytes / (1000 * 1000)).round();
  return '$receivedMb / $totalMb MB';
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
  final ValueNotifier<double?> progress = ValueNotifier<double?>(null);
  final ValueNotifier<ChatStats> stats = ValueNotifier<ChatStats>(
    const ChatStats(),
  );
  final ValueNotifier<String?> streamingText = ValueNotifier<String?>(null);
  final ValueNotifier<String> status = ValueNotifier<String>(
    'Load ${ggufModels.first.label} to begin.',
  );

  LlamaEngine? _engine;
  ChatSession? _session;
  GgufModelOption _selectedModel = ggufModels.first;
  ChatSettings _settings = const ChatSettings();
  String? _backendName;
  Timer? _ticker;
  bool _loading = false;
  bool _generating = false;
  bool _stopRequested = false;
  bool _disposed = false;

  List<ChatMessage> get messages => List.unmodifiable(_messages);
  GgufModelOption get selectedModel => _selectedModel;
  ChatSettings get settings => _settings;
  bool get loading => _loading;
  bool get ready => _session != null;
  bool get generating => _generating;

  Future<void> _disposeQuietly(LlamaEngine? engine) async {
    if (engine == null) return;
    try {
      await engine.dispose();
    } catch (_) {}
  }

  Future<void> selectModel(GgufModelOption model) async {
    if (_loading || _generating || model.id == _selectedModel.id) return;
    final engine = _engine;
    _engine = null;
    _session = null;
    _backendName = null;
    _selectedModel = model;
    _messages.clear();
    streamingText.value = null;
    stats.value = const ChatStats();
    progress.value = null;
    status.value = 'Load ${model.label} to begin.';
    if (engine == null) {
      notifyListeners();
      return;
    }
    _loading = true;
    notifyListeners();
    try {
      await engine.dispose();
    } catch (_) {
      if (!_disposed) {
        status.value =
            'Previous model did not unload cleanly. Load ${model.label} to begin.';
      }
    } finally {
      _loading = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> load() async {
    if (_loading || ready) return;
    final model = _selectedModel;
    _loading = true;
    progress.value = null;
    status.value = 'Loading ${model.label}…';
    notifyListeners();
    try {
      final engine = _engine ?? await createEngine();
      if (_disposed) {
        await _disposeQuietly(engine);
        return;
      }
      _engine = engine;
      await engine.setModel(
        LlamaModel(ModelSource.url(Uri.parse(model.url))),
        params: buildGgufModelParams(model),
        onProgress: (downloadProgress) {
          if (_disposed) return;
          final fraction = downloadProgress.fraction;
          final previous = progress.value;
          if (fraction != null &&
              previous != null &&
              fraction < 0.999 &&
              (fraction - previous).abs() < 0.01 - 1e-9) {
            return;
          }
          progress.value = fraction;
          status.value = formatLoadStatus(model, downloadProgress);
        },
      );
      if (_disposed) return;
      final backendName = await engine.getBackendName();
      if (_disposed) return;
      _backendName = backendName;
      stats.value = ChatStats(backendName: backendName);
      _session = ChatSession(engine, maxContextTokens: model.contextSize);
      status.value = 'Model ready.';
    } on LlamaException catch (error) {
      if (!_disposed) status.value = error.message;
    } catch (_) {
      if (!_disposed) status.value = 'Could not load ${model.label}.';
    } finally {
      _loading = false;
      if (!_disposed) {
        progress.value = null;
        notifyListeners();
      }
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
    if (temperature != null || maxTokens != null) {
      notifyListeners();
    }
  }

  Future<void> send(String text) async {
    final session = _session;
    final prompt = text.trim();
    if (session == null || _generating || prompt.isEmpty) return;

    final systemPrompt = _settings.systemPrompt.trim();
    session.systemPrompt = systemPrompt.isEmpty ? null : systemPrompt;
    _messages.add(ChatMessage(LlamaChatRole.user, prompt));
    _generating = true;
    _stopRequested = false;
    streamingText.value = '';
    status.value = 'Generating…';
    _clock
      ..reset()
      ..start();
    stats.value = ChatStats(backendName: _backendName, elapsed: Duration.zero);
    _ticker = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (_disposed) return;
      stats.value = ChatStats(
        backendName: _backendName,
        elapsed: _clock.elapsed,
      );
    });
    notifyListeners();

    try {
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
          streamingText.value = reply.toString();
        }
      } on LlamaException catch (error) {
        errorMessage = error.message;
      } catch (_) {
        errorMessage = 'Generation failed.';
      } finally {
        _ticker?.cancel();
        _ticker = null;
        _clock.stop();
      }
      if (_disposed) return;

      streamingText.value = null;
      // ChatSession decides whether this turn survives and normalizes its reply.
      final answer = committedReply;
      if (answer == null) {
        if (_messages.isNotEmpty) _messages.removeLast();
      } else {
        _messages.add(ChatMessage(LlamaChatRole.assistant, answer));
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
        } catch (_) {
          // Some runtimes do not expose a tokenizer or may fail during teardown.
        }
      }
      if (_disposed) return;
      stats.value = ChatStats(
        backendName: _backendName,
        outputTokens: tokens,
        tokensPerSecond: tokens != null && elapsed > Duration.zero
            ? tokens * Duration.microsecondsPerSecond / elapsed.inMicroseconds
            : null,
        elapsed: elapsed,
      );
      status.value = _stopRequested
          ? 'Stopped.'
          : errorMessage ?? 'Model ready.';
    } finally {
      _ticker?.cancel();
      _ticker = null;
      _clock.stop();
      _generating = false;
      if (!_disposed) {
        streamingText.value = null;
        notifyListeners();
      }
    }
  }

  void stop() {
    if (!_generating || _stopRequested) return;
    _stopRequested = true;
    status.value = 'Stopping…';
    // The runtime can flush text before the stream ends and commits the reply.
    _engine?.cancelGeneration();
  }

  void clearChat() {
    if (_generating) return;
    _session?.reset();
    _messages.clear();
    streamingText.value = null;
    stats.value = ChatStats(backendName: _backendName);
    status.value = 'Model ready.';
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _ticker?.cancel();
    _engine?.cancelGeneration();
    unawaited(_disposeQuietly(_engine));
    progress.dispose();
    stats.dispose();
    streamingText.dispose();
    status.dispose();
    super.dispose();
  }
}
