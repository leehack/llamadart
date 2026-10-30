import 'dart:convert';

import 'package:dinja/dinja.dart';

import '../../exceptions.dart';
import '../../models/chat/chat_message.dart';
import '../../models/chat/chat_role.dart';
import '../../models/chat/chat_template_result.dart';
import '../../models/chat/completion_chunk.dart';
import '../../models/inference/tool_choice.dart';
import '../../models/tools/tool_definition.dart';
import '../chat_format.dart';
import '../chat_parse_result.dart';
import '../chat_template_handler.dart';
import '../template_internal_metadata.dart';
import '../thinking_utils.dart';
import '../tool_call_fallback_parser.dart';
import '../tool_call_parsing_utils.dart';
import '../tool_call_grammar_utils.dart';

/// Handler for LFM2 and LFM2.5 (Liquid Foundation Model) formats.
///
/// Uses `<|tool_call_start|>` / `<|tool_call_end|>` special tokens for tool
/// calls. LFM2 templates wrap tool definitions in `<|tool_list_start|>` /
/// `<|tool_list_end|>`; LFM2.5 templates write a plain list.
class Lfm2Handler extends ChatTemplateHandler {
  /// Finds a possible tool-call list for the stream's content gate.
  static int toolCallOpening(String text, [int from = 0]) =>
      ToolCallParsingUtils.literalOpening(text, const [
        '<|tool_call_start|>',
      ], from);

  static final RegExp _forceJsonSchemaLineMarker = RegExp(
    r'force json schema\.\n',
    caseSensitive: false,
  );

  static final RegExp _forceJsonSchemaMarker = RegExp(
    r'force json schema\.',
    caseSensitive: false,
  );

  @override
  ChatFormat get format => ChatFormat.lfm2;

  @override
  List<String> get additionalStops => ['<|im_end|>'];

  @override
  List<String> getStops({bool hasTools = false, bool enableThinking = true}) {
    if (hasTools) {
      return const [];
    }

    return additionalStops;
  }

  @override
  List<String> get preservedTokens => const [
    '<|tool_call_start|>',
    '<|tool_call_end|>',
  ];

  @override
  LlamaChatTemplateResult render({
    required String templateSource,
    required List<LlamaChatMessage> messages,
    required Map<String, String> metadata,
    bool addAssistant = true,
    List<ToolDefinition>? tools,
    bool enableThinking = true,
  }) {
    final template = Template(templateSource);
    final hasTools = tools != null && tools.isNotEmpty;
    final toolChoice = metadata[internalToolChoiceMetadataKey];
    final toolChoiceRequired = toolChoice == ToolChoice.required.name;
    final parallelToolCalls =
        metadata[internalParallelToolCallsMetadataKey] == 'true';
    final hasForceJsonMarker = _shouldConstrainWithJsonTools(messages);
    final shouldConstrainWithJsonTools =
        hasTools && (hasForceJsonMarker || toolChoiceRequired);
    final effectiveMessages = hasForceJsonMarker
        ? _stripForceJsonSchemaMarker(messages)
        : messages;

    final prompt = renderTemplate(
      template,
      metadata: metadata,
      context: {
        'messages': templateMessages(
          effectiveMessages,
          templateSource: templateSource,
        ),
        'add_generation_prompt': addAssistant,
        'tools': _serializeToolsForTemplate(tools),
        'bos_token': metadata['tokenizer.ggml.bos_token'] ?? '',
        'eos_token': metadata['tokenizer.ggml.eos_token'] ?? '',
      },
    );

    return LlamaChatTemplateResult(
      prompt: prompt,
      format: format.index,
      grammar: shouldConstrainWithJsonTools
          ? _jsonGrammar(tools, parallelToolCalls: parallelToolCalls)
          : null,
      grammarLazy: shouldConstrainWithJsonTools && !toolChoiceRequired,
      additionalStops: getStops(
        hasTools: hasTools,
        enableThinking: enableThinking,
      ),
      preservedTokens: hasTools ? preservedTokens : const [],
      grammarTriggers: shouldConstrainWithJsonTools
          ? [
              const GrammarTrigger(
                type: 3,
                value: r'\s*<\|tool_call_start\|>\s*\[',
              ),
            ]
          : [],
    );
  }

