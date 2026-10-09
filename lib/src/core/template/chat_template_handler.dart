import 'package:dinja/dinja.dart';

import '../exceptions.dart';
import '../models/chat/chat_message.dart';
import '../models/chat/chat_template_result.dart';
import '../models/tools/tool_definition.dart';
import 'chat_format.dart';
import 'media_placeholders.dart';
import 'chat_parse_result.dart';
import 'template_caps.dart';
import 'template_internal_metadata.dart';
import 'template_render_context.dart';
import 'thinking_utils.dart';

export 'template_render_context.dart' show TemplateToolCallSerialization;

/// Abstract base class for per-format chat template handlers.
///
/// Each handler encapsulates format-specific logic for:
/// - Rendering messages into a prompt (via Jinja template)
/// - Parsing raw LLM output into structured content + tool calls
/// - Building GBNF grammar strings for constrained generation
///
/// Handlers are stateless singletons — all state lives in the arguments.
abstract class ChatTemplateHandler {
  /// The chat format this handler supports.
  ChatFormat get format;

  /// Start tag used for reasoning/thinking extraction.
  String get thinkingStartTag => '<think>';

  /// End tag used for reasoning/thinking extraction.
  String get thinkingEndTag => '</think>';

  /// Static additional stop sequences for backward compatibility.
  ///
  /// Prefer [getStops] for context-aware stop sequences.
  List<String> get additionalStops;

  /// Tool-call serialization shape expected by this handler's Jinja template.
  TemplateToolCallSerialization get toolCallSerialization =>
      TemplateToolCallSerialization.none;

  /// Builds the `messages` value passed to Jinja.
  ///
  /// Handlers should use this instead of calling [LlamaChatMessage.toJson]
  /// directly so template-specific tool-call shapes are applied only at the
  /// render-context boundary. Pass the [templateSource] being rendered:
  /// tool-call arguments become objects when [TemplateCaps] detects that it
  /// reads them as objects, and string content becomes a text part when it
  /// reads content only as parts, as llama.cpp does. A handler that builds
  /// typed parts itself passes `typedContent: false` to keep string content.
  /// With [multimodal], each media part becomes [mediaMarker] in the message
  /// text.
  List<Map<String, dynamic>> templateMessages(
    List<LlamaChatMessage> messages, {
    bool multimodal = false,
    String mediaMarker = mtmdMediaMarker,
    String? templateSource,
    bool typedContent = true,
  }) {
    final caps = templateSource == null
        ? null
        : TemplateCaps.detect(templateSource);
    try {
      return TemplateRenderContext.messagesForTemplate(
        messages,
        toolCallSerialization: toolCallSerialization,
        multimodal: multimodal,
        mediaMarker: mediaMarker,
        objectArguments: caps?.supportsObjectArguments ?? false,
        typedContentOnly:
            typedContent &&
            caps != null &&
            caps.supportsTypedContent &&
            !caps.supportsStringContent,
      );
    } catch (e, stackTrace) {
      if (toolCallSerialization.isEmpty) rethrow;
      final wrapped = LlamaInferenceException(
        'Failed to build render context for $format chat template while '
        'applying template-specific tool-call serialization. Verify tool-call '
        'arguments are JSON objects compatible with the selected template.',
        {'causeType': e.runtimeType.toString(), 'cause': e.toString()},
      );
      Error.throwWithStackTrace(wrapped, stackTrace);
    }
  }

  /// Returns context-aware stop sequences for this format.
  ///
  /// Matches llama.cpp's per-handler stop logic where stops vary based on
  /// whether tools are provided and whether thinking is enabled.
  ///
  /// Override in handlers that need context-dependent stops.
  List<String> getStops({bool hasTools = false, bool enableThinking = true}) {
    return additionalStops;
  }

  /// Returns preserved tokens for this format.
  ///
  /// Preserved tokens prevent grammar-constrained generation from consuming
  /// format-critical tokens. Override in handlers that need them.
  List<String> get preservedTokens => const [];

  /// Renders messages into a complete [LlamaChatTemplateResult].
  ///
  /// This calls the Jinja template with format-specific context setup,
  /// and optionally generates grammar + trigger info for tool calls.
  ///
  /// Parameters:
  /// - [templateSource]: The Jinja template string from model metadata
  /// - [messages]: The conversation history
  /// - [metadata]: Model metadata (for bos/eos tokens, etc.)
  /// - [addAssistant]: Whether to add generation prompt
  /// - [tools]: Optional tool definitions for function calling
  /// - [enableThinking]: Whether thinking/reasoning is enabled
  LlamaChatTemplateResult render({
    required String templateSource,
    required List<LlamaChatMessage> messages,
    required Map<String, String> metadata,
    bool addAssistant = true,
    List<ToolDefinition>? tools,
    bool enableThinking = true,
  });

