import 'dart:math';

import '../models/chat/completion_chunk.dart';
import 'thinking_utils.dart';
import 'tool_call_parsing_utils.dart';

/// Result of parsing loose tool-call text fallback.
class ToolCallFallbackParseResult {
  /// Remaining user-visible content after extracting tool calls.
  final String content;

  /// Parsed tool calls, if any.
  final List<LlamaCompletionChunkToolCall> toolCalls;

  /// Creates a fallback parse result.
  const ToolCallFallbackParseResult({
    required this.content,
    required this.toolCalls,
  });
}

/// Parses tool calls from loose plain-text payloads.
///
/// This is intentionally permissive and used only when a format-specific
/// parser fails to extract explicit tool-call structures.
/// With [preserveJsonProse], keep the raw text preceding a loose JSON call.
/// While [isPartial], hold only the suffix that can still become such a call.
ToolCallFallbackParseResult parseToolCallsFromLooseText(
  String input, {
  bool preserveJsonProse = false,
  bool isPartial = false,
}) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) {
    return ToolCallFallbackParseResult(
      content: preserveJsonProse ? input : '',
      toolCalls: const <LlamaCompletionChunkToolCall>[],
    );
  }

  final (payload, payloadStart) = _stripToolFence(trimmed);

  final json = _parseJsonLikeToolCalls(payload);
  if (json != null) {
    var contentEnd = 0;
    if (preserveJsonProse) {
      final leadingSpace = input.length - input.trimLeft().length;
      contentEnd = _looseJsonWrapperStart(
        input.substring(0, leadingSpace + payloadStart + json.start),
      );
      if (isPartial) {
        contentEnd = min(contentEnd, _pendingLooseJsonStart(input));
      }
    }
    return ToolCallFallbackParseResult(
      content: input.substring(0, contentEnd),
      toolCalls: json.calls,
    );
  }

  final functionCall = _parseFunctionCallSyntax(payload);
  if (functionCall != null) {
    return ToolCallFallbackParseResult(
      content: '',
      toolCalls: <LlamaCompletionChunkToolCall>[functionCall],
    );
  }

  return ToolCallFallbackParseResult(
    content: !preserveJsonProse
        ? trimmed
        : isPartial
        ? input.substring(0, _pendingLooseJsonStart(input))
        : input,
    toolCalls: const <LlamaCompletionChunkToolCall>[],
  );
}

final _looseJsonWrapper = RegExp(
  r'(?:<tool_call>|```(?:tool_code|tool|json)?)\s*(?:\[\s*)?$|\[\s*$',
);

int _looseJsonWrapperStart(String prefix) =>
    _looseJsonWrapper.firstMatch(prefix)?.start ?? prefix.length;

int _pendingLooseJsonStart(String input) {
  const wrapperOpenings = ['<tool_call>', '```json', '```tool', '```tool_code'];
  final wrapperPrefix = withoutTrailingTagPrefix(input, wrapperOpenings);
  var holdFrom = min(wrapperPrefix.length, _looseJsonWrapperStart(input));

  // The fallback tries semicolon-delimited parts and the whole reply. A
  // semicolon can also be inside a JSON string, so both can still complete.
  for (final start in {0, input.lastIndexOf(';') + 1}) {
    final remainder = input.substring(start);
    final trimmed = remainder.trimLeft();
    final array = start + remainder.length - trimmed.length;
    if (trimmed.startsWith('[') &&
        ToolCallParsingUtils.findStructuredJsonEnd(input, array) == null) {
      holdFrom = min(holdFrom, array);
    }
    final object = input.indexOf('{', start);
    if (object >= 0 &&
        ToolCallParsingUtils.findStructuredJsonEnd(input, object) == null) {
      holdFrom = min(
        holdFrom,
        _looseJsonWrapperStart(input.substring(0, object)),
      );
    }
  }
  return holdFrom;
}

