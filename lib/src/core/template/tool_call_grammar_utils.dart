import '../grammar/json_schema_converter.dart';
import '../models/tools/tool_definition.dart';

/// Utilities for building tool-call grammars from [ToolDefinition] schemas.
class ToolCallGrammarUtils {
  const ToolCallGrammarUtils._();

  /// Escapes [value] as a grammar string literal.
  static String literal(String value) => _literal(value);

  /// Encodes [value] as a collision-free GBNF rule-name component.
  static String ruleName(String value) {
    if (value.isEmpty) {
      return 'rule-empty';
    }
    final buffer = StringBuffer();
    for (final rune in value.runes) {
      final isAsciiAlphaNumeric =
          (rune >= 0x30 && rune <= 0x39) ||
          (rune >= 0x41 && rune <= 0x5A) ||
          (rune >= 0x61 && rune <= 0x7A);
      if (isAsciiAlphaNumeric) {
        buffer.writeCharCode(rune);
      } else {
        buffer.write('-u${rune.toRadixString(16)}-');
      }
    }
    return buffer.toString();
  }

  /// Builds a grammar for an array of tool calls and wraps it with literals.
  static String? buildWrappedArrayGrammar({
    required List<ToolDefinition>? tools,
    required String prefix,
    required String suffix,
    String nameKey = 'name',
    String argumentsKey = 'arguments',
    String? idKey,
    String? idPattern,
    bool allowParallelToolCalls = true,
  }) {
    if (tools == null || tools.isEmpty) {
      return null;
    }

    final schema = _buildToolArraySchema(
      tools,
      nameKey: nameKey,
      argumentsKey: argumentsKey,
      idKey: idKey,
      idPattern: idPattern,
      allowParallelToolCalls: allowParallelToolCalls,
    );

    final grammar = JsonSchemaConverter.convert(schema);
    return wrapRootGrammar(grammar, prefix: prefix, suffix: suffix);
  }

  /// Builds a grammar for a single tool call object and wraps it.
  static String? buildWrappedObjectGrammar({
    required List<ToolDefinition>? tools,
    required String prefix,
    required String suffix,
    String nameKey = 'name',
    String argumentsKey = 'arguments',
    String? idKey,
    String? idPattern,
  }) {
    if (tools == null || tools.isEmpty) {
      return null;
    }

    final itemSchemas = tools
        .map(
          (tool) => _buildToolObjectSchema(
            tool,
            nameKey: nameKey,
            argumentsKey: argumentsKey,
            idKey: idKey,
            idPattern: idPattern,
          ),
        )
        .toList(growable: false);

    final schema = itemSchemas.length == 1
        ? itemSchemas.first
        : <String, dynamic>{'anyOf': itemSchemas};
    final grammar = JsonSchemaConverter.convert(schema);
    return wrapRootGrammar(grammar, prefix: prefix, suffix: suffix);
  }

  /// Rewrites the grammar `root` rule with wrapper literals.
  static String wrapRootGrammar(
    String grammar, {
    String prefix = '',
    String suffix = '',
  }) {
    final lines = grammar.trimRight().split('\n');
    final rootIndex = lines.indexWhere((line) => line.startsWith('root ::= '));
    if (rootIndex == -1) {
      return grammar;
    }

    final rootExpr = lines[rootIndex].substring('root ::= '.length).trim();
    final prefixExpr = prefix.isEmpty ? '' : '${literal(prefix)} ';
    final suffixExpr = suffix.isEmpty ? '' : ' ${literal(suffix)}';
    lines[rootIndex] = 'root ::= $prefixExpr($rootExpr)$suffixExpr';

    return '${lines.join('\n')}\n';
  }

  /// Lets a required-call [grammar] start inside a forced-open thought.
  ///
  /// The grammar applies from the first token, which is reasoning when the
  /// prompt ends with a thinking start tag. As in llama.cpp's reasoning
  /// parser, any text without [endTag] may precede the calls; the end tag is
  /// required because forced-open parsing treats unclosed output as
  /// reasoning.
  static String afterForcedOpenThought(String grammar, String endTag) => [
    for (final line in grammar.trimRight().split('\n'))
      line.startsWith('root ::= ')
          ? 'root ::= think-body ${_literal(endTag)} think-space '
                '(${line.substring('root ::= '.length)})'
          : line,
    ..._excludingRules('think-body', endTag),
    r'think-space ::= | " " | "\n"{1,2} [ \t]{0,20}',
  ].join('\n');

  /// Rules for [name] matching text without [delimiter], as llama.cpp's
  /// `gbnf_excluding_grammar` emits them for a delimiter whose first
  /// character does not recur in it.
  static List<String> _excludingRules(String name, String delimiter) {
    assert(
      delimiter.length > 1 && !delimiter.substring(1).contains(delimiter[0]),
    );
    String state(int i) => i == 0 ? name : '$name-$i';
    String chars(String value) =>
        value.replaceAllMapped(RegExp(r'[\\\]\[^-]'), (m) => '\\${m[0]}');
    final first = chars(delimiter[0]);
    final last = delimiter.length - 1;
    return [
      for (var i = 0; i < delimiter.length; i++)
        '${state(i)} ::= '
            '${i == 0 || i == last ? '' : '| [${chars(delimiter[i])}] ${state(i + 1)} '}'
            '| [$first] ${state(1)} '
            '| [^${i == 0 ? '' : chars(delimiter[i])}$first] $name',
    ];
  }

  static Map<String, dynamic> _buildToolArraySchema(
    List<ToolDefinition> tools, {
    required String nameKey,
    required String argumentsKey,
    String? idKey,
    String? idPattern,
    required bool allowParallelToolCalls,
  }) {
    final itemSchemas = tools
        .map(
          (tool) => _buildToolObjectSchema(
            tool,
            nameKey: nameKey,
            argumentsKey: argumentsKey,
            idKey: idKey,
            idPattern: idPattern,
          ),
        )
        .toList(growable: false);

    final schema = <String, dynamic>{
      'type': 'array',
      'items': itemSchemas.length == 1
          ? itemSchemas.first
          : <String, dynamic>{'anyOf': itemSchemas},
      'minItems': 1,
    };

    if (!allowParallelToolCalls) {
      schema['maxItems'] = 1;
    }

    return schema;
  }

  static Map<String, dynamic> _buildToolObjectSchema(
    ToolDefinition tool, {
    required String nameKey,
    required String argumentsKey,
    String? idKey,
    String? idPattern,
  }) {
    final properties = <String, dynamic>{
      nameKey: <String, dynamic>{'type': 'string', 'const': tool.name},
      argumentsKey: tool.toJsonSchema(),
    };
    final required = <String>[nameKey, argumentsKey];

    if (idKey != null) {
      properties[idKey] = <String, dynamic>{
        'type': 'string',
        if (idPattern != null && idPattern.isNotEmpty) 'pattern': idPattern,
      };
      required.add(idKey);
    }

    return <String, dynamic>{
      'type': 'object',
      'properties': properties,
      'required': required,
    };
  }

  static String _literal(String value) {
    final escaped = value
        .replaceAll('\\', r'\\')
        .replaceAll('"', r'\"')
        .replaceAll('\n', r'\n')
        .replaceAll('\r', r'\r');
    return '"$escaped"';
  }
}
