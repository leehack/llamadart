import 'dart:convert';

import '../../exceptions.dart';
import '../../models/tools/tool_definition.dart';
import '../tool_call_grammar_utils.dart';

/// Builds the schema-directed Python-call language used by LFM2 auto tools.
/// Required/force-JSON callers retain their separate JSON-list grammar.
String? buildLfm2AutoGrammar(
  List<ToolDefinition>? tools, {
  required bool parallelToolCalls,
}) {
  if (tools == null || tools.isEmpty) return null;
  final builder = _PythonGrammar();
  final calls = <String>[];
  final copiedCalls = <String>[];
  for (var index = 0; index < tools.length; index++) {
    final tool = tools[index];
    final schema = tool.toJsonSchema();
    calls.add(builder.tool(tool.name, schema, 'tool-$index'));
    if (builder.acceptsCopiedStringTail(tool.name, schema)) {
      copiedCalls.add(
        builder.copiedTool(tool.name, schema, 'copied-tool-$index'),
      );
    }
  }
  builder.rules['call'] = calls.join(' | ');
  if (copiedCalls.isNotEmpty) {
    builder.rules['copied-call'] = copiedCalls.join(' | ');
  }
  final normalList =
      'call ${parallelToolCalls ? '(close-ws "," close-ws call)* ' : ''}'
      '(close-ws ",")?';
  // The loose fallback reinterprets quotes and JSON objects. Admit copied tails
  // only in one required plain path argument, without either ambiguity.
  final list = copiedCalls.isEmpty ? normalList : '($normalList | copied-call)';
  // A trailing comma lets compound tokens close the last argument and call
  // without forcing the sampler back into an unfinished string. Bound closing
  // whitespace so a completed call cannot consume the remaining token budget.
  builder.rules['root'] =
      '${ToolCallGrammarUtils.literal('<|tool_call_start|>')} ws "[" ws $list '
      'close-ws "]" close-ws ${ToolCallGrammarUtils.literal('<|tool_call_end|>')}';
  return builder.rules.entries
      .map((entry) => '${entry.key} ::= ${entry.value}')
      .join('\n');
}

final class _PythonGrammar {
  // Uniqueness needs a finite state per remaining argument set. Bound schema
  // expansion before constructing an exponential number of grammar rules.
  static const int _maxArgumentStates = 4096;
  int _argumentStates = 0;
  int _nextValue = 0;
  final Map<String, String> rules = {
    'ws': r'[ \t\n\r]*',
    'close-ws': r'[ \t\n\r]{0,8}',
    'py-string': 'double-string | single-string',
    'double-string': r'''"\"" ([^"\\] | "\\" .)* "\""''',
    'single-string': r'''"'" ([^'\\] | "\\" .)* "'"''',
    'copied-path-string':
        r'''"\"" copied-path-char* "\\" "\"" | "'" copied-path-char* "\\" "'"''',
    'copied-path-char': r'[a-zA-Z0-9_ ./:\\-] | [\u0080-\U0010FFFF]',
    'integer': r'"-"? ("0" | [1-9] [0-9]*)',
    'number': r'integer ("." [0-9]+)? ([eE] [+-]? [0-9]+)?',
    'boolean': r'"True" | "False" | "true" | "false"',
    'null': r'"None" | "null"',
  };

  bool acceptsCopiedStringTail(String name, Map<String, dynamic> schema) {
    final fields = _fields(schema);
    if (RegExp(r'[A-Za-z_][A-Za-z0-9_.-]*').matchAsPrefix(name)?.end !=
            name.length ||
        fields.length != 1) {
      return false;
    }
    final field = fields.entries.single;
    final required = schema['required'] as List? ?? const [];
    return RegExp(r'[A-Za-z_][A-Za-z0-9_]*').matchAsPrefix(field.key)?.end ==
            field.key.length &&
        required.length == 1 &&
        required.single == field.key &&
        field.value['type'] == 'string' &&
        field.value.keys.every((key) => key == 'type' || key == 'description');
  }

  String copiedTool(String name, Map<String, dynamic> schema, String rule) {
    final key = _fields(schema).keys.single;
    rules[rule] =
        '${ToolCallGrammarUtils.literal(name)} "(" ws '
        '${ToolCallGrammarUtils.literal(key)} ws "=" ws copied-path-string '
        'close-ws ")"';
    return rule;
  }

  String tool(String name, Map<String, dynamic> schema, String rule) {
    final fields = _fields(schema);
    final required = (schema['required'] as List? ?? const []).cast<String>();
    final members = <({String name, String value, bool required})>[
      for (final entry in fields.entries)
        (
          name: '${ToolCallGrammarUtils.literal(entry.key)} ws "=" ws',
          value: value(entry.value),
          required: required.contains(entry.key),
        ),
    ];
    final arguments = objectMembers(members, '$rule-args');
    rules[rule] =
        '${ToolCallGrammarUtils.literal(name)} "(" ws $arguments ws ")"';
    return rule;
  }

