import 'package:llamadart/llamadart.dart';
import '../models.dart';

/// Service for interacting with the Llama engine in a CLI environment.
class LlamaCliService {
  final LlamaService _service = LlamaService();
  final List<CliMessage> _history = [];

  /// Initializes the engine with the given [modelPath].
  Future<void> init(
    String modelPath, {
    List<LoraAdapterConfig> loras = const [],
  }) async {
    await _service.init(
      modelPath,
      modelParams: ModelParams(
        gpuLayers: 99,
        logLevel: LlamaLogLevel.error,
        loras: loras,
      ),
    );
  }

  /// Sends a message and returns the full response.
  Future<String> chat(String text) async {
    _history.add(CliMessage(text: text, role: CliRole.user));

    final messages = _getChatHistory();
    String response = "";

    await for (final token in _service.chat(messages)) {
      response += token;
    }

    final cleanResponse = response.trim();
    _history.add(CliMessage(text: cleanResponse, role: CliRole.assistant));
    return cleanResponse;
  }

  /// Sends a message and returns a stream of tokens.
  Stream<String> chatStream(String text) async* {
    _history.add(CliMessage(text: text, role: CliRole.user));

    final messages = _getChatHistory();
    String fullResponse = "";

    await for (final token in _service.chat(messages)) {
      fullResponse += token;
      yield token;
    }

    final cleanResponse = fullResponse.trim();
    _history.add(CliMessage(text: cleanResponse, role: CliRole.assistant));
  }

  List<LlamaChatMessage> _getChatHistory() {
    return _history
        .map((m) => LlamaChatMessage(
              role: m.role == CliRole.user ? 'user' : 'assistant',
              content: m.text,
            ))
        .toList();
  }

  /// Disposes the underlying engine resources.
  Future<void> dispose() async {
    await _service.dispose();
  }
}