/// Decodes tool arguments JSON/object text into a map.
Map<String, dynamic> decodeToolArgumentsObject(String? rawArguments) {
  if (rawArguments == null) {
    return const <String, dynamic>{};
  }

  final trimmed = rawArguments.trim();
  if (trimmed.isEmpty) {
    return const <String, dynamic>{};
  }

  final decoded = ToolCallParsingUtils.decodeJsonMapValue(
    trimmed,
    trimInput: true,
  );
  if (decoded != null) {
    return decoded;
  }

  final object = ToolCallParsingUtils.extractFirstJsonObject(trimmed);
  if (object != null) {
    return object;
  }

  return const <String, dynamic>{};
}

/// Normalizes fallback argument aliases.
Map<String, dynamic> normalizeFallbackToolArguments(
  Map<String, dynamic> arguments,
) {
  final normalized = <String, dynamic>{...arguments};
  final wrappedArguments = _unwrapArgumentContainer(normalized);
  if (wrappedArguments != null) {
    normalized
      ..clear()
      ..addAll(wrappedArguments);
  }
  return normalized;
}

Map<String, dynamic>? _unwrapArgumentContainer(Map<String, dynamic> arguments) {
  const wrapperKeys = <String>{'arguments', 'parameters', 'params', 'input'};
  if (arguments.length != 1) {
    return null;
  }

  final entry = arguments.entries.first;
  if (!wrapperKeys.contains(entry.key)) {
    return null;
  }

  return ToolCallParsingUtils.coerceMap(entry.value);
}

/// Normalizes noisy tool aliases to canonical names where possible.
String normalizeFallbackToolName(
  String rawName, {
  Map<String, dynamic>? arguments,
}) {
  // Preserve model-emitted tool name for llama.cpp parity.
  final trimmed = rawName.trim();
  return trimmed;
}

({List<LlamaCompletionChunkToolCall> calls, int start})?
_parseJsonLikeToolCalls(String input) {
  final parts = input.split(';');

  if (parts.where((part) => part.trim().isNotEmpty).skip(1).isNotEmpty) {
    final calls = <LlamaCompletionChunkToolCall>[];
    var offset = 0;
    int? firstCall;
    for (final part in parts) {
      final partStart = offset + part.length - part.trimLeft().length;
      offset += part.length + 1;
      final decoded = _decodeJsonLoose(part.trim());
      if (decoded == null) continue;
      final partCalls = _toolCallsFromDecoded(
        decoded.value,
        startIndex: calls.length,
      );
      if (partCalls.isEmpty) continue;
      firstCall ??= partStart + decoded.start;
      calls.addAll(partCalls);
    }

    if (firstCall != null) {
      return (calls: List.unmodifiable(calls), start: firstCall);
    }
  }

  final decoded = _decodeJsonLoose(input);
  if (decoded != null) {
    final calls = _toolCallsFromDecoded(decoded.value, startIndex: 0);
    if (calls.isNotEmpty) return (calls: calls, start: decoded.start);
  }

  return null;
}

({Object value, int start})? _decodeJsonLoose(String input) {
  final direct = ToolCallParsingUtils.decodeJsonValue(input);
  if (direct != null) {
    return (value: direct, start: 0);
  }

  final normalized = _normalizeLooseJsonIdentifiers(input);
  final normalizedDecoded = ToolCallParsingUtils.decodeJsonValue(normalized);
  if (normalizedDecoded != null) {
    return (value: normalizedDecoded, start: 0);
  }

  final object = ToolCallParsingUtils.extractFirstJsonObject(normalized);
  return object == null ? null : (value: object, start: input.indexOf('{'));
}