  bool _shouldConstrainWithJsonTools(List<LlamaChatMessage> messages) {
    if (messages.isEmpty) {
      return false;
    }

    final first = messages.first;
    if (first.role != LlamaChatRole.system) {
      return false;
    }

    final content = first.content;
    return _forceJsonSchemaLineMarker.hasMatch(content) ||
        _forceJsonSchemaMarker.hasMatch(content);
  }

  List<LlamaChatMessage> _stripForceJsonSchemaMarker(
    List<LlamaChatMessage> messages,
  ) {
    if (messages.isEmpty) {
      return messages;
    }

    final first = messages.first;
    if (first.role != LlamaChatRole.system) {
      return messages;
    }

    var stripped = first.content.replaceFirst(_forceJsonSchemaLineMarker, '');
    if (stripped == first.content) {
      stripped = first.content.replaceFirst(_forceJsonSchemaMarker, '');
    }
    if (stripped == first.content) {
      return messages;
    }

    return <LlamaChatMessage>[
      first.copyWith(content: stripped),
      ...messages.skip(1),
    ];
  }

  /// Passes each tool as `name`, `description` and `parameters`, the shape
  /// LiquidAI's LFM2 and LFM2.5 model cards show. This deliberately differs
  /// from llama-server, which passes the OpenAI shape (`type`, `function`).
  List<Map<String, dynamic>>? _serializeToolsForTemplate(
    List<ToolDefinition>? tools,
  ) {
    if (tools == null || tools.isEmpty) {
      return null;
    }

    return tools
        .map(
          (tool) => <String, dynamic>{
            'name': tool.name,
            'description': tool.description,
            'parameters': tool.toJsonSchema(),
          },
        )
        .toList(growable: false);
  }

  @override
  ChatParseResult parse(
    String output, {
    bool isPartial = false,
    bool parseToolCalls = true,
    bool thinkingForcedOpen = false,
  }) {
    if (!parseToolCalls) {
      final thinking = extractThinking(
        output,
        thinkingForcedOpen: thinkingForcedOpen,
      );
      return ChatParseResult(
        content: thinking.content.trim(),
        reasoningContent: thinking.reasoning,
      );
    }

    final toolCalls = <LlamaCompletionChunkToolCall>[];
    var contentText = output;

    // LFM2 format:
    // <|tool_call_start|>[{"name":"fn","arguments":{...}}]<|tool_call_end|>
    final toolCallRegex = RegExp(
      r'<\|tool_call_start\|>\s*(.*?)\s*<\|tool_call_end\|>',
      dotAll: true,
    );

    final matches = toolCallRegex.allMatches(output);
    for (var i = 0; i < matches.length; i++) {
      final match = matches.elementAt(i);
      final payload = match.group(1)!;
      final parsedCalls = _parseCallList(payload, startIndex: toolCalls.length);
      if (parsedCalls != null) {
        toolCalls.addAll(parsedCalls);
      }
      contentText = contentText.replaceAll(match.group(0)!, '');
    }

    final thinking = extractThinking(
      contentText,
      thinkingForcedOpen: thinkingForcedOpen,
    );

    return ChatParseResult(
      content: thinking.content.trim(),
      reasoningContent: thinking.reasoning,
      toolCalls: toolCalls,
    );
  }

  @override
  String? buildGrammar(List<ToolDefinition>? tools) =>
      _jsonGrammar(tools, parallelToolCalls: false);

  String? _jsonGrammar(
    List<ToolDefinition>? tools, {
    required bool parallelToolCalls,
  }) => ToolCallGrammarUtils.buildWrappedArrayGrammar(
    tools: tools,
    prefix: '<|tool_call_start|>',
    suffix: '<|tool_call_end|>',
    allowParallelToolCalls: parallelToolCalls,
  );