  Map<String, Map<String, dynamic>> _fields(Map<String, dynamic> schema) => {
    for (final entry in (schema['properties'] as Map? ?? const {}).entries)
      entry.key as String: Map<String, dynamic>.from(entry.value as Map),
  };

  String value(Map<String, dynamic> schema) {
    final choices = schema['enum'];
    if (choices is List) {
      if (choices.isEmpty || choices.any((value) => value is! String)) {
        throw LlamaUnsupportedException(
          'LFM2 auto enum arguments require a non-empty string enum.',
        );
      }
      final rule = 'value-${_nextValue++}';
      rules[rule] = choices
          .cast<String>()
          .map((text) {
            final trailingBackslashes = text.codeUnits.reversed
                .takeWhile((codeUnit) => codeUnit == 0x5c)
                .length;
            if (trailingBackslashes.isOdd) {
              throw LlamaUnsupportedException(
                'LFM2 auto enum values ending in an odd number of backslashes '
                'cannot preserve strict argument quote boundaries.',
              );
            }
            final literals = <String>[];
            for (final quote in ['"', "'"]) {
              if (!text.contains(quote)) {
                literals.add(ToolCallGrammarUtils.literal('$quote$text$quote'));
              }
            }
            if (literals.isEmpty) {
              throw LlamaUnsupportedException(
                'LFM2 auto enum values containing both quote styles cannot '
                'preserve the copied-string policy.',
              );
            }
            return literals.join(' | ');
          })
          .join(' | ');
      return rule;
    }
    return switch (schema['type']) {
      'string' => 'py-string',
      'integer' => 'integer',
      'number' => 'number',
      'boolean' => 'boolean',
      'null' => 'null',
      'array' => array(schema),
      'object' => object(schema),
      _ => throw LlamaUnsupportedException(
        'LFM2 auto Python-call grammar requires declared legacy parameter '
        'types; this schema is unsupported.',
      ),
    };
  }

  String array(Map<String, dynamic> schema) {
    final items = schema['items'];
    if (items is! Map) {
      throw LlamaUnsupportedException(
        'LFM2 auto array parameters need a declared item type.',
      );
    }
    final rule = 'value-${_nextValue++}';
    final item = value(Map<String, dynamic>.from(items));
    rules[rule] = '"[" ws ($item (ws "," ws $item)*)? ws "]"';
    return rule;
  }

  String object(Map<String, dynamic> schema) {
    final rule = 'value-${_nextValue++}';
    final fields = _fields(schema);
    final required = (schema['required'] as List? ?? const []).cast<String>();
    final members = <({String name, String value, bool required})>[
      for (final entry in fields.entries)
        (
          name: '${quotedObjectKey(entry.key)} ws ":" ws',
          value: value(entry.value),
          required: required.contains(entry.key),
        ),
    ];
    final body = objectMembers(members, '$rule-members');
    rules[rule] = '"{" ws $body ws "}"';
    return rule;
  }

  String quotedObjectKey(String key) {
    // Nested double-quoted keys use JSON decoding in the existing parser.
    final spellings = [
      jsonEncode(key),
      if (!key.contains("'") &&
          !key.contains(r'\') &&
          key.runes.every((rune) => rune >= 0x20 && rune != 0x7f))
        "'$key'",
    ];
    return '(${spellings.map(ToolCallGrammarUtils.literal).join(' | ')})';
  }

  String objectMembers(
    List<({String name, String value, bool required})> members,
    String prefix,
  ) {
    if (members.length > 20) _tooLarge();
    if (members.isEmpty) {
      rules[prefix] = '""';
      return prefix;
    }
    final visited = <int>{};
    final requiredMask = [
      for (var index = 0; index < members.length; index++)
        if (members[index].required) 1 << index,
    ].fold(0, (left, right) => left | right);
    final full = (1 << members.length) - 1;
    String state(int remaining) {
      final name = '$prefix-$remaining';
      if (!visited.add(remaining)) return name;
      if (++_argumentStates > _maxArgumentStates) _tooLarge();
      final alternatives = <String>[];
      for (var index = 0; index < members.length; index++) {
        final bit = 1 << index;
        if (remaining & bit == 0) continue;
        final member = members[index];
        final next = remaining ^ bit;
        final item = '${member.name} ${member.value}';
        if (next & requiredMask == 0) alternatives.add(item);
        if (next != 0) alternatives.add('$item ws "," ws ${state(next)}');
      }
      rules[name] = alternatives.join(' | ');
      return name;
    }

    final nonempty = state(full);
    if (requiredMask != 0) return nonempty;
    rules[prefix] = '"" | $nonempty';
    return prefix;
  }

  Never _tooLarge() => throw LlamaUnsupportedException(
    'LFM2 auto Python-call grammar exceeds the bounded argument-state '
    'budget; use fewer parameters or nested object fields.',
  );
}