List<LlamaCompletionChunkToolCall> _toolCallsFromDecoded(
  Object decoded, {
  required int startIndex,
}) {
  final decodedMap = ToolCallParsingUtils.coerceMap(decoded);
  if (decodedMap != null) {
    final toolCallsRaw = decodedMap['tool_calls'];
    if (toolCallsRaw != null) {
      final calls = _toolCallsFromDecoded(toolCallsRaw, startIndex: startIndex);
      if (calls.isNotEmpty) {
        return calls;
      }
    }

    final call = _toolCallFromMap(decodedMap, index: startIndex);
    if (call == null) {
      return const <LlamaCompletionChunkToolCall>[];
    }
    return <LlamaCompletionChunkToolCall>[call];
  }

  if (decoded is List) {
    final calls = <LlamaCompletionChunkToolCall>[];
    for (var i = 0; i < decoded.length; i++) {
      final item = ToolCallParsingUtils.coerceMap(decoded[i]);
      if (item == null) {
        continue;
      }

      final call = _toolCallFromMap(item, index: startIndex + i);
      if (call != null) {
        calls.add(call);
      }
    }
    return List<LlamaCompletionChunkToolCall>.unmodifiable(calls);
  }

  return const <LlamaCompletionChunkToolCall>[];
}

LlamaCompletionChunkToolCall? _toolCallFromMap(
  Map<String, dynamic> object, {
  required int index,
}) {
  final candidate =
      ToolCallParsingUtils.coerceMap(object['tool_call']) ?? object;

  final functionRaw = candidate['function'];
  Object? nameRaw;
  Object? argumentsRaw;
  final function = ToolCallParsingUtils.coerceMap(functionRaw);
  if (function != null) {
    nameRaw = function['name'];
    argumentsRaw =
        function['arguments'] ??
        function['parameters'] ??
        function['params'] ??
        function['input'] ??
        candidate['arguments'] ??
        candidate['parameters'] ??
        candidate['args'] ??
        candidate['params'] ??
        candidate['input'];
  } else {
    nameRaw =
        candidate['name'] ??
        functionRaw ??
        candidate['tool_name'] ??
        candidate['code'] ??
        candidate['type'];
    argumentsRaw =
        candidate['arguments'] ??
        candidate['parameters'] ??
        candidate['args'] ??
        candidate['params'] ??
        candidate['input'];
  }

  if (nameRaw is! String || nameRaw.trim().isEmpty) {
    return null;
  }

  final argsMap = argumentsRaw == null
      ? _extractInlineArguments(candidate)
      : _toArgumentsObject(argumentsRaw);
  final normalizedArgs = normalizeFallbackToolArguments(argsMap);
  final normalizedName = normalizeFallbackToolName(
    nameRaw,
    arguments: normalizedArgs,
  );

  if (normalizedName.isEmpty) {
    return null;
  }

  return ToolCallParsingUtils.createFunctionToolCall(
    index: index,
    name: normalizedName,
    id: object['id'] is String ? object['id'] as String : null,
    arguments: normalizedArgs,
  );
}

Map<String, dynamic> _extractInlineArguments(Map<String, dynamic> candidate) {
  const metaKeys = <String>{
    'name',
    'type',
    'code',
    'tool_name',
    'function',
    'tool',
    'toolName',
    'id',
    'call_id',
    'tool_call_id',
    'index',
    'tool_call',
  };

  final inline = <String, dynamic>{};
  for (final entry in candidate.entries) {
    if (metaKeys.contains(entry.key)) {
      continue;
    }
    inline[entry.key] = entry.value;
  }

  return inline;
}

Map<String, dynamic> _toArgumentsObject(Object? raw) {
  if (raw == null) {
    return const <String, dynamic>{};
  }

  final map = ToolCallParsingUtils.coerceMap(raw);
  if (map != null) {
    return map;
  }

  if (raw is String) {
    return decodeToolArgumentsObject(raw);
  }

  return const <String, dynamic>{};
}

LlamaCompletionChunkToolCall? _parseFunctionCallSyntax(String input) {
  final match = RegExp(
    r'^([A-Za-z_][A-Za-z0-9_\.-]*)\s*(?:\((.*)\))?$',
    dotAll: true,
  ).firstMatch(input);
  if (match == null) {
    return null;
  }

  final nameRaw = match.group(1) ?? '';
  final rawArgs = (match.group(2) ?? '').trim();
  final args = _parseFunctionArguments(rawArgs);
  if (rawArgs.isNotEmpty && args == null) {
    return null;
  }

  final normalizedArgs = normalizeFallbackToolArguments(
    args ?? const <String, dynamic>{},
  );
  final normalizedName = normalizeFallbackToolName(
    nameRaw,
    arguments: normalizedArgs,
  );
  if (normalizedName.isEmpty) {
    return null;
  }

  if (rawArgs.isEmpty && normalizedName == nameRaw) {
    return null;
  }

  return ToolCallParsingUtils.createFunctionToolCall(
    index: 0,
    name: normalizedName,
    arguments: normalizedArgs,
  );
}

