import 'chat_format.dart';
import 'chat_template_handler.dart';
import 'handlers/apertus_handler.dart';
import 'handlers/apriel15_handler.dart';
import 'handlers/cohere2_moe_handler.dart';
import 'handlers/command_r7b_handler.dart';
import 'handlers/deepseek_dsml_handler.dart';
import 'handlers/deepseek_r1_handler.dart';
import 'handlers/deepseek_v3_handler.dart';
import 'handlers/exaone_moe_handler.dart';
import 'handlers/firefunction_v2_handler.dart';
import 'handlers/function_gemma_handler.dart';
import 'handlers/functionary_v31_llama31_handler.dart';
import 'handlers/functionary_v32_handler.dart';
import 'handlers/gemma4_handler.dart';
import 'handlers/gemma_handler.dart';
import 'handlers/generic_handler.dart';
import 'handlers/glm45_handler.dart';
import 'handlers/gpt_oss_handler.dart';
import 'handlers/granite_handler.dart';
import 'handlers/hermes_handler.dart';
import 'handlers/hunyuan_v3_handler.dart';
import 'handlers/kimi_k2_handler.dart';
import 'handlers/kimi_k3_handler.dart';
import 'handlers/laguna_handler.dart';
import 'handlers/lfm2_handler.dart';
import 'handlers/llama3_handler.dart';
import 'handlers/magistral_handler.dart';
import 'handlers/minicpm5_handler.dart';
import 'handlers/minimax_m1_m3_handler.dart';
import 'handlers/minimax_m2_handler.dart';
import 'handlers/ministral_handler.dart';
import 'handlers/mistral_handler.dart';
import 'handlers/muse_glimmer_handler.dart';
import 'handlers/nemotron_v2_handler.dart';
import 'handlers/qwen3_coder_xml_handler.dart';
import 'handlers/seed_oss_handler.dart';
import 'handlers/solar_open_handler.dart';
import 'handlers/translate_gemma_handler.dart';
import 'handlers/xiaomi_mimo_handler.dart';

/// How one [ChatFormat] is detected from a template and which handler
/// renders and parses it.
final class ChatFormatRegistration {
  /// Registers [format], created by [createHandler] and matched by [detect].
  const ChatFormatRegistration(this.format, this.createHandler, {this.detect});

  /// The format this registration describes.
  final ChatFormat format;

  /// Creates the handler for [format].
  final ChatTemplateHandler Function() createHandler;

  /// Whether a template source is in [format], or null for a format the
  /// engine selects itself and no template detects.
  final bool Function(String templateSource)? detect;
}

