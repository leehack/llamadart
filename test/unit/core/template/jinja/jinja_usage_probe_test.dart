import 'package:dinja/ast.dart';
import 'package:dinja/dinja.dart';
import 'package:llamadart/src/core/template/jinja/jinja_usage_probe.dart';
import 'package:test/test.dart';

JinjaUsageRun _render(String source, Map<String, JinjaValue> context) =>
    JinjaUsageProbe(parseTemplate(source)).render(context);

JinjaMap _message(Object? content) =>
    val(<String, Object?>{'role': 'user', 'content': content}) as JinjaMap;

JinjaValue _content(JinjaMap message) => message.items[val('content')]!;

void main() {
  group('JinjaUsageProbe', () {
    test('renders the same text as the template', () {
      final message = _message('hi');
      final run = _render(
        "A{{ messages[0].content | upper }}{% if x is not defined %}-{% endif %}"
        "{% for i in range(2) %}{{ i }}{% endfor %}{{ 'q\\'s' }}{# c #}B",
        {
          'messages': JinjaList(<JinjaValue>[message]),
        },
      );

      expect(run.success, isTrue);
      expect(run.error, isNull);
      expect(run.output, "AHI-01q'sB");
    });

    test('records only the values the template reads', () {
      final read = _message('read');
      final unread = _message('unread');
      final run = _render('{{ messages[0].content }}', {
        'messages': JinjaList(<JinjaValue>[read, unread]),
      });

      expect(run.used(_content(read)), isTrue);
      expect(run.used(_content(unread)), isFalse);
      expect(run.ops(read), containsAll(<String>['object_access']));
    });

    test('records for loops and integer subscripts as array access', () {
      final looped = _message(<Object?>[]);
      final indexed = _message(<Object?>[
        <String, Object?>{'type': 'text', 'text': 'x'},
      ]);
      final run = _render(
        '{% for p in messages[0].content %}{% endfor %}'
        '{{ messages[1].content[0].text }}',
        {
          'messages': JinjaList(<JinjaValue>[looped, indexed]),
        },
      );

      expect(run.ops(_content(looped)), contains('array_access'));
      expect(run.ops(_content(indexed)), contains('array_access'));
    });

    test('throws on a for loop over a string, as llama.cpp does', () {
      final message = _message('text');
      final run = _render(
        '{% for p in messages[0].content %}{{ p }}{% endfor %}',
        {
          'messages': JinjaList(<JinjaValue>[message]),
        },
      );

      expect(run.success, isFalse);
      expect(run.output, isEmpty);
      expect(run.error.toString(), contains('got String'));
      expect(run.ops(_content(message)), contains('array_access'));
    });

    test('records filter names and tests', () {
      final message = _message('text');
      final run = _render(
        '{% if messages[0].content is string %}'
        '{{ messages[0].content | trim }}{% endif %}',
        {
          'messages': JinjaList(<JinjaValue>[message]),
        },
      );

      expect(
        run.ops(_content(message)),
        containsAll(<String>['test_is_string', 'trim']),
      );
    });

    test('marks every nested value used when tojson reads a value', () {
      final tools =
          val(<Object?>[
                <String, Object?>{
                  'function': <String, Object?>{'name': 'tool1'},
                },
              ])
              as JinjaList;
      final function =
          (tools.items.single as JinjaMap).items[val('function')] as JinjaMap;
      final run = _render('{{ tools | tojson }}', {'tools': tools});

      expect(run.used(function.items[val('name')]!), isTrue);
    });

    test('keeps what a throwing render read before it threw', () {
      final message = _message('text');
      final run = _render(
        "{{ messages[0].content }}{{ raise_exception('no') }}",
        {
          'messages': JinjaList(<JinjaValue>[message]),
        },
      );

      expect(run.success, isFalse);
      expect(run.error, isNotNull);
      expect(run.used(_content(message)), isTrue);
    });
  });
}