/// Splits `key=value` argument lists on top-level commas only, leaving commas
/// inside single/double-quoted values intact (e.g. `note='a, b'`).
List<String> _splitArgsRespectingQuotes(String raw) {
  final parts = <String>[];
  final buffer = StringBuffer();
  String? quote;
  for (var i = 0; i < raw.length; i++) {
    final ch = raw[i];
    if (quote != null) {
      buffer.write(ch);
      if (ch == quote) {
        quote = null;
      }
    } else if (ch == '"' || ch == "'") {
      quote = ch;
      buffer.write(ch);
    } else if (ch == ',') {
      parts.add(buffer.toString());
      buffer.clear();
    } else {
      buffer.write(ch);
    }
  }
  if (buffer.isNotEmpty) {
    parts.add(buffer.toString());
  }
  return parts;
}

Map<String, dynamic>? _parseFunctionArguments(String raw) {
  if (raw.trim().isEmpty) {
    return const <String, dynamic>{};
  }

  final asObject = ToolCallParsingUtils.extractFirstJsonObject(raw);
  if (asObject != null) {
    return asObject;
  }

  final result = <String, dynamic>{};
  final pairs = _splitArgsRespectingQuotes(raw);
  for (final rawPair in pairs) {
    final pair = rawPair.trim();
    if (pair.isEmpty) {
      continue;
    }

    final separatorIndex = pair.indexOf('=');
    if (separatorIndex <= 0) {
      return null;
    }

    final key = pair.substring(0, separatorIndex).trim();
    var value = pair.substring(separatorIndex + 1).trim();
    if (key.isEmpty || value.isEmpty) {
      return null;
    }

    if (value.length >= 2 &&
        ((value.startsWith("'") && value.endsWith("'")) ||
            (value.startsWith('"') && value.endsWith('"')))) {
      value = value.substring(1, value.length - 1);
      result[key] = value;
      continue;
    }

    if (value == 'true') {
      result[key] = true;
      continue;
    }

    if (value == 'false') {
      result[key] = false;
      continue;
    }

    final intValue = int.tryParse(value);
    if (intValue != null) {
      result[key] = intValue;
      continue;
    }

    final doubleValue = double.tryParse(value);
    if (doubleValue != null) {
      result[key] = doubleValue;
      continue;
    }

    result[key] = value;
  }

  return result;
}

(String, int) _stripToolFence(String input) {
  // Require a whitespace boundary after the optional language token so a
  // payload like ```jsonify{...} does not get "json" consumed as the language
  // (which would leave "ify{...}" as the body and corrupt the JSON).
  final fenced = RegExp(
    r'^(```(?:(?:tool_code|tool|json)(?=\s))?\s*)([\s\S]*?)\s*```$',
  );
  final match = fenced.firstMatch(input);
  if (match == null) {
    return (input, 0);
  }

  final inner = match.group(2)!;
  final payload = inner.trimLeft();
  if (payload.isEmpty) {
    return (input, 0);
  }

  return (
    payload.trimRight(),
    match.group(1)!.length + inner.length - payload.length,
  );
}

String _normalizeLooseJsonIdentifiers(String input) {
  var normalized = input;
  normalized = normalized.replaceAllMapped(
    RegExp(r'("name"\s*:\s*)([A-Za-z_][A-Za-z0-9_\.-]*)'),
    (match) => '${match.group(1)}"${match.group(2)}"',
  );
  normalized = normalized.replaceAllMapped(
    RegExp(r'("function"\s*:\s*)([A-Za-z_][A-Za-z0-9_\.-]*)'),
    (match) => '${match.group(1)}"${match.group(2)}"',
  );
  return normalized;
}