/// Every [ChatFormat], each exactly once, in detection priority order: the
/// first registration whose [ChatFormatRegistration.detect] matches a
/// template wins, following llama.cpp's order. A detector placed earlier
/// shadows every later one whose markers it shares.
final List<ChatFormatRegistration>
chatFormatRegistrations = List.unmodifiable(<ChatFormatRegistration>[
  // Keep Kimi K3 separate from Kimi K2: K3 uses XTML tags and typed
  // arguments rather than K2's tool-call-section tokens.
  ChatFormatRegistration(
    ChatFormat.kimiK3,
    KimiK3Handler.new,
    detect: (s) =>
        _hasAll(s, const ['<|open|>', '<|close|>', '<|end_of_msg|>']),
  ),
  // Recipient channels and ATEM calls.
  ChatFormatRegistration(
    ChatFormat.museGlimmer,
    MuseGlimmerHandler.new,
    detect: (s) => _hasAll(s, const ['<atem:function_calls>', '<|eom|>']),
  ),
  // Before Hermes: the namespaced envelope contains a literal <tool_call>.
  ChatFormatRegistration(
    ChatFormat.minimaxM3,
    MinimaxM3Handler.new,
    detect: (s) =>
        _hasAll(s, const [']<]minimax[>[', '<tool_call>', '<invoke name=']),
  ),
  // DeepSeek V3.2/V4 DSML family. The marker is assembled from a Jinja
  // variable, so detecting only literal rendered tags misses every variant.
  ChatFormatRegistration(
    ChatFormat.deepseekV32,
    DeepseekV32Handler.new,
    detect: (s) => _hasAll(s, const ['dsml_token', 'DSML', 'function_calls']),
  ),
  ChatFormatRegistration(
    ChatFormat.deepseekV4,
    DeepseekV4Handler.new,
    detect: (s) => _hasAll(s, const ['dsml_token', 'DSML', 'tool_calls']),
  ),
  // Newline-delimited JSON tool-call envelope.
  ChatFormatRegistration(
    ChatFormat.minimaxM1,
    MinimaxM1Handler.new,
    detect: (s) => _hasAll(s, const [
      '<begin_of_document>',
      '<beginning_of_sentence>',
      '<tool_calls>',
    ]),
  ),
  // Shares GLM-style argument tags but uses explicit assistant and
  // tool-response turns and </assistant> as a stop.
  ChatFormatRegistration(
    ChatFormat.laguna,
    LagunaHandler.new,
    detect: (s) => _hasAll(s, const [
      '<assistant>',
      '</assistant>',
      '<tool_response>',
      '<arg_key>',
      '<arg_value>',
    ]),
  ),
  ChatFormatRegistration(
    ChatFormat.deepseekV3,
    DeepseekV3Handler.new,
    detect: (s) => s.contains(
      "message['prefix'] is defined and message['prefix'] and thinking",
    ),
  ),
  ChatFormatRegistration(
    ChatFormat.deepseekR1,
    DeepseekR1Handler.new,
    detect: (s) => s.contains('<｜tool▁calls▁begin｜>'),
  ),
  // Cohere2 MoE / North Code, before Command R7B: both use
  // <|START_ACTION|>, but START_TEXT is unique to the newer template.
  ChatFormatRegistration(
    ChatFormat.cohere2Moe,
    Cohere2MoeHandler.new,
    detect: (s) => _hasAll(s, const ['<|START_TEXT|>', '<|START_ACTION|>']),
  ),
  ChatFormatRegistration(
    ChatFormat.minicpm5,
    MiniCpm5Handler.new,
    detect: (s) => _hasAll(s, const [
      'Tool usage guidelines:',
      '<function name="',
      '<param name="',
    ]),
  ),
  ChatFormatRegistration(
    ChatFormat.commandR7B,
    CommandR7BHandler.new,
    detect: (s) => s.contains('<|END_THINKING|><|START_ACTION|>'),
  ),
  ChatFormatRegistration(
    ChatFormat.granite,
    GraniteHandler.new,
    detect: (s) => _hasAll(s, const ['elif thinking', '<|tool_call|>']),
  ),
  ChatFormatRegistration(
    ChatFormat.glm45,
    Glm45Handler.new,
    detect: (s) =>
        _hasAll(s, const ['[gMASK]<sop>', '<arg_key>', '<arg_value>']),
  ),
  ChatFormatRegistration(
    ChatFormat.hunyuanV3,
    HunyuanV3Handler.new,
    detect: (s) =>
        _hasAll(s, const ['<｜hy_User{}｜>', '<tool_sep{}>', '<arg_key{}>']),
  ),
  // Qwen3.6 uses the same generated `<function=...><parameter=...>`
  // envelope, but its template describes the shape through its XML
  // tool-call instruction instead of `<function>` and `<parameters>`
  // declaration tags.
  ChatFormatRegistration(
    ChatFormat.qwen3CoderXml,
    Qwen3CoderXmlHandler.new,
    detect: (s) =>
        _hasAll(s, const ['<tool_call>', '<function=', '<parameter=']) &&
        (_hasAll(s, const ['<function>', '<parameters>']) ||
            s.contains('Function calls MUST follow the specified format')),
  ),
  ChatFormatRegistration(
    ChatFormat.xiaomiMimo,
    XiaomiMimoHandler.new,
    detect: (s) => _hasAll(s, const [
      '<tools>',
      '# Tools',
      '</tools>',
      '<tool_calls>',
      '</tool_calls>',
      '<tool_response>',
    ]),
  ),
  ChatFormatRegistration(
    ChatFormat.exaoneMoe,
    ExaoneMoeHandler.new,
    detect: (s) =>
        _hasAll(s, const ['<tool_call>', '<tool_result>', '<|tool_declare|>']),
  ),
  // Hermes 2 Pro / Qwen 2.5/3. Every <tool_call> family above must stay
  // above it.
  ChatFormatRegistration(
    ChatFormat.hermes,
    HermesHandler.new,
    detect: (s) => s.contains('<tool_call>'),
  ),
  ChatFormatRegistration(
    ChatFormat.gptOss,
    GptOssHandler.new,
    detect: (s) => s.contains('<|channel|>'),
  ),
  ChatFormatRegistration(
    ChatFormat.seedOss,
    SeedOssHandler.new,
    detect: (s) => s.contains('<seed:think>'),
  ),
  ChatFormatRegistration(
    ChatFormat.nemotronV2,
    NemotronV2Handler.new,
    detect: (s) => s.contains('<SPECIAL_10>'),
  ),
  ChatFormatRegistration(
    ChatFormat.apertus,
    ApertusHandler.new,
    detect: (s) => _hasAll(s, const ['<|system_start|>', '<|tools_prefix|>']),
  ),
  // LFM2 wraps its tool list in <|tool_list_start|>/<|tool_list_end|>;
  // LFM2.5 writes a plain "List of tools: [...]". llama.cpp routes both.
  ChatFormatRegistration(
    ChatFormat.lfm2,
    Lfm2Handler.new,
    detect: (s) =>
        _hasAll(s, const ['<|tool_list_start|>', '<|tool_list_end|>']) ||
        (s.contains('List of tools: [') && !s.contains('<|tool_list_start|>')),
  ),
  ChatFormatRegistration(
    ChatFormat.minimaxM2,
    MinimaxM2Handler.new,
    detect: (s) => _hasAll(s, const [']~!b[', ']~b]']),
  ),
  ChatFormatRegistration(
    ChatFormat.kimiK2,
    KimiK2Handler.new,
    detect: (s) => _hasAll(s, const [
      '<|im_system|>tool_declare<|im_middle|>',
      '<|tool_calls_section_begin|>',
      '## Return of',
    ]),
  ),
  ChatFormatRegistration(
    ChatFormat.apriel15,
    Apriel15Handler.new,
    detect: (s) => _hasAll(s, const [
      '<thinking>',
      '</thinking>',
      '<available_tools>',
      '<|assistant|>',
      '<|tool_result|>',
      '<tool_calls>[',
      ']</tool_calls>',
    ]),
  ),
  ChatFormatRegistration(
    ChatFormat.solarOpen,
    SolarOpenHandler.new,
    detect: (s) => _hasAll(s, const [
      '<|tool_response:begin|>',
      '<|tool_response:name|>',
      '<|tool_response:result|>',
    ]),
  ),
  // Before Gemma 3, whose turn markers FunctionGemma templates also use.
  ChatFormatRegistration(
    ChatFormat.functionGemma,
    FunctionGemmaHandler.new,
    detect: (s) =>
        s.contains('<start_function_declaration>') ||
        s.contains('<start_function_call>') ||
        s.contains('<start_function_response>'),
  ),
  ChatFormatRegistration(
    ChatFormat.translateGemma,
    TranslateGemmaHandler.new,
    detect: (s) =>
        _hasAll(s, const ['[source_lang_code]', '[target_lang_code]']),
  ),
  ChatFormatRegistration(
    ChatFormat.functionaryV32,
    FunctionaryV32Handler.new,
    detect: (s) => s.contains('>>>all'),
  ),
  ChatFormatRegistration(
    ChatFormat.firefunctionV2,
    FirefunctionV2Handler.new,
    detect: (s) => s.contains(' functools['),
  ),
  ChatFormatRegistration(
    ChatFormat.functionaryV31Llama31,
    FunctionaryV31Llama31Handler.new,
    detect: (s) => _hasAll(s, const ['<|start_header_id|>', '<function=']),
  ),
  ChatFormatRegistration(
    ChatFormat.llama3,
    Llama3Handler.new,
    detect: (s) => s.contains('<|start_header_id|>ipython<|end_header_id|>'),
  ),
  // Ministral templates also carry [THINK] and [TOOL_CALLS], so Ministral
  // precedes Magistral and Mistral Nemo.
  ChatFormatRegistration(
    ChatFormat.ministral,
    MinistralHandler.new,
    detect: (s) =>
        _hasAll(s, const ['[SYSTEM_PROMPT]', '[TOOL_CALLS]', '[ARGS]']),
  ),
  ChatFormatRegistration(
    ChatFormat.magistral,
    MagistralHandler.new,
    detect: (s) => _hasAll(s, const ['[THINK]', '[/THINK]']),
  ),
  ChatFormatRegistration(
    ChatFormat.mistralNemo,
    MistralHandler.new,
    detect: (s) => s.contains('[TOOL_CALLS]'),
  ),
  ChatFormatRegistration(
    ChatFormat.gemma,
    GemmaHandler.new,
    detect: (s) => s.contains('<start_of_turn>') && !s.contains('<|im_start|>'),
  ),
  ChatFormatRegistration(
    ChatFormat.gemma4,
    Gemma4Handler.new,
    detect: (s) => _hasAll(s, const ['<|turn>', '<turn|>']),
  ),
  const ChatFormatRegistration(
    ChatFormat.llama3BuiltinTools,
    Llama3Handler.new,
  ),
  ChatFormatRegistration(
    ChatFormat.pegSimple,
    () => _withoutTemplateToolCalls(ChatFormat.pegSimple),
  ),
  ChatFormatRegistration(
    ChatFormat.pegNative,
    () => _withoutTemplateToolCalls(ChatFormat.pegNative),
  ),
  ChatFormatRegistration(
    ChatFormat.pegConstructed,
    () => _withoutTemplateToolCalls(ChatFormat.pegConstructed),
  ),
  const ChatFormatRegistration(ChatFormat.generic, GenericHandler.new),
  ChatFormatRegistration(
    ChatFormat.contentOnly,
    () => _withoutTemplateToolCalls(ChatFormat.contentOnly),
  ),
]);

/// The registration of [format].
ChatFormatRegistration chatFormatRegistration(ChatFormat format) =>
    _registrationsByFormat[format]!;

final Map<ChatFormat, ChatFormatRegistration> _registrationsByFormat = {
  for (final registration in chatFormatRegistrations)
    registration.format: registration,
};

bool _hasAll(String source, List<String> markers) =>
    markers.every(source.contains);

/// A generic handler for [format] that serializes no tool calls into the
/// template.
GenericHandler _withoutTemplateToolCalls(ChatFormat format) => GenericHandler(
  format: format,
  toolCallSerialization: TemplateToolCallSerialization.none,
);
