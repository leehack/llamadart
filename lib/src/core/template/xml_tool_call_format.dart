import '../models/tools/tool_definition.dart';
import '../models/chat/completion_chunk.dart';
import 'chat_parse_result.dart';
import 'thinking_utils.dart';
import 'tool_call_parsing_utils.dart';

/// Describes the XML-style tool call format used by several models.
///
/// Retains the semantics of llama.cpp's former `xml_tool_call_format` struct.
/// Shared by MiniMax M2, Qwen3 Coder XML, Apriel, Seed OSS, and legacy
/// format definitions.
class XmlToolCallFormat {
  /// Opening scope tag (e.g., `<minimax:tool_call>`).
  final String scopeStart;

  /// Start of a tool call (e.g., `<invoke name="`).
  final String toolStart;

  /// Separator between tool name and arguments (e.g., `">`).
  final String toolSep;

  /// Start of a key (e.g., `<parameter name="`).
  final String keyStart;

  /// Separator between key and value (e.g., `">`).
  final String keyValSep;

  /// End of a value (e.g., `</parameter>`).
  final String valEnd;

  /// End of a tool call (e.g., `</invoke>`).
  final String toolEnd;

  /// Closing scope tag (e.g., `</minimax:tool_call>`).
  final String scopeEnd;

  /// How argument values are decoded.
  ///
  /// `true` preserves raw strings, `false` requires JSON, and `null` accepts
  /// either form. This matches the three-state upstream field that preceded
  /// llama.cpp's format-specific PEG parsers.
  final bool? rawArgval;

  /// Whether to trim whitespace from raw argument values.
  final bool trimRawArgval;

  /// Override for the last value's end marker.
  ///
  /// An empty string means the tool-end marker immediately follows the final
  /// value.
  final String? lastValEnd;

  /// Override for the last tool's end marker.
  final String? lastToolEnd;

  /// Whether tool calls can appear inside thinking blocks.
  final bool allowToolcallInThink;

  /// Creates a [XmlToolCallFormat] definition.
  const XmlToolCallFormat({
    required this.scopeStart,
    required this.toolStart,
    required this.toolSep,
    required this.keyStart,
    required this.keyValSep,
    required this.valEnd,
    required this.toolEnd,
    required this.scopeEnd,
    this.rawArgval,
    this.trimRawArgval = false,
    this.lastValEnd,
    this.lastToolEnd,
    this.allowToolcallInThink = false,
  });

  /// Standard XML format (e.g. Qwen 2.5/3 Coder).
  static const qwen3Coder = XmlToolCallFormat(
    scopeStart: '<tool_call>',
    toolStart: '<function=',
    toolSep: '>',
    keyStart: '<parameter=',
    keyValSep: '>',
    valEnd: '</parameter>',
    toolEnd: '</function>',
    scopeEnd: '</tool_call>',
    trimRawArgval: true,
    allowToolcallInThink: true,
  );

  /// Kimi K2 format.
  static const kimiK2 = XmlToolCallFormat(
    scopeStart: '<|tool_calls_section_begin|>',
    toolStart: '<|tool_call_begin|>',
    toolSep: '<|tool_call_argument_begin|>{',
    keyStart: '"',
    keyValSep: '": ',
    valEnd: ', ',
    toolEnd: '}<|tool_call_end|>',
    scopeEnd: '<|tool_calls_section_end|>',
    rawArgval: false,
    lastValEnd: '',
  );

  /// MiniMax M2 format.
  static const minimaxM2 = XmlToolCallFormat(
    scopeStart: '<minimax:tool_call>\n',
    toolStart: '<invoke name="',
    toolSep: '">\n',
    keyStart: '<parameter name="',
    keyValSep: '">',
    valEnd: '</parameter>\n',
    toolEnd: '</invoke>\n',
    scopeEnd: '</minimax:tool_call>',
  );

  /// MiniCPM5 XML function-call format.
  static const minicpm5 = XmlToolCallFormat(
    scopeStart: '',
    toolStart: '<function name="',
    toolSep: '">',
    keyStart: '<param name="',
    keyValSep: '">',
    valEnd: '</param>',
    toolEnd: '</function>',
    scopeEnd: '',
  );

  /// Seed-OSS format.
  static const seedOss = XmlToolCallFormat(
    scopeStart: '<seed:tool_call>',
    toolStart: '<function=',
    toolSep: '>',
    keyStart: '<parameter=',
    keyValSep: '>',
    valEnd: '</parameter>',
    toolEnd: '</function>',
    scopeEnd: '</seed:tool_call>',
  );

