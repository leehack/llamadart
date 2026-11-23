import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:genkit/genkit.dart';
import 'package:genkit_google_genai/genkit_google_genai.dart';
import 'package:genkit_llamadart/genkit_llamadart.dart';
import 'package:http/http.dart' as http;

class LocalModelOption {
  const LocalModelOption({
    required this.id,
    required this.label,
    required this.url,
    required this.sizeLabel,
    required this.sizeBytes,
    required this.contextSize,
    required this.note,
    this.warning,
    this.promptSuffix = '',
    this.enableThinking = false,
  });

  final String id;
  final String label;
  final String url;
  final String sizeLabel;
  final int sizeBytes;
  final int contextSize;
  final String note;
  final String? warning;
  final String promptSuffix;
  final bool enableThinking;
}

const ggufModels = <LocalModelOption>[
  LocalModelOption(
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
  LocalModelOption(
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
  LocalModelOption(
    id: 'gemma-4-e2b',
    label: 'Gemma 4 E2B',
    url:
        'https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/'
        '0314792d7f1f7e229411f620751375812bb9faf2/'
        'gemma-4-E2B-it-Q4_K_S.gguf',
    sizeLabel: 'desktop Chrome, ~3 GB',
    sizeBytes: 3043934304,
    contextSize: 2048,
    note: 'Higher quality responses; thinking disabled for quick replies.',
    warning:
        'Large download (~3 GB; can take several minutes). Measured ~11 GB '
        'peak browser memory — requires desktop Chrome with WebAssembly '
        'memory64 and 16+ GB RAM recommended; not supported on Safari or '
        'mobile browsers.',
  ),
];

const liteRtLmModels = <LocalModelOption>[
  LocalModelOption(
    id: 'qwen3-0.6b',
    label: 'Qwen3 0.6B',
    url:
        'https://huggingface.co/litert-community/Qwen3-0.6B/resolve/'
        '8d42ab5f1db14cad987fac57aeb17d070f9e180d/'
        'Qwen3-0.6B_dynamic_wi4b32_afp32.litertlm',
    sizeLabel: '~343 MB',
    sizeBytes: 343490560,
    contextSize: 1024,
    note: 'Fastest download. Requires Chrome with WebGPU.',
    // Qwen3's built-in template uses this suffix to suppress thinking.
    promptSuffix: '\n/no_think',
    enableThinking: true,
  ),
  LocalModelOption(
    id: 'gemma-4-e2b-litert',
    label: 'Gemma 4 E2B',
    url:
        'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/'
        '2e12bfd869b2962984f97a1f2a26807316d534cc/'
        'gemma-4-E2B-it-web.litertlm',
    sizeLabel: 'desktop Chrome, ~2 GB',
    sizeBytes: 2008432640,
    contextSize: 1024,
    note: 'Requires WebGPU.',
    warning:
        'Large download (~2 GB) can take several minutes. Measured ~3 GB '
        'peak Chrome memory on desktop and ~7 GB on Safari. Keep the Safari '
        'tab visible while loading. '
        'Requires WebGPU on desktop. Reloading the page or switching back '
        'to this model re-downloads the file.',
    enableThinking: true,
  ),
];

ModelParams buildGgufModelParams(
  LocalModelOption model, {
  bool isWeb = kIsWeb,
}) => ModelParams(
  contextSize: model.contextSize,
  // Native llama.cpp rejects Web-only hints such as modelBytesHint.
  modelBytesHint: isWeb ? model.sizeBytes : null,
);

// LiteRT-LM rejects llama.cpp Web hints such as modelBytesHint.
ModelParams buildLiteRtLmModelParams(LocalModelOption model) =>
    ModelParams(contextSize: model.contextSize);

// The pinned plugin routes this model through streamGenerateContent, whose
// CORS preflight allows the request headers used in DartPad.
const _geminiModelName = 'gemini-3.1-flash-lite';

enum PlaygroundProvider {
  gguf('GGUF'),
  liteRtLm('LiteRT-LM'),
  gemini('Gemini');

  const PlaygroundProvider(this.label);

  final String label;
}

const singleTurnNotice =
    'This runtime runs single-turn only (history and system prompt are not sent).';

class ChatTurn {
  const ChatTurn(this.role, this.text);

  final Role role;
  final String text;
}

// Rough budget for prior turns sent to the 2,048-token local GGUF context,
// leaving room for the system prompt, current prompt, and reply tokens.
const localHistoryCharBudget = 4500;

({List<ChatTurn> turns, int omittedPairs}) trimLocalHistory(
  List<ChatTurn> messages, {
  int maxChars = localHistoryCharBudget,
}) {
  final pairs = <(ChatTurn, ChatTurn)>[];
  for (var i = 0; i + 1 < messages.length; i += 2) {
    pairs.add((messages[i], messages[i + 1]));
  }
  final kept = <(ChatTurn, ChatTurn)>[];
  var chars = 0;
  for (var i = pairs.length - 1; i >= 0; i--) {
    final pair = pairs[i];
    final pairChars = pair.$1.text.length + pair.$2.text.length;
    if (chars + pairChars > maxChars) break;
    kept.add(pair);
    chars += pairChars;
  }
  final turns = <ChatTurn>[
    for (final pair in kept.reversed) ...[pair.$1, pair.$2],
  ];
  return (turns: turns, omittedPairs: pairs.length - kept.length);
}

String formatLoadElapsed(Duration elapsed) {
  final totalSeconds = elapsed.inSeconds;
  if (totalSeconds < 60) return '${totalSeconds}s';
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  return '${minutes}m ${seconds.toString().padLeft(2, '0')}s';
}

String formatStats(int? outputTokens, double? latencyMs) {
  if (outputTokens == null) return '';
  final count = '$outputTokens tok';
  if (latencyMs == null || latencyMs <= 0) return count;
  final rate = outputTokens / (latencyMs / 1000);
  return '$count · ${rate.toStringAsFixed(1)} tok/s';
}

class PlaygroundController extends ChangeNotifier {
  PlaygroundController({
    required this.bootstrapGguf,
    required this.bootstrapLiteRt,
    required this.runtimeFactory,
    required this.googlePlugin,
    this.isWeb = kIsWeb,
  });

  final Future<void> Function() bootstrapGguf;
  final Future<void> Function() bootstrapLiteRt;
  final LlamaDartRuntimeFactory? runtimeFactory;
  final GenkitPlugin Function(String key) googlePlugin;
  final bool isWeb;

  final prompt = TextEditingController(text: 'Tell me a story about a fox.');
  final apiKey = TextEditingController();
  final liveStats = ValueNotifier<String?>(null);
  final liveStatus = ValueNotifier<String>(
    'Load ${ggufModels.first.label} to begin.',
  );
  final streamingText = ValueNotifier<String?>(null);
  final _messages = <ChatTurn>[];
  final _elapsed = Stopwatch();
  Timer? _ticker;
  Timer? _loadTicker;
  Genkit? _ai;
  LlamaDartPlugin? _local;
  CancellationController? _cancellation;
  bool _disposed = false;
  bool _loading = false;
  bool _supportsMultiTurn = false;
  PlaygroundProvider _provider = PlaygroundProvider.gguf;
  LocalModelOption _ggufModel = ggufModels.first;
  LocalModelOption _liteRtLmModel = liteRtLmModels.first;
  String? _backendName;
  double? _latencyMs;
  int? _outputTokens;
  int _omittedHistoryTurns = 0;

  double _temperature = 0.7;
  int _maxTokens = 256;
  String _systemPrompt = 'You are a concise, helpful assistant.';

  PlaygroundProvider get provider => _provider;
  LocalModelOption get ggufModel => _ggufModel;
  LocalModelOption get liteRtLmModel => _liteRtLmModel;
  bool get isGguf => _provider == PlaygroundProvider.gguf;
  bool get isLiteRtLm => _provider == PlaygroundProvider.liteRtLm;
  bool get isGemini => _provider == PlaygroundProvider.gemini;
  bool get ready => _ai != null;
  bool get loading => _loading;
  bool get generating => _cancellation != null;
  bool get busy => loading || generating;
  bool get supportsMultiTurn => _supportsMultiTurn;
  String get status => liveStatus.value;
  double get temperature => _temperature;
  int get maxTokens => _maxTokens;
  String get systemPrompt => _systemPrompt;
  int get omittedHistoryTurns => _omittedHistoryTurns;
  List<ChatTurn> get messages => List.unmodifiable(_messages);
  String? get stats => liveStats.value;

  void _setStatus(String value) => liveStatus.value = value;

  String _idleStatus() => switch (_provider) {
    PlaygroundProvider.gguf => 'Load ${_ggufModel.label} to begin.',
    PlaygroundProvider.liteRtLm => 'Load ${_liteRtLmModel.label} to begin.',
    PlaygroundProvider.gemini => 'Enter a Gemini API key to connect.',
  };

  String? _formatCurrentStats() {
    final backend = _backendName;
    if (backend == null) return null;
    final usage = formatStats(_outputTokens, _latencyMs);
    if (usage.isNotEmpty) return '$backend · $usage';
    final elapsedMs = generating
        ? _elapsed.elapsedMicroseconds / 1000
        : _latencyMs;
    if (elapsedMs == null) return backend;
    return '$backend · ${(elapsedMs / 1000).toStringAsFixed(1)}s';
  }

  void _syncStats() => liveStats.value = _formatCurrentStats();

  void setTemperature(double value) {
    _temperature = value;
    notifyListeners();
  }

  void setMaxTokens(double value) {
    _maxTokens = value.round();
    notifyListeners();
  }

  void setSystemPrompt(String value) => _systemPrompt = value;

  Future<void> select(PlaygroundProvider provider) async {
    if (busy || provider == _provider) return;
    final ai = _ai;
    final local = _local;
    _provider = provider;
    _ai = null;
    _local = null;
    _supportsMultiTurn = false;
    _backendName = null;
    _resetChat();
    apiKey.clear();
    _setStatus(_idleStatus());
    if (ai == null && local == null) {
      notifyListeners();
      return;
    }
    _loading = true;
    notifyListeners();
    try {
      await _close(ai, local);
    } finally {
      _loading = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> selectGgufModel(LocalModelOption model) async {
    if (busy || model.id == _ggufModel.id) return;
    _ggufModel = model;
    await _resetAfterModelChange(active: isGguf);
  }

  Future<void> selectLiteRtLmModel(LocalModelOption model) async {
    if (busy || model.id == _liteRtLmModel.id) return;
    _liteRtLmModel = model;
    await _resetAfterModelChange(active: isLiteRtLm);
  }

  Future<void> _resetAfterModelChange({required bool active}) async {
    if (!active) {
      notifyListeners();
      return;
    }
    final ai = _ai;
    final local = _local;
    _ai = null;
    _local = null;
    _supportsMultiTurn = false;
    _backendName = null;
    _resetChat();
    _setStatus(_idleStatus());
    if (ai == null && local == null) {
      notifyListeners();
      return;
    }
    _loading = true;
    notifyListeners();
    try {
      await _close(ai, local);
    } finally {
      _loading = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> load() async {
    if (busy || ready) return;
    final key = apiKey.text.trim();
    if (isGemini && key.isEmpty) return;
    final provider = _provider;
    final useGguf = provider == PlaygroundProvider.gguf;
    final activeModel = useGguf ? _ggufModel : _liteRtLmModel;
    final loadingLabel = isGemini ? provider.label : activeModel.label;
    _loading = true;
    apiKey.clear();
    _setStatus(isGemini ? 'Setting up Gemini…' : 'Loading $loadingLabel…');
    notifyListeners();

    Timer? loadTicker;
    if (!isGemini) {
      var ticks = 0;
      final loadWatch = Stopwatch()..start();
      loadTicker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (_disposed) return;
        ticks++;
        // Combine timer ticks and wall time so both real loads and FakeAsync
        // widget tests advance the elapsed counter consistently.
        final seconds = ticks > loadWatch.elapsed.inSeconds
            ? ticks
            : loadWatch.elapsed.inSeconds;
        _setStatus(
          'Loading $loadingLabel… '
          '${formatLoadElapsed(Duration(seconds: seconds))}',
        );
      });
      _loadTicker = loadTicker;
    }

    LlamaDartPlugin? local;
    Genkit? ai;
    try {
      if (isGemini) {
        ai = Genkit(
          plugins: [googlePlugin(key)],
          model: googleAI.gemini(_geminiModelName),
          isDevEnv: false,
        );
        _backendName = 'Gemini (Cloud)';
        _supportsMultiTurn = true;
        _syncStats();
        _setStatus('Gemini ready. Send to verify your key.');
      } else {
        await (useGguf ? bootstrapGguf() : bootstrapLiteRt());
        if (_disposed) return;
        final model = LlamaModelDefinition(
          name: activeModel.id,
          modelPath: activeModel.url,
          modelParams: useGguf
              ? buildGgufModelParams(activeModel, isWeb: isWeb)
              : buildLiteRtLmModelParams(activeModel),
          supportsEmbeddings: false,
          supportsTools: false,
          supportsConstrainedOutput: false,
        );
        local = LlamaDartPlugin(
          models: [model],
          runtimeFactory: runtimeFactory,
        );
        final inspection = await local.inspectModel(model.name);
        if (_disposed) return;
        ai = Genkit(
          plugins: [local],
          model: llamaDart.model(model.name),
          isDevEnv: false,
        );
        final capabilities = inspection.capabilities;
        _backendName = capabilities?.backendName ?? provider.label;
        _supportsMultiTurn = capabilities?.supportsMultiTurnChat ?? false;
        _syncStats();
        _setStatus('Model ready ($_backendName).');
      }
      _ai = ai;
      _local = local;
    } catch (error) {
      _setStatus(switch (error) {
        _ when isGemini => 'Gemini setup failed. Re-enter your API key.',
        LlamaException(:final message) => message,
        _ => 'Could not load $loadingLabel.',
      });
    } finally {
      loadTicker?.cancel();
      if (_loadTicker == loadTicker) _loadTicker = null;
      try {
        if (!ready) await _close(ai, local);
      } finally {
        _loading = false;
        if (!_disposed) notifyListeners();
      }
    }
  }

  Future<void> send() async {
    final ai = _ai;
    final text = prompt.text.trim();
    if (busy || ai == null || text.isEmpty) return;

    prompt.clear();
    final gemini = isGemini;
    final trimmed = _supportsMultiTurn && !gemini
        ? trimLocalHistory(_messages)
        : (
            turns: _supportsMultiTurn ? _messages : const <ChatTurn>[],
            omittedPairs: 0,
          );
    _omittedHistoryTurns = trimmed.omittedPairs;
    final history = <Message>[
      for (final turn in trimmed.turns)
        Message(
          role: turn.role,
          content: [TextPart(text: turn.text)],
        ),
    ];
    final system = _systemPrompt.trim();
    final activeModel = isGguf ? _ggufModel : _liteRtLmModel;
    final cancellation = CancellationController();
    final reply = StringBuffer();
    _cancellation = cancellation;
    _messages.add(ChatTurn(Role.user, text));
    streamingText.value = '';
    _setStatus('Generating…');
    _outputTokens = null;
    _latencyMs = null;
    _elapsed
      ..reset()
      ..start();
    _syncStats();
    _ticker = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!_disposed) _syncStats();
    });
    notifyListeners();

    bool isCurrent() => !_disposed && _cancellation == cancellation;

    Future<GenerateResult<Object?>> generate() => ai.generate<Object?, Object>(
      system: _supportsMultiTurn && system.isNotEmpty ? system : null,
      messages: history.isEmpty ? null : history,
      prompt: gemini ? text : '$text${activeModel.promptSuffix}',
      config: gemini
          ? GeminiOptions(
              temperature: _temperature,
              maxOutputTokens: _maxTokens,
            )
          : LlamaDartGenerationConfig(
              temperature: _temperature,
              maxTokens: _maxTokens,
              enableThinking: activeModel.enableThinking,
            ),
      cancel: cancellation.token,
      onChunk: (chunk) {
        if (!isCurrent()) return;
        reply.write(chunk.text);
        streamingText.value = reply.toString();
      },
    );

    final errorMessage = gemini
        ? 'Gemini request failed. Check your API key and connection.'
        : 'Generation failed.';
    String withLocalHistoryHint(String base) {
      if (gemini || history.isEmpty) return base;
      final punctuated = base.endsWith('.') ? base : '$base.';
      return '$punctuated Try Clear or a shorter prompt.';
    }

    String status;
    try {
      final result = await (gemini
          ? http.runWithClient(
              generate,
              () => _GeminiClient(http.Client(), cancellation.token),
            )
          : generate());
      if (!isCurrent()) return;
      final reason = result.finishReason;
      final latencyMs = result.latencyMs;
      _outputTokens = result.usage?.outputTokens;
      _latencyMs = latencyMs != null && latencyMs > 0 ? latencyMs : null;
      status = switch (reason) {
        FinishReason.aborted => 'Stopped.',
        FinishReason.failed =>
          gemini
              ? errorMessage
              : withLocalHistoryHint(result.finishMessage ?? errorMessage),
        FinishReason.blocked => 'The model blocked this response.',
        _ when reply.isEmpty => 'The model returned no response text.',
        _ => 'Done.',
      };
    } catch (_) {
      status = withLocalHistoryHint(errorMessage);
    }
    if (isCurrent()) _finishTurn(status);
  }

  void stop() {
    final cancellation = _cancellation;
    if (cancellation == null) return;
    _finishTurn('Stopped.');
    cancellation.cancel();
  }

  void _finishTurn(String status) {
    _cancellation = null;
    _ticker?.cancel();
    _ticker = null;
    _elapsed.stop();
    _latencyMs ??= _elapsed.elapsedMicroseconds / 1000;
    final replyText = streamingText.value ?? '';
    streamingText.value = null;
    if (replyText.isNotEmpty) {
      _messages.add(ChatTurn(Role.model, replyText));
    } else if (_messages.isNotEmpty && _messages.last.role == Role.user) {
      // An unanswered prompt should not become part of the next request.
      _messages.removeLast();
    }
    _syncStats();
    _setStatus(status);
    notifyListeners();
  }

  void clearChat() {
    if (busy) return;
    _resetChat();
    notifyListeners();
  }

  void _resetChat() {
    _messages.clear();
    _omittedHistoryTurns = 0;
    _outputTokens = null;
    _latencyMs = null;
    _syncStats();
  }

  Future<void> _close(Genkit? ai, LlamaDartPlugin? local) async {
    try {
      await local?.dispose();
    } finally {
      await ai?.shutdown();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _ticker?.cancel();
    _loadTicker?.cancel();
    _cancellation?.cancel();
    prompt.dispose();
    apiKey.dispose();
    liveStats.dispose();
    liveStatus.dispose();
    streamingText.dispose();
    unawaited(_close(_ai, _local));
    super.dispose();
  }
}

class _GeminiClient extends http.BaseClient {
  _GeminiClient(this._client, this._token);

  final http.Client _client;
  final CancellationToken _token;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request is! http.Request) return _client.send(request);
    // BrowserClient.close() no longer tracks the fetch after headers arrive.
    // The abort trigger also cancels reads from a stalled response body.
    final abortable =
        http.AbortableRequest(
            request.method,
            request.url,
            abortTrigger: _token.whenCancelled,
          )
          ..followRedirects = request.followRedirects
          ..maxRedirects = request.maxRedirects
          ..persistentConnection = request.persistentConnection
          ..headers.addAll(request.headers)
          ..bodyBytes = request.bodyBytes;
    return _client.send(abortable);
  }

  @override
  void close() => _client.close();
}
