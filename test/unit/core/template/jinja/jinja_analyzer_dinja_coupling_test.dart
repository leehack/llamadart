// ignore: implementation_imports
import 'package:dinja/src/ast/nodes.dart';
// ignore: implementation_imports
import 'package:dinja/src/lexer.dart';
// ignore: implementation_imports
import 'package:dinja/src/parser.dart';
import 'package:test/test.dart';

import 'package:llamadart/src/core/template/jinja/jinja_analyzer.dart';
import 'package:llamadart/src/core/template/template_caps.dart';

/// Guards `jinja_analyzer.dart`'s imports of dinja's private sources: the
/// imports above stop compiling if those files move, and `dinja private-source
/// coupling` fails if the lexer/parser shape or AST node types change.
///
/// The capability goldens are descriptive of the analyzer's current output,
/// not a dinja guarantee - a deliberate analyzer change is expected to update
/// them, and that is not dinja drift.
void main() {
  const representativeTemplate = '''
{% for message in messages %}
{% if message.role == 'system' %}{{ message.content }}{% endif %}
{% if message.tool_calls %}
{% for tool_call in message.tool_calls %}{{ tool_call.function.name }}{% endfor %}
{% endif %}
{% if message.role == 'user' %}
{% for item in message.content %}{% if item.type == 'text' %}{{ item.text }}{% endif %}{% endfor %}
{% endif %}
{% endfor %}
{% for tool in tools %}{{ tool.function.name }}{% endfor %}
''';

  group('dinja private-source coupling', () {
    test('lexer and parser entry points keep the shape the analyzer uses', () {
      // Mirrors the call chain in JinjaAnalyzer.analyze().
      final LexerResult lexed = Lexer(representativeTemplate).tokenize();
      expect(lexed.tokens, isNotEmpty);

      final Program program = Parser(
        lexed.tokens,
        representativeTemplate,
      ).parse();
      expect(program.body, isNotEmpty);
    });

    test('AST node types the analyzer matches on are still produced', () {
      final lexed = Lexer(representativeTemplate).tokenize();
      final program = Parser(lexed.tokens, representativeTemplate).parse();

      final seen = <Type>{};
      void visit(Statement node) {
        seen.add(node.runtimeType);
        if (node is Program) {
          node.body.forEach(visit);
        } else if (node is IfStatement) {
          visit(node.test);
          node.body.forEach(visit);
          node.alternate.forEach(visit);
        } else if (node is ForStatement) {
          visit(node.iterable);
          visit(node.loopVar);
          node.body.forEach(visit);
          node.defaultBlock.forEach(visit);
        } else if (node is BinaryExpression) {
          visit(node.left);
          visit(node.right);
        } else if (node is MemberExpression) {
          visit(node.object);
          visit(node.property);
        }
      }

      visit(program);

      expect(
        seen,
        containsAll(<Type>[
          IfStatement,
          ForStatement,
          BinaryExpression,
          MemberExpression,
          Identifier,
          StringLiteral,
        ]),
        reason: 'JinjaAnalyzer pattern-matches on each of these node types',
      );
    });
  });

  group('JinjaAnalyzer capability goldens', () {
    const cases = <String, String>{
      'full chat template': representativeTemplate,
      'string literal does not imply thinking support':
          '{{ "thinking about it" }}'
          '{% for m in messages %}{{ m.content }}{% endfor %}',
      'typed content parts':
          "{% for part in message['content'] %}"
          "{% if part['type'] == 'image' %}Image{% endif %}"
          '{% endfor %}',
      'bare tools guard': '{% if tools %}tools available{% endif %}',
    };

    const goldens = <String, Map<String, bool>>{
      'full chat template': <String, bool>{
        'supports_system_role': true,
        'supports_tool_calls': true,
        'supports_tools': true,
        'supports_parallel_tool_calls': true,
        'supports_string_content': true,
        'supports_typed_content': true,
        'supports_thinking': false,
      },
      'string literal does not imply thinking support': <String, bool>{
        'supports_system_role': true,
        'supports_tool_calls': false,
        'supports_tools': false,
        'supports_parallel_tool_calls': false,
        'supports_string_content': true,
        'supports_typed_content': false,
        'supports_thinking': false,
      },
      'typed content parts': <String, bool>{
        'supports_system_role': false,
        'supports_tool_calls': false,
        'supports_tools': false,
        'supports_parallel_tool_calls': false,
        'supports_string_content': false,
        'supports_typed_content': true,
        'supports_thinking': false,
      },
      'bare tools guard': <String, bool>{
        'supports_system_role': false,
        'supports_tool_calls': false,
        'supports_tools': false,
        'supports_parallel_tool_calls': false,
        'supports_string_content': true,
        'supports_typed_content': false,
        'supports_thinking': false,
      },
    };

    for (final entry in cases.entries) {
      test('${entry.key} keeps its capability map', () {
        final source = entry.value;
        expect(JinjaAnalyzer.analyze(source).toMap(), goldens[entry.key]);
        expect(
          TemplateCaps.detectRegex(source).toMap(),
          isNot(goldens[entry.key]),
          reason:
              'golden must be unreachable via the regex fallback, otherwise a '
              'broken dinja parse path would still pass',
        );
      });
    }

    test('invalid syntax still falls back to the regex result', () {
      const invalid = "{% if message.role == 'system' %}{{ message.content }}";
      expect(
        JinjaAnalyzer.analyze(invalid).toMap(),
        TemplateCaps.detectRegex(invalid).toMap(),
      );
    });
  });
}
