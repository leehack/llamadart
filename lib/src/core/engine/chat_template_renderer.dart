import '../exceptions.dart';
import '../llama_logger.dart';
import '../models/chat/chat_message.dart';
import '../models/chat/chat_template_result.dart';
import '../models/chat/content_part.dart';
import '../models/inference/tool_choice.dart';
import '../models/tools/tool_definition.dart';
import '../template/chat_template_engine.dart';
import '../template/media_placeholders.dart';

/// Loads model metadata for chat-template rendering.
typedef ChatTemplateMetadataLoader = Future<Map<String, String>> Function();

/// Tokenizes rendered prompts when callers request a token count.
typedef ChatTemplateTokenizer =
    Future<List<int>> Function(String text, {bool addSpecial});

/// Renders model chat templates for [LlamaEngine].
///
/// The public API stays on [LlamaEngine], while this helper owns metadata
/// preparation, response-format normalization, and optional token counting.
class ChatTemplateRenderer {
  const ChatTemplateRenderer._();

  /// Whether [messages] carry an image, audio or video part.
  static bool carriesMedia(List<LlamaChatMessage> messages) => messages.any(
    (message) => message.parts.any(
      (part) =>
          part is LlamaImageContent ||
          part is LlamaAudioContent ||
          part is LlamaVideoContent,
    ),
  );

  /// Renders a chat template and optionally counts prompt tokens.
  ///
  /// A non-empty [modelTemplate] replaces the model's `tokenizer.chat_template`
  /// and its `tool_use` variant, as llama.cpp's `--chat-template` does;
  /// [customTemplate] still takes precedence over both.
  ///
  /// A request that carries media is rendered with [chatPromptMediaMarker]
  /// where each part was. With [keepChatMarker] the prompt keeps it, for a
  /// backend that takes chat prompts. Otherwise the prompt is one that reads
  /// the same through `generate`: `<__media__>` where each part was, and a
  /// zero-width space in every other string `generate` would read as a part.
  /// A request without media is rendered as it is.
  static Future<LlamaChatTemplateResult> render({
    required ChatTemplateMetadataLoader loadMetadata,
    required ChatTemplateTokenizer tokenize,
    required List<LlamaChatMessage> messages,
    bool addAssistant = true,
    Map<String, dynamic>? jsonSchema,
    List<ToolDefinition>? tools,
    ToolChoice toolChoice = ToolChoice.auto,
    bool parallelToolCalls = false,
    bool enableThinking = true,
    Map<String, dynamic>? responseFormat,
    String? customTemplate,
    String? modelTemplate,
    bool includeTokenCount = true,
    Map<String, dynamic>? chatTemplateKwargs,
    DateTime? templateNow,
    bool keepChatMarker = false,
  }) async {
    Map<String, String> metadata = {};
    try {
      metadata = await loadMetadata();
    } catch (error) {
      LlamaLogger.instance.warning('Failed to read metadata: $error');
    }
    final String? templateSource;
    if (modelTemplate != null && modelTemplate.isNotEmpty) {
      templateSource = modelTemplate;
      metadata.remove('tokenizer.chat_template.tool_use');
    } else {
      templateSource = metadata['tokenizer.chat_template'];
    }

    final effectiveResponseFormat =
        responseFormat ??
        (jsonSchema == null
            ? null
            : {
                'type': 'json_schema',
                'json_schema': {'schema': jsonSchema},
              });

    final hasMedia = carriesMedia(messages);
    final result = ChatTemplateEngine.render(
      templateSource: templateSource,
      messages: messages,
      metadata: metadata,
      addAssistant: addAssistant,
      tools: tools,
      toolChoice: toolChoice,
      parallelToolCalls: parallelToolCalls,
      enableThinking: enableThinking,
      responseFormat: effectiveResponseFormat,
      customTemplate: customTemplate,
      chatTemplateKwargs: chatTemplateKwargs,
      now: templateNow,
      mediaMarker: hasMedia ? chatPromptMediaMarker : mtmdMediaMarker,
    );
    final prompt = hasMedia && !keepChatMarker
        ? chatPromptAsCallerPrompt(
            result.prompt,
            chatMarker: chatPromptMediaMarker,
          )
        : result.prompt;

    int? tokenCount;
    if (includeTokenCount) {
      try {
        final tokens = await tokenize(prompt, addSpecial: false);
        tokenCount = tokens.length;
      } on UnsupportedError catch (error) {
        LlamaLogger.instance.debug(
          'Skipping chat template token count because backend tokenization '
          'is unsupported: $error',
        );
      } on LlamaUnsupportedException catch (error) {
        LlamaLogger.instance.debug(
          'Skipping chat template token count because backend tokenization '
          'is unsupported: $error',
        );
      }
    }

    return LlamaChatTemplateResult(
      prompt: prompt,
      format: result.format,
      grammar: result.grammar,
      grammarLazy: result.grammarLazy,
      additionalStops: result.additionalStops,
      grammarTriggers: result.grammarTriggers,
      thinkingForcedOpen: result.thinkingForcedOpen,
      preservedTokens: result.preservedTokens,
      parser: result.parser,
      tokenCount: tokenCount,
    );
  }
}
