import 'dart:async';

import 'package:flutter/material.dart';
import 'package:genkit/genkit.dart';
import 'package:genkit_google_genai/genkit_google_genai.dart';
import 'package:genkit_llamadart/genkit_llamadart.dart';
import 'package:http/http.dart' as http;

const _smolLm = LlamaModelDefinition(
  name: 'smollm2',
  modelPath:
      'https://huggingface.co/unsloth/SmolLM2-135M-Instruct-GGUF/resolve/'
      '9e6855bc4be717fca1ef21360a1db4b29d5c559a/'
      'SmolLM2-135M-Instruct-Q4_K_M.gguf',
  modelParams: ModelParams(contextSize: 2048),
  supportsEmbeddings: false,
  supportsTools: false,
  supportsConstrainedOutput: false,
);
const _qwen = LlamaModelDefinition(
  name: 'qwen3',
  modelPath:
      'https://huggingface.co/litert-community/Qwen3-0.6B/resolve/'
      '8d42ab5f1db14cad987fac57aeb17d070f9e180d/'
      'Qwen3-0.6B_dynamic_wi4b32_afp32.litertlm',
  modelParams: ModelParams(contextSize: 1024),
  supportsEmbeddings: false,
  supportsTools: false,
  supportsConstrainedOutput: false,
);
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
  });

  final Future<void> Function() bootstrapGguf;
  final Future<void> Function() bootstrapLiteRt;
  final LlamaDartRuntimeFactory? runtimeFactory;
  final GenkitPlugin Function(String key) googlePlugin;

  final prompt = TextEditingController(text: 'Tell me a story about a fox.');
  final apiKey = TextEditingController();
  final _messages = <ChatTurn>[];
  final _elapsed = Stopwatch();
  Timer? _ticker;
  Genkit? _ai;
  LlamaDartPlugin? _local;
  CancellationController? _cancellation;
  bool _disposed = false;
  bool _loading = false;
  bool _supportsMultiTurn = false;
  PlaygroundProvider _provider = PlaygroundProvider.gguf;
  String _status = 'Load a GGUF model to begin.';
  String? _backendName;
  double? _latencyMs;
  int? _outputTokens;

  double _temperature = 0.7;
  int _maxTokens = 256;
  String _systemPrompt = 'You are a concise, helpful assistant.';

  PlaygroundProvider get provider => _provider;
  bool get isGemini => _provider == PlaygroundProvider.gemini;
  bool get ready => _ai != null;
  bool get loading => _loading;
  bool get generating => _cancellation != null;
  bool get busy => loading || generating;
  bool get supportsMultiTurn => _supportsMultiTurn;
  String get status => _status;
  double get temperature => _temperature;
  int get maxTokens => _maxTokens;
  String get systemPrompt => _systemPrompt;
  List<ChatTurn> get messages => List.unmodifiable(_messages);

  String? get stats {
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
    _loading = true;
    _status = isGemini
        ? 'Enter a Gemini API key to connect.'
        : 'Load the ${provider.label} model to begin.';
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
    _loading = true;
    apiKey.clear();
    _status = isGemini ? 'Setting up Gemini…' : 'Loading ${provider.label}…';
    notifyListeners();

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
        _status = 'Gemini ready. Send to verify your key.';
      } else {
        final isGguf = provider == PlaygroundProvider.gguf;
        await (isGguf ? bootstrapGguf() : bootstrapLiteRt());
        if (_disposed) return;
        final model = isGguf ? _smolLm : _qwen;
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
        _status = 'Model ready ($_backendName).';
      }
      _ai = ai;
      _local = local;
    } catch (error) {
      _status = switch (error) {
        _ when isGemini => 'Gemini setup failed. Re-enter your API key.',
        LlamaException(:final message) => message,
        _ => 'Could not load ${provider.label}.',
      };
    } finally {
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

    final history = <Message>[
      if (_supportsMultiTurn)
        for (final turn in _messages)
          Message(
            role: turn.role,
            content: [TextPart(text: turn.text)],
          ),
    ];
    final system = _systemPrompt.trim();
    final gemini = isGemini;
    final isLiteRtLm = _provider == PlaygroundProvider.liteRtLm;
    final cancellation = CancellationController();
    final reply = StringBuffer();
    _cancellation = cancellation;
    _messages.addAll([
      ChatTurn(Role.user, text),
      const ChatTurn(Role.model, ''),
    ]);
    _status = 'Generating…';
    _outputTokens = null;
    _latencyMs = null;
    _elapsed
      ..reset()
      ..start();
    _ticker = Timer.periodic(const Duration(milliseconds: 100), (_) {
      notifyListeners();
    });
    notifyListeners();

    bool isCurrent() => !_disposed && _cancellation == cancellation;

    Future<GenerateResult<Object?>> generate() => ai.generate<Object?, Object>(
      system: _supportsMultiTurn && system.isNotEmpty ? system : null,
      messages: history.isEmpty ? null : history,
      // Qwen3 uses the prompt's soft switch with its built-in template.
      prompt: isLiteRtLm ? '$text\n/no_think' : text,
      config: gemini
          ? GeminiOptions(
              temperature: _temperature,
              maxOutputTokens: _maxTokens,
            )
          : LlamaDartGenerationConfig(
              temperature: _temperature,
              maxTokens: _maxTokens,
              enableThinking: isLiteRtLm,
            ),
      cancel: cancellation.token,
      onChunk: (chunk) {
        if (!isCurrent()) return;
        reply.write(chunk.text);
        _messages.last = ChatTurn(Role.model, reply.toString());
        notifyListeners();
      },
    );

    final errorMessage = gemini
        ? 'Gemini request failed. Check your API key and connection.'
        : 'Generation failed.';
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
          gemini ? errorMessage : result.finishMessage ?? errorMessage,
        FinishReason.blocked => 'The model blocked this response.',
        _ when reply.isEmpty => 'The model returned no response text.',
        _ => 'Done.',
      };
    } catch (_) {
      status = errorMessage;
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
    _elapsed.stop();
    _latencyMs ??= _elapsed.elapsedMicroseconds / 1000;
    // An unanswered prompt should not become part of the next request.
    if (_messages.last.text.isEmpty) {
      _messages.removeRange(_messages.length - 2, _messages.length);
    }
    _status = status;
    notifyListeners();
  }

  void clearChat() {
    if (busy) return;
    _resetChat();
    notifyListeners();
  }

  void _resetChat() {
    _messages.clear();
    _outputTokens = null;
    _latencyMs = null;
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
    _cancellation?.cancel();
    prompt.dispose();
    apiKey.dispose();
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