  /// Apriel 1.5 format.
  static const apriel15 = XmlToolCallFormat(
    scopeStart: '<tool_calls>[',
    toolStart: '{"name": "',
    toolSep: '", "arguments": {',
    keyStart: '"',
    keyValSep: '": ',
    valEnd: ', ',
    toolEnd: '}, ',
    scopeEnd: ']</tool_calls>',
    rawArgval: false,
    lastValEnd: '}',
    lastToolEnd: '}',
  );

  /// Xiaomi MiMo format.
  static const xiaomiMimo = XmlToolCallFormat(
    scopeStart: '',
    toolStart: '<tool_call>\n{"name": "',
    toolSep: '", "arguments": {',
    keyStart: '"',
    keyValSep: '": ',
    valEnd: ', ',
    toolEnd: '}\n</tool_call>',
    scopeEnd: '',
    rawArgval: false,
    lastValEnd: '',
  );

  /// Generic fallback XML format.
  static const generic = XmlToolCallFormat(
    scopeStart: '',
    toolStart: '<tool_code>',
    toolSep: '\n',
    keyStart: '<',
    keyValSep: '>',
    valEnd: '</',
    toolEnd: '</tool_code>',
    scopeEnd: '',
  );
}

/// Builds a simple XML-style tool-call grammar for [format].
String? buildXmlToolCallGrammar(
  List<ToolDefinition>? tools,
  XmlToolCallFormat format,
) {
  if (tools == null || tools.isEmpty) {
    return null;
  }

  final toolNames = tools
      .map((tool) => tool.name)
      .toSet()
      .toList(growable: false);
  final paramNames = <String>{};
  for (final tool in tools) {
    for (final parameter in tool.parameters) {
      paramNames.add(parameter.name);
    }
  }

  final toolNameRule = toolNames.map(_literal).join(' | ');
  final paramNameRule = paramNames.isEmpty
      ? 'identifier'
      : paramNames.map(_literal).join(' | ');

  final scopeStart = format.scopeStart.isEmpty
      ? ''
      : '${_literal(format.scopeStart)} ';
  final scopeEnd = format.scopeEnd.isEmpty
      ? ''
      : ' ${_literal(format.scopeEnd)}';
  const jsonValueRules = r'''
identifier ::= [A-Za-z_] [A-Za-z0-9_-]*
space ::= " "?
string ::= "\"" ([^"\\] | "\\\\" .)* "\""
number ::= "-"? ([0-9] | [1-9] [0-9]*) ("." [0-9]+)? ([eE] [-+]? [0-9]+)?
boolean ::= "true" | "false"
null ::= "null"
value ::= string | number | boolean | null | arr | obj
arr ::= "[" space (value ("," space value)*)? space "]"
obj ::= "{" space (string ":" space value ("," space string ":" space value)*)? space "}"
''';

  if (format == XmlToolCallFormat.qwen3Coder) {
    // Qwen emits the XML envelope with line breaks between tags. Lazy grammar
    // activation replays that exact trigger text, so whitespace must be valid
    // in the grammar rather than relying on eager constrained decoding to
    // remove it.
    return '''
root ::= ${_literal(format.scopeStart)} xml-space tool-call+ ${_literal(format.scopeEnd)} xml-space
tool-call ::= ${_literal(format.toolStart)} tool-name ${_literal(format.toolSep)} xml-space param* ${_literal(format.toolEnd)} xml-space
param ::= ${_literal(format.keyStart)} param-name ${_literal(format.keyValSep)} qwen3-coder-value ${_literal(format.valEnd)} xml-space
tool-name ::= $toolNameRule
param-name ::= $paramNameRule
qwen3-coder-value ::= raw-text | value
raw-text ::= ([^<])*
xml-space ::= [ \\t\\n\\r]*
$jsonValueRules
''';
  }

  if (format == XmlToolCallFormat.minicpm5) {
    return '''
root ::= ${scopeStart}tool-call+$scopeEnd
tool-call ::= ${_literal(format.toolStart)} tool-name ${_literal(format.toolSep)} param* ${_literal(format.toolEnd)}
param ::= ${_literal(format.keyStart)} param-name ${_literal(format.keyValSep)} minicpm-value ${_literal(format.valEnd)}
tool-name ::= $toolNameRule
param-name ::= $paramNameRule
minicpm-value ::= raw-text | value
raw-text ::= ([^<])*
$jsonValueRules
''';
  }

  final argumentValueRule = switch (format.rawArgval) {
    true => 'raw-text',
    false => 'value',
    null => 'argument-value',
  };
  final argumentsRule = format.lastValEnd == null
      ? '(param ${_literal(format.valEnd)})*'
      : format.lastValEnd!.isEmpty
      ? '(param (${_literal(format.valEnd)} param)*)?'
      : '(param (${_literal(format.valEnd)} param)*)? ${_literal(format.lastValEnd!)}';
  final toolCallRule =
      '${_literal(format.toolStart)} tool-name ${_literal(format.toolSep)} arguments ${_literal(format.toolEnd)}';
  final rootRule = format.lastToolEnd == null
      ? '${scopeStart}tool-call+$scopeEnd'
      : '${scopeStart}tool-call* last-tool-call$scopeEnd';
  final lastToolCallRule = format.lastToolEnd == null
      ? ''
      : '\nlast-tool-call ::= ${_literal(format.toolStart)} tool-name ${_literal(format.toolSep)} arguments ${_literal(format.lastToolEnd!)}';
  final rawTextRule = format.rawArgval == false ? '' : '\nraw-text ::= ([^<])*';
  final eitherValueRule = format.rawArgval == null
      ? '\nargument-value ::= raw-text | value'
      : '';

  return '''
root ::= $rootRule
tool-call ::= $toolCallRule$lastToolCallRule
arguments ::= $argumentsRule
param ::= ${_literal(format.keyStart)} param-name ${_literal(format.keyValSep)} $argumentValueRule
tool-name ::= $toolNameRule
param-name ::= $paramNameRule$rawTextRule$eitherValueRule
$jsonValueRules
''';
}

