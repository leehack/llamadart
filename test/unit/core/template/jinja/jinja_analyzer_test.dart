import 'package:test/test.dart';
import 'package:llamadart/src/core/llama_logger.dart';
import 'package:llamadart/src/core/models/config/log_level.dart';
import 'package:llamadart/src/core/template/jinja/jinja_analyzer.dart';

void main() {
  group('JinjaAnalyzer', () {
    test('detects capabilities in valid Jinja template', () {
      final template = '''
        {% for message in messages %}
          {% if message.role == 'system' %}
            {{ message.content }}
          {% endif %}
          {% if message.tool_calls %}
            {% for tool_call in message.tool_calls %}
               {{ tool_call.function.name }}
            {% endfor %}
          {% endif %}
          {% if message.role == 'user' %}
             {% for item in message.content %}
               {% if item.type == 'text' %}
                 {{ item.text }}
               {% endif %}
             {% endfor %}
          {% endif %}
        {% endfor %}
      ''';

      final caps = JinjaAnalyzer.analyze(template);

      expect(
        caps.supportsSystemRole,
        isTrue,
        reason: 'Should detect message.role == system',
      );
      expect(
        caps.supportsToolCalls,
        isTrue,
        reason: 'Should detect message.tool_calls iteration',
      );
      expect(
        caps.supportsTypedContent,
        isTrue,
        reason: 'Should detect item.type == text check',
      );
      expect(caps.supportsThinking, isFalse);
    });

    test('detects thinking tags', () {
      final template = '{{ "<think>" + message.content + "</think>" }}';
      final caps = JinjaAnalyzer.analyze(template);
      expect(caps.supportsThinking, isTrue);
    });

    test('detects thinking tags in raw data', () {
      final template = 'Raw text with <think> tag inside.';
      final caps = JinjaAnalyzer.analyze(template);
      expect(caps.supportsThinking, isTrue);
    });

    test('detects Gemma 4 thinking tags', () {
      final template = '{{ "<|think|>" + message.content }}';
      final caps = JinjaAnalyzer.analyze(template);
      expect(caps.supportsThinking, isTrue);
    });

    test('falls back to regex for invalid Jinja', () {
      // Invalid syntax: missing end tag
      final template = '''
        {% if message.role == 'system' %}
          {{ message.content }}
        {# Missing endif #}
      ''';

      // This should throw error in parser, caught by analyzer, falling back to regex.
      // Regex should still find 'system'.

      final caps = JinjaAnalyzer.analyze(template);
      expect(
        caps.supportsSystemRole,
        isTrue,
        reason: 'Fallback regex should detect system',
      );
    });

    test('detects tools variable iteration', () {
      final template =
          '{% for tool in tools %}{{ tool.function.name }}{% endfor %}';
      final caps = JinjaAnalyzer.analyze(template);
      // llama.cpp caps: tools access does not imply message.tool_calls support.
      expect(caps.supportsToolCalls, isFalse);
      expect(caps.supportsTools, isTrue);
    });

    test('detects message["role"] syntax', () {
      final template = '''
        {% for message in messages %}
          {% if message['role'] == 'system' %}
            System: {{ message['content'] }}
          {% endif %}
        {% endfor %}
      ''';
      final caps = JinjaAnalyzer.analyze(template);
      expect(caps.supportsSystemRole, isTrue);
    });

    test('detects content["type"] syntax', () {
      final template = '''
        {% for part in message['content'] %}
          {% if part['type'] == 'image' %}
             Image...
          {% endif %}
        {% endfor %}
      ''';
      final caps = JinjaAnalyzer.analyze(template);
      expect(caps.supportsTypedContent, isTrue);
    });

    test('requires tool name usage for supportsTools', () {
      final template = '{% if tools %}tools available{% endif %}';
      final caps = JinjaAnalyzer.analyze(template);
      expect(caps.supportsTools, isFalse);
    });

    test('requires tool call name usage for supportsToolCalls', () {
      final template = '{% if messages[1].tool_calls %}calls{% endif %}';
      final caps = JinjaAnalyzer.analyze(template);
      expect(caps.supportsToolCalls, isFalse);
      expect(caps.supportsParallelToolCalls, isFalse);
    });

    test(
      'does not treat raw content stringification as typed content support',
      () {
        final template = '{{ messages[0].content }}';
        final caps = JinjaAnalyzer.analyze(template);
        expect(caps.supportsStringContent, isTrue);
        expect(caps.supportsTypedContent, isFalse);
      },
    );
  });

  group('JinjaAnalyzer probe render failures', () {
    late List<String> messages;

    setUp(() {
      messages = <String>[];
      LlamaLogger.instance.setLevel(LlamaLogLevel.debug);
      LlamaLogger.instance.setHandler((record) => messages.add(record.message));
    });

    tearDown(() {
      LlamaLogger.instance.setHandler(null);
      LlamaLogger.instance.setLevel(LlamaLogLevel.none);
    });

    test('logs the labelled probe when the system-role render throws', () {
      const template = '''
{% for message in messages %}
{% if message.role == 'system' %}{{ message.content | no_such_filter }}{% endif %}
{% endfor %}
''';

      final caps = JinjaAnalyzer.analyze(template);

      expect(caps.supportsSystemRole, isFalse);
      expect(
        messages,
        contains(
          allOf(
            contains('system-role capability probe failed to render'),
            contains('no_such_filter'),
          ),
        ),
      );
    });

    test('logs the labelled probe when the tools render throws', () {
      const template = '''
{% for message in messages %}{{ message.content }}{% endfor %}
{% for tool in tools %}{{ tool.function.name | no_such_filter }}{% endfor %}
''';

      final caps = JinjaAnalyzer.analyze(template);

      expect(caps.supportsTools, isFalse);
      expect(caps.supportsToolCalls, isFalse);
      expect(caps.supportsParallelToolCalls, isFalse);
      expect(
        messages,
        contains(contains('tools capability probe failed to render')),
      );
    });

    test('stays silent when a template merely lacks the capability', () {
      const template =
          '{% for message in messages %}'
          '{{ message.content }}{% endfor %}';

      final caps = JinjaAnalyzer.analyze(template);

      expect(caps.supportsTools, isFalse);
      expect(caps.supportsToolCalls, isFalse);
      expect(
        messages,
        isNot(contains(contains('capability probe failed to render'))),
      );
    });
  });
}