  List<LlamaCompletionChunkToolCall>? _parseCallList(
    String payload, {
    required int startIndex,
  }) {
    try {
      return ToolCallParsingUtils.parseToolCallArray(
            ToolCallParsingUtils.decodeJsonValue(payload),
            startIndex: startIndex,
            failOnInvalidItem: false,
            assignFallbackIds: true,
          ) ??
          _PythonCallList(payload).parse(startIndex: startIndex) ??
          _parsePythonStyleToolCallList(payload, startIndex: startIndex);
    } on LlamaInferenceException {
      // Arguments the wire format refuses (too deep, not finite) are model
      // text, not a caller error, so they must not throw out of parse.
      return null;
    }
  }

  List<LlamaCompletionChunkToolCall>? _parsePythonStyleToolCallList(
    String payload, {
    required int startIndex,
  }) {
    var body = payload.trim();
    if (body.startsWith('[') && body.endsWith(']')) {
      body = body.substring(1, body.length - 1).trim();
    }
    if (body.isEmpty) {
      return const <LlamaCompletionChunkToolCall>[];
    }

    final parts = _splitPythonStyleToolCalls(body);
    if (parts.isEmpty) {
      return null;
    }

    final calls = <LlamaCompletionChunkToolCall>[];
    for (final part in parts) {
      final parsed = parseToolCallsFromLooseText(part);
      if (parsed.toolCalls.length != 1 || parsed.content.isNotEmpty) {
        return null;
      }
      final call = parsed.toolCalls.single;
      calls.add(
        LlamaCompletionChunkToolCall(
          index: startIndex + calls.length,
          id: call.id,
          type: call.type,
          function: call.function,
        ),
      );
    }

    return calls;
  }

  List<String> _splitPythonStyleToolCalls(String body) {
    final parts = <String>[];
    final buffer = StringBuffer();
    String? quote;
    var depth = 0;

    for (var i = 0; i < body.length; i++) {
      final ch = body[i];
      if (quote != null) {
        buffer.write(ch);
        if (ch == r'\' && i + 1 < body.length) {
          i++;
          buffer.write(body[i]);
        } else if (ch == quote) {
          quote = null;
        }
        continue;
      }

      if (ch == '"' || ch == "'") {
        quote = ch;
        buffer.write(ch);
      } else if (ch == '(' || ch == '[' || ch == '{') {
        depth++;
        buffer.write(ch);
      } else if (ch == ')' || ch == ']' || ch == '}') {
        if (depth > 0) {
          depth--;
        }
        buffer.write(ch);
      } else if (ch == ',' && depth == 0) {
        final part = buffer.toString().trim();
        if (part.isNotEmpty) {
          parts.add(part);
        }
        buffer.clear();
      } else {
        buffer.write(ch);
      }
    }

    final tail = buffer.toString().trim();
    if (tail.isNotEmpty) {
      parts.add(tail);
    }

    return parts;
  }
}

/// Reads the `[name(arg=value), ...]` list LFM2 writes, as llama.cpp's
/// `python_style_tool_calls` and `normalize_quotes_to_json` do: values are
/// Python or JSON literals, and strings decode their escapes.
class _PythonCallList {
  _PythonCallList(this._source);

  static final RegExp _nameAtStart = RegExp(r'[A-Za-z_][A-Za-z0-9_.-]*');
  static final RegExp _numberAtStart = RegExp(
    r'-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?',
  );
  static final RegExp _hexAtStart = RegExp(r'[0-9a-fA-F]{4}');

  /// One less than the wire format's limit, which counts the arguments map.
  static const int _maxValueDepth = 127;
  static const Map<String, Object?> _literals = {
    'True': true,
    'False': false,
    'None': null,
    'true': true,
    'false': false,
    'null': null,
  };
  static const Map<String, String> _escapes = {
    '"': '"',
    "'": "'",
    r'\': r'\',
    '/': '/',
    'b': '\b',
    'f': '\f',
    'n': '\n',
    'r': '\r',
    't': '\t',
  };

  final String _source;
  int _at = 0;
  int _depth = 0;