String _literal(String value) {
  final escaped = value
      .replaceAll('\\', r'\\')
      .replaceAll('"', r'\"')
      .replaceAll('\n', r'\n')
      .replaceAll('\r', r'\r');
  return '"$escaped"';
}

/// Parses XML-style tool calls with optional reasoning.
///
/// Matches llama.cpp's `consume_reasoning_with_xml_tool_calls`.
ChatParseResult parseXmlToolCalls(
  String input,
  XmlToolCallFormat format, {
  String startThink = '<think>',
  String endThink = '</think>',
  bool isPartial = false,
  bool parseToolCalls = true,
  bool thinkingForcedOpen = false,
}) {
  String? reasoning;
  var content = input;

  // Qwen3.6 can emit a tool call directly after a thinking tag that was
  // already opened in the prompt. Split that leading thinking text before
  // parsing the tool scope instead of classifying the whole tool call as
  // reasoning when no closing tag was generated.
  final forcedOpenToolScopeIndex =
      parseToolCalls &&
          format.allowToolcallInThink &&
          thinkingForcedOpen &&
          !content.contains(startThink) &&
          !content.contains(endThink)
      ? (format.scopeStart.isEmpty
            ? content.indexOf(format.toolStart)
            : content.indexOf(format.scopeStart))
      : -1;
  if (forcedOpenToolScopeIndex >= 0) {
    final leadingReasoning = content
        .substring(0, forcedOpenToolScopeIndex)
        .trim();
    reasoning = leadingReasoning.isEmpty ? null : leadingReasoning;
    content = content.substring(forcedOpenToolScopeIndex);
  } else {
    // Extract thinking/reasoning first.
    // Keep an incomplete trailing XML tool-scope prefix out of streamed
    // reasoning. A tokenizer may split `<tool_call>` over multiple pieces;
    // treating the prefix as reasoning would leak tool markup before the
    // complete scope can be parsed on the next chunk.
    final deferredScopePrefixLength =
        isPartial && format.allowToolcallInThink && thinkingForcedOpen
        ? _trailingPrefixLength(content, format.scopeStart)
        : 0;
    final thinkingInput = deferredScopePrefixLength == 0
        ? content
        : content.substring(0, content.length - deferredScopePrefixLength);
    final thinkResult = extractThinking(
      thinkingInput,
      startTag: startThink,
      endTag: endThink,
      thinkingForcedOpen: thinkingForcedOpen,
    );
    reasoning = thinkResult.reasoning;
    content = thinkResult.content;
  }

  if (!parseToolCalls) {
    return ChatParseResult(
      content: content.trim(),
      reasoningContent: reasoning,
    );
  }

  final toolCalls = <LlamaCompletionChunkToolCall>[];
  final parsedContent = StringBuffer();
  var remainingContent = format.scopeStart.isEmpty ? '' : content;
  final originalContent = content;
  var parseFailed = false;

  // Find scope start
  final scopeIdx = format.scopeStart.isEmpty
      ? 0
      : content.indexOf(format.scopeStart);

  if (scopeIdx == -1) {
    return ChatParseResult(
      content: content.trim(),
      reasoningContent: reasoning,
    );
  }

  if (format.scopeStart.isNotEmpty) {
    remainingContent = content.substring(0, scopeIdx);
    content = content.substring(scopeIdx + format.scopeStart.length);
  }

  // Parse individual tool calls
  var callIndex = 0;
  var pos = 0;

  while (pos < content.length) {
    final toolIdx = content.indexOf(format.toolStart, pos);
    if (toolIdx == -1) {
      if (format.scopeStart.isNotEmpty) {
        final remaining = content.substring(pos).trimLeft();
        if (remaining.isNotEmpty && !_startsWithScopeTail(remaining, format)) {
          parseFailed = true;
        }
      } else if (pos < content.length) {
        parsedContent.write(content.substring(pos));
      }
      break;
    }
    if (format.scopeStart.isNotEmpty &&
        content.substring(pos, toolIdx).trim().isNotEmpty) {
      parseFailed = true;
      break;
    }
    if (format.scopeStart.isEmpty && toolIdx > pos) {
      parsedContent.write(content.substring(pos, toolIdx));
    }

    final toolCall = _parseXmlToolCall(content, toolIdx, format);
    if (toolCall == null) {
      if (format.scopeStart.isNotEmpty) {
        parseFailed = true;
      } else {
        parsedContent.write(content.substring(toolIdx));
      }
      break;
    }
    pos = toolCall.nextPos;

    toolCalls.add(
      ToolCallParsingUtils.createFunctionToolCall(
        index: callIndex,
        name: toolCall.name,
        arguments: toolCall.arguments,
      ),
    );
    callIndex++;
  }

  // Find scope end and append any trailing content
  if (format.scopeStart.isEmpty) {
    remainingContent = parsedContent.toString();
  } else if (format.scopeEnd.isNotEmpty) {
    final scopeEndIdx = content.indexOf(format.scopeEnd, pos);
    if (scopeEndIdx != -1) {
      final trailing = content.substring(scopeEndIdx + format.scopeEnd.length);
      if (trailing.trim().isNotEmpty) {
        remainingContent += trailing;
      }
    } else {
      parseFailed = true;
    }
  }

  if (parseFailed) {
    return ChatParseResult(
      content: originalContent.trim(),
      reasoningContent: reasoning,
    );
  }

  return ChatParseResult(
    content: remainingContent.trim(),
    reasoningContent: reasoning,
    toolCalls: toolCalls,
  );
}