  /// Parses raw LLM output into structured [ChatParseResult].
  ///
  /// Extracts content, reasoning/thinking, and tool calls from the
  /// raw text using format-specific delimiters and patterns.
  ///
  /// Parameters:
  /// - [output]: The raw LLM output text
  /// - [isPartial]: Whether this is a partial/streaming result
  /// - [parseToolCalls]: Whether to extract tool calls (false = content only)
  /// - [thinkingForcedOpen]: Whether thinking was force-opened in prompt
  ChatParseResult parse(
    String output, {
    bool isPartial = false,
    bool parseToolCalls = true,
    bool thinkingForcedOpen = false,
  });

  /// Builds a GBNF grammar string for constraining tool call output.
  ///
  /// Returns `null` if [tools] is null/empty (no grammar needed).
  /// Each format wraps tool call JSON differently (e.g., `<tool_call>` tags
  /// for Hermes, `[TOOL_CALLS]` prefix for Mistral).
  String? buildGrammar(List<ToolDefinition>? tools);

  /// Renders [template] with [context] plus llama.cpp-style extra globals.
  ///
  /// This injects `chat_template_kwargs` values encoded by
  /// [ChatTemplateEngine]/[LlamaEngine] through metadata.
  String renderTemplate(
    Template template, {
    required Map<String, String> metadata,
    required Map<String, dynamic> context,
  }) {
    return template.render(<String, dynamic>{
      ...chatTemplateKwargsFromMetadata(metadata),
      ...context,
    });
  }

  /// Renders a request that carries media for a template that reads both
  /// string and typed content.
  ///
  /// Each image, audio or video part becomes [mediaMarker] in the message
  /// text, where the part was, as llama.cpp renders it. The template's own
  /// placeholder for a typed media part is not written, and a placeholder
  /// string in message text stays text.
  LlamaChatTemplateResult renderWithMultimodalContent({
    required String templateSource,
    required List<LlamaChatMessage> messages,
    required Map<String, String> metadata,
    bool addAssistant = true,
    List<ToolDefinition>? tools,
    bool enableThinking = true,
    String mediaMarker = mtmdMediaMarker,
  }) {
    final template = Template(templateSource);
    var prompt = renderTemplate(
      template,
      metadata: metadata,
      context: {
        'messages': templateMessages(
          messages,
          multimodal: true,
          mediaMarker: mediaMarker,
          templateSource: templateSource,
        ),
        'add_generation_prompt': addAssistant,
        'tools': tools?.map((t) => t.toJson()).toList(),
        'enable_thinking': enableThinking,
        'bos_token': metadata['tokenizer.ggml.bos_token'] ?? '',
        'eos_token': metadata['tokenizer.ggml.eos_token'] ?? '',
      },
    );

    var thinkingForcedOpen = false;
    if (isThinkingForcedOpen(prompt, startTag: thinkingStartTag.trimRight())) {
      if (!enableThinking) {
        prompt = '${prompt.trimRight()}$thinkingEndTag\n';
      } else {
        thinkingForcedOpen = true;
      }
    }

    final hasTools = tools != null && tools.isNotEmpty;

    return LlamaChatTemplateResult(
      prompt: prompt,
      format: format.index,
      grammar: buildGrammar(tools),
      grammarLazy: hasTools,
      additionalStops: getStops(
        hasTools: hasTools,
        enableThinking: enableThinking,
      ),
      thinkingForcedOpen: thinkingForcedOpen,
    );
  }

  /// Resolves a caller-provided template `now` value or falls back to current
  /// wall-clock time.
  DateTime resolveTemplateNow(Map<String, String> metadata) {
    final rawNow = metadata[internalTemplateNowMetadataKey];
    if (rawNow != null && rawNow.trim().isNotEmpty) {
      final parsed = DateTime.tryParse(rawNow);
      if (parsed != null) {
        return parsed;
      }
    }
    return DateTime.now();
  }
}

/// Optional handler contract for output formats whose argument decoding depends
/// on the tool JSON schemas supplied for the completion request.
///
/// [ChatTemplateEngine] uses this contract when schemas are available while
/// retaining [ChatTemplateHandler.parse] for callers that only have raw output.
abstract interface class ToolSchemaAwareChatTemplateHandler {
  /// Parses [output] using [tools] to validate names, required properties, and
  /// schema-directed argument types.
  ChatParseResult parseWithTools(
    String output, {
    List<ToolDefinition>? tools,
    bool isPartial = false,
    bool parseToolCalls = true,
    bool thinkingForcedOpen = false,
  });
}