  /// The calls of the whole source, or null if it is not such a list.
  List<LlamaCompletionChunkToolCall>? parse({required int startIndex}) {
    try {
      final calls = <LlamaCompletionChunkToolCall>[];
      _skipSpace();
      _expect('[');
      _skipSpace();
      do {
        _skipSpace();
        calls.add(_call(startIndex + calls.length));
        _skipSpace();
      } while (_accept(','));
      _expect(']');
      _skipSpace();
      return _at == _source.length ? calls : null;
    } on FormatException {
      return null;
    }
  }

  LlamaCompletionChunkToolCall _call(int index) {
    final name = _matchName();
    _skipSpace();
    _expect('(');
    _skipSpace();
    final arguments = <String, dynamic>{};
    if (!_accept(')')) {
      do {
        _skipSpace();
        final key = _matchName();
        _skipSpace();
        _expect('=');
        _skipSpace();
        arguments[key] = _value();
        _skipSpace();
      } while (_accept(','));
      _expect(')');
    }
    return ToolCallParsingUtils.createFunctionToolCall(
      index: index,
      name: name,
      arguments: arguments,
    );
  }

  Object? _value() {
    if (_at >= _source.length) throw const FormatException();
    final char = _source[_at];
    if (char == '"' || char == "'") return _string(char);
    if (char == '[') return _list();
    if (char == '{') return _dict();
    final word = _nameAtStart.matchAsPrefix(_source, _at);
    if (word != null) {
      if (!_literals.containsKey(word[0])) throw const FormatException();
      _at = word.end;
      return _literals[word[0]];
    }
    final number = _numberAtStart.matchAsPrefix(_source, _at);
    if (number == null) throw const FormatException();
    _at = number.end;
    final value = jsonDecode(number[0]!) as num;
    if (!value.isFinite) throw const FormatException();
    return value;
  }

  String _string(String quote) {
    _at++;
    final buffer = StringBuffer();
    while (_at < _source.length) {
      final char = _source[_at++];
      if (char == quote) return buffer.toString();
      if (char != r'\') {
        buffer.write(char);
        continue;
      }
      if (_at >= _source.length) break;
      final escape = _source[_at++];
      if (escape == 'u') {
        final hex = _hexAtStart.matchAsPrefix(_source, _at);
        if (hex == null) throw const FormatException();
        buffer.writeCharCode(int.parse(hex[0]!, radix: 16));
        _at = hex.end;
        continue;
      }
      final decoded = _escapes[escape];
      if (decoded == null) throw const FormatException();
      buffer.write(decoded);
    }
    throw const FormatException();
  }

  List<Object?> _list() {
    _expect('[');
    _enterContainer();
    _skipSpace();
    final items = <Object?>[];
    if (!_accept(']')) {
      do {
        _skipSpace();
        items.add(_value());
        _skipSpace();
      } while (_accept(','));
      _expect(']');
    }
    _depth--;
    return items;
  }

  Map<String, Object?> _dict() {
    _expect('{');
    _enterContainer();
    _skipSpace();
    final entries = <String, Object?>{};
    if (!_accept('}')) {
      do {
        _skipSpace();
        if (_at >= _source.length) throw const FormatException();
        final quote = _source[_at];
        if (quote != '"' && quote != "'") throw const FormatException();
        final key = _string(quote);
        _skipSpace();
        _expect(':');
        _skipSpace();
        entries[key] = _value();
        _skipSpace();
      } while (_accept(','));
      _expect('}');
    }
    _depth--;
    return entries;
  }

  void _enterContainer() {
    if (++_depth > _maxValueDepth) throw const FormatException();
  }

  String _matchName() {
    final match = _nameAtStart.matchAsPrefix(_source, _at);
    if (match == null) throw const FormatException();
    _at = match.end;
    return match[0]!;
  }

  void _skipSpace() {
    while (_at < _source.length && ' \t\r\n'.contains(_source[_at])) {
      _at++;
    }
  }

  bool _accept(String char) {
    if (_at < _source.length && _source[_at] == char) {
      _at++;
      return true;
    }
    return false;
  }

  void _expect(String char) {
    if (!_accept(char)) throw const FormatException();
  }
}