int _trailingPrefixLength(String value, String prefix) {
  if (prefix.isEmpty) {
    return 0;
  }

  final maxLength = value.length < prefix.length
      ? value.length
      : prefix.length - 1;
  for (var length = maxLength; length > 0; length--) {
    if (value.endsWith(prefix.substring(0, length))) {
      return length;
    }
  }
  return 0;
}

_ParsedXmlToolCall? _parseXmlToolCall(
  String content,
  int toolIdx,
  XmlToolCallFormat format,
) {
  final nameStart = toolIdx + format.toolStart.length;
  final sepIdx = content.indexOf(format.toolSep, nameStart);
  if (sepIdx == -1) {
    return null;
  }

  final name = content.substring(nameStart, sepIdx).trim();
  if (name.isEmpty) {
    return null;
  }

  final arguments = _parseXmlArguments(
    content,
    sepIdx + format.toolSep.length,
    format,
  );
  if (arguments == null) {
    return null;
  }

  return _ParsedXmlToolCall(
    name: name,
    arguments: arguments.arguments,
    nextPos: arguments.nextPos,
  );
}

_ParsedXmlArguments? _parseXmlArguments(
  String content,
  int start,
  XmlToolCallFormat format,
) {
  final strictScope = format.scopeStart.isNotEmpty;
  final args = <String, dynamic>{};
  var pos = start;
  var consumedToolEnd = false;

  while (pos < content.length) {
    pos = _consumeXmlWhitespace(content, pos);

    final toolEndLen = _matchToolEnd(content, pos, format);
    if (toolEndLen != null) {
      pos += toolEndLen;
      consumedToolEnd = true;
      break;
    }

    final keyIdx = content.indexOf(format.keyStart, pos);
    if (keyIdx == -1) {
      if (strictScope && _matchToolEnd(content, pos, format) == null) {
        return null;
      }
      break;
    }
    if (strictScope && content.substring(pos, keyIdx).trim().isNotEmpty) {
      return null;
    }

    final keyNameStart = keyIdx + format.keyStart.length;
    final keyNameEnd = content.indexOf(format.keyValSep, keyNameStart);
    if (keyNameEnd == -1) {
      return null;
    }

    final key = content.substring(keyNameStart, keyNameEnd).trim();
    if (key.isEmpty) {
      return null;
    }
    pos = keyNameEnd + format.keyValSep.length;

    final argumentValue = _parseXmlArgumentValue(content, pos, format);
    if (argumentValue == null) {
      return null;
    }
    args[key] = argumentValue.value;
    pos = argumentValue.nextPos;
  }

  pos = _consumeXmlWhitespace(content, pos);
  if (!consumedToolEnd) {
    final toolEndLen = _matchToolEnd(content, pos, format);
    if (toolEndLen != null) {
      pos += toolEndLen;
    } else if (strictScope) {
      return null;
    }
  }

  return _ParsedXmlArguments(arguments: args, nextPos: pos);
}

