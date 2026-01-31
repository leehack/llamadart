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

  Future<String> buildPrompt(
    List<ChatMessage> messages,
    String modelPath,
    int maxTokens, {
    int safetyMargin = 1024,
  }) async {
    final lowerPath = modelPath.toLowerCase();
    final isGemma = lowerPath.contains('gemma');
    final assistantRole = isGemma ? 'model' : 'assistant';

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
      // Use cached token count if available
      m.tokenCount ??= await _llamaService.getTokenCount(m.text);
      final tokens = m.tokenCount!;

      if (totalTokens + tokens > (maxTokens - safetyMargin)) {
        break;
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

    return await _llamaService.applyChatTemplate(finalMessages);
  }

  Stream<String> generate(
    String prompt,
    ChatSettings settings,
    List<String> stopSequences,
  ) {
    return _llamaService.generate(
      prompt,
      params: GenerationParams(
        temp: settings.temperature,
        topK: settings.topK,
        topP: settings.topP,
        penalty: 1.1,
        stopSequences: [
          ...stopSequences,
          '<|user|>',
          '<|im_end|>',
          '<|im_start|>',
          '<|end_of_turn|>',
          '### Instruction:',
        ],
      ),
    );
  }

  String cleanResponse(String response) {
    var cleanText = response;

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
        caseSensitive: false,
      ),
      "",
    );

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
      RegExp(
        r'\n(?:[\|\><\s]*)?(model|assistant|user|system|thought):',
        caseSensitive: false,
      ),
      "\n",
    );

    cleanText = cleanText.replaceFirst(
      RegExp(r'(?:\<|\||\>|im_|end_|start_)+$'),
      "",
    );

    return cleanText.trim();
  }

  Future<void> dispose() async {
    await _llamaService.dispose();
  }

  void cancelGeneration() {
    _llamaService.cancelGeneration();
  }

  List<String> detectStopSequences(Map<String, String> metadata) {
    final stops = <String>[];
    final template = metadata['tokenizer.chat_template']?.toLowerCase() ?? "";
    if (template.contains('im_end')) stops.add('<|im_end|>');
    if (template.contains('end_of_turn')) stops.add('<end_of_turn>');
    if (template.contains('eot_id')) stops.add('<|eot_id|>');
    if (template.contains('assistant')) stops.add('<|assistant|>');

    final arch = metadata['general.architecture']?.toLowerCase() ?? "";
    if (arch.contains('llama')) {
      stops.add('</s>');
      stops.add('<|eot_id|>');
    }
    if (arch.contains('gemma')) stops.add('<end_of_turn>');
    return stops.toSet().toList();
  }
}
