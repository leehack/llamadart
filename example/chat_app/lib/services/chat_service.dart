import 'package:llamadart/llamadart.dart';
import '../models/chat_message.dart';
import '../models/chat_settings.dart';

class ChatService {
  final LlamaService _llamaService = LlamaService();

  LlamaService get llama => _llamaService;

  Future<void> init(ChatSettings settings) async {
    if (settings.modelPath == null) throw Exception("Model path is null");

    if (settings.modelPath!.startsWith('http')) {
      await _llamaService.initFromUrl(
        settings.modelPath!,
        modelParams: ModelParams(
          gpuLayers: 99,
          preferredBackend: settings.preferredBackend,
          contextSize: settings.contextSize,
          logLevel: settings.logLevel,
        ),
      );
    } else {
      await _llamaService.init(
        settings.modelPath!,
        modelParams: ModelParams(
          gpuLayers: 99,
          preferredBackend: settings.preferredBackend,
          contextSize: settings.contextSize,
          logLevel: settings.logLevel,
        ),
      );
    }
  }

  Future<LlamaChatTemplateResult> buildPrompt(
    List<ChatMessage> messages,
    int maxTokens, {
    int safetyMargin = 1024,
  }) async {
    // Filter out UI placeholders
    final conversationMessages = messages
        .where(
          (m) =>
              m.text != 'Model loaded successfully! Ready to chat.' &&
              m.text != '...',
        )
        .toList();

    final List<LlamaChatMessage> finalMessages = [];
    int totalTokens = 0;

    for (int i = conversationMessages.length - 1; i >= 0; i--) {
      final m = conversationMessages[i];
      m.tokenCount ??= await _llamaService.getTokenCount(m.text);
      final tokens = m.tokenCount!;

      if (totalTokens + tokens > (maxTokens - safetyMargin)) {
        break;
      }

      totalTokens += tokens;
      finalMessages.insert(
        0,
        LlamaChatMessage(
          role: m.isUser ? 'user' : 'assistant',
          content: m.text,
        ),
      );
    }

    return await _llamaService.applyChatTemplate(finalMessages);
  }

  Stream<String> generate(
    List<LlamaChatMessage> messages,
    ChatSettings settings,
  ) {
    return _llamaService.chat(
      messages,
      params: GenerationParams(
        temp: settings.temperature,
        topK: settings.topK,
        topP: settings.topP,
        penalty: 1.1,
      ),
    );
  }

  String cleanResponse(String response) {
    return response.trim();
  }

  Future<void> dispose() async {
    await _llamaService.dispose();
  }

  void cancelGeneration() {
    _llamaService.cancelGeneration();
  }
}