_ParsedCdataValue? _parseCdataValue(
  String content,
  int start,
  XmlToolCallFormat format,
) {
  const cdataStart = '<![CDATA[';
  const cdataEnd = ']]>';
  if (!content.startsWith(cdataStart, start)) {
    return null;
  }

  final cdataEndIdx = content.indexOf(cdataEnd, start + cdataStart.length);
  if (cdataEndIdx == -1) {
    return null;
  }

  final valueEnd = _consumeValueEnd(
    content,
    cdataEndIdx + cdataEnd.length,
    format,
  );
  if (valueEnd == null) {
    return null;
  }

  return _ParsedCdataValue(
    value: content.substring(start + cdataStart.length, cdataEndIdx),
    nextPos: valueEnd,
  );
}

int? _matchToolEnd(String text, int at, XmlToolCallFormat format) {
  if (format.toolEnd.isNotEmpty && text.startsWith(format.toolEnd, at)) {
    return format.toolEnd.length;
  }
  if (format.lastToolEnd != null &&
      format.lastToolEnd!.isNotEmpty &&
      text.startsWith(format.lastToolEnd!, at)) {
    return format.lastToolEnd!.length;
  }
  return null;
}

int _findNextToolEndIndex(String text, int from, XmlToolCallFormat format) {
  final toolEndIdx = format.toolEnd.isEmpty
      ? -1
      : text.indexOf(format.toolEnd, from);
  final lastToolEndIdx =
      (format.lastToolEnd != null && format.lastToolEnd!.isNotEmpty)
      ? text.indexOf(format.lastToolEnd!, from)
      : -1;
  if (toolEndIdx == -1) {
    return lastToolEndIdx;
  }
  if (lastToolEndIdx == -1) {
    return toolEndIdx;
  }
  return toolEndIdx < lastToolEndIdx ? toolEndIdx : lastToolEndIdx;
}

bool _startsWithScopeTail(String text, XmlToolCallFormat format) {
  if (format.scopeEnd.isEmpty) {
    return text.isEmpty;
  }
  if (text.startsWith(format.scopeEnd)) {
    return true;
  }
  if (format.lastToolEnd != null &&
      format.lastToolEnd!.isNotEmpty &&
      text.startsWith('${format.lastToolEnd}${format.scopeEnd}')) {
    return true;
  }
  if (format.toolEnd.isNotEmpty &&
      text.startsWith('${format.toolEnd}${format.scopeEnd}')) {
    return true;
  }
  return false;
}

int _consumeXmlWhitespace(String text, int from) {
  var pos = from;
  while (pos < text.length) {
    final codeUnit = text.codeUnitAt(pos);
    if (codeUnit > 0x20) {
      break;
    }
    pos++;
  }
  return pos;
}

