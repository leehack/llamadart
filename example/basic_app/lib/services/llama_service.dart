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

    final prompt = await _buildPrompt();
    String response = "";

    await for (final token in _service.generate(prompt)) {
      response += token;
    }

    final cleanResponse = _cleanResponse(response);
    _history.add(CliMessage(text: cleanResponse, role: CliRole.assistant));
    return cleanResponse;
  }

  /// Sends a message and returns a stream of tokens.
  Stream<String> chatStream(String text) async* {
    _history.add(CliMessage(text: text, role: CliRole.user));

    final prompt = await _buildPrompt();
    String fullResponse = "";

    await for (final token in _service.generate(prompt)) {
      fullResponse += token;
      yield token;
    }

    final cleanResponse = _cleanResponse(fullResponse);
    _history.add(CliMessage(text: cleanResponse, role: CliRole.assistant));
  }

  Future<String> _buildPrompt() async {
    final messages = _history
        .map((m) => LlamaChatMessage(
              role: m.role == CliRole.user ? 'user' : 'assistant',
              content: m.text,
            ))
        .toList();

    return await _service.applyChatTemplate(messages);
  }

  String _cleanResponse(String response) {
    return response
        .replaceAll('<|im_end|>', '')
        .replaceAll('<|im_start|>', '')
        .replaceAll('<|end_of_turn|>', '')
        .replaceAll('</s>', '')
        .trim();
  }

  /// Disposes the underlying engine resources.
  Future<void> dispose() async {
    await _service.dispose();
  }
}