_ParsedXmlArgumentValue? _parseXmlArgumentValue(
  String content,
  int start,
  XmlToolCallFormat format,
) {
  if (format.rawArgval == false) {
    final valueStart = _consumeXmlWhitespace(content, start);
    final parsed = ToolCallParsingUtils.extractLeadingJsonValue(
      content,
      valueStart,
    );
    if (parsed == null) {
      return null;
    }
    final nextPos = _consumeValueEnd(content, parsed.end, format);
    if (nextPos == null) {
      return null;
    }
    return _ParsedXmlArgumentValue(value: parsed.value, nextPos: nextPos);
  }

  final cdataValue = _parseCdataValue(content, start, format);
  if (cdataValue != null) {
    return _ParsedXmlArgumentValue(
      value: cdataValue.value,
      nextPos: cdataValue.nextPos,
    );
  }

  final valueEnd = _findValueEnd(content, start, format);
  if (valueEnd == null) {
    return null;
  }

  var value = content.substring(start, valueEnd.valueEnd);
  if (format.trimRawArgval) {
    value = value.trim();
  }
  return _ParsedXmlArgumentValue(
    value: format.rawArgval == true
        ? value
        : ToolCallParsingUtils.decodeJsonValueOrString(value),
    nextPos: valueEnd.nextPos,
  );
}

int? _consumeValueEnd(String content, int start, XmlToolCallFormat format) {
  final markerStart = _consumeXmlWhitespace(content, start);
  if (format.valEnd.isNotEmpty &&
      content.startsWith(format.valEnd, markerStart)) {
    return markerStart + format.valEnd.length;
  }

  final lastValEnd = format.lastValEnd;
  if (lastValEnd == null ||
      (lastValEnd.isNotEmpty && !content.startsWith(lastValEnd, markerStart))) {
    return null;
  }
  final afterMarker = markerStart + lastValEnd.length;
  final toolEndStart = _consumeXmlWhitespace(content, afterMarker);
  return _matchToolEnd(content, toolEndStart, format) == null
      ? null
      : afterMarker;
}

_ValueEndMatch? _findValueEnd(
  String content,
  int start,
  XmlToolCallFormat format,
) {
  _ValueEndMatch? best;
  if (format.valEnd.isNotEmpty) {
    final index = content.indexOf(format.valEnd, start);
    if (index != -1) {
      best = _ValueEndMatch(
        valueEnd: index,
        nextPos: index + format.valEnd.length,
      );
    }
  }

  final lastValEnd = format.lastValEnd;
  if (lastValEnd != null) {
    if (lastValEnd.isEmpty) {
      final toolEndIndex = _findNextToolEndIndex(content, start, format);
      if (toolEndIndex != -1 &&
          (best == null || toolEndIndex < best.valueEnd)) {
        best = _ValueEndMatch(valueEnd: toolEndIndex, nextPos: toolEndIndex);
      }
    } else {
      var searchFrom = start;
      while (searchFrom <= content.length - lastValEnd.length) {
        final index = content.indexOf(lastValEnd, searchFrom);
        if (index == -1) {
          break;
        }
        final afterMarker = index + lastValEnd.length;
        final toolEndStart = _consumeXmlWhitespace(content, afterMarker);
        if (_matchToolEnd(content, toolEndStart, format) != null) {
          if (best == null || index < best.valueEnd) {
            best = _ValueEndMatch(valueEnd: index, nextPos: afterMarker);
          }
          break;
        }
        searchFrom = index + lastValEnd.length;
      }
    }
  }
  return best;
}

final class _ParsedCdataValue {
  final String value;
  final int nextPos;

  const _ParsedCdataValue({required this.value, required this.nextPos});
}

final class _ParsedXmlToolCall {
  final String name;
  final Map<String, dynamic> arguments;
  final int nextPos;

  const _ParsedXmlToolCall({
    required this.name,
    required this.arguments,
    required this.nextPos,
  });
}

final class _ParsedXmlArguments {
  final Map<String, dynamic> arguments;
  final int nextPos;

  const _ParsedXmlArguments({required this.arguments, required this.nextPos});
}

final class _ParsedXmlArgumentValue {
  final Object? value;
  final int nextPos;

  const _ParsedXmlArgumentValue({required this.value, required this.nextPos});
}

final class _ValueEndMatch {
  final int valueEnd;
  final int nextPos;

  const _ValueEndMatch({required this.valueEnd, required this.nextPos});
}
