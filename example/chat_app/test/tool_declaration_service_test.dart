import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_chat_example/services/host_tool_service.dart';
import 'package:llamadart_chat_example/services/tool_declaration_service.dart';

void main() {
  const service = ToolDeclarationService();

  group('ToolDeclarationService', () {
    test('normalizes blank declarations to an empty array', () {
      expect(service.normalizeDeclarations('   '), '[]');
      expect(service.normalizeDeclarations('[{"name":"a"}]'), '[{"name":"a"}]');
    });

    test('parses OpenAI function-style declarations', () {
      final tools = service.parseDefinitions(
        '''
[
  {
    "type": "function",
    "function": {
      "name": "getWeather",
      "description": "Get weather for a city",
      "parameters": {
        "type": "object",
        "properties": {
          "city": {"type": "string"}
        },
        "required": ["city"]
      }
    }
  }
]
''',
        handlerFor: (String _) =>
            (ToolParams _) async => 'ok',
      );

      expect(tools, hasLength(1));
      final tool = tools.first;
      expect(tool.name, 'getWeather');
      expect(tool.description, 'Get weather for a city');
      expect(tool.parameters, hasLength(1));
      expect(tool.parameters.first.name, 'city');
      expect(tool.parameters.first.required, isTrue);
      expect(tool.parameters.first.toJsonSchema()['type'], 'string');
    });

    test('returns readable parser errors', () {
      expect(
        () => service.parseDefinitions(
          'not-json',
          handlerFor: (String _) =>
              (ToolParams _) async => null,
        ),
        throwsFormatException,
      );

      final error = service.formatError(
        const FormatException('bad declaration'),
        fallback: 'invalid',
      );
      expect(error, 'bad declaration');

      final fallback = service.formatError(
        Exception('boom'),
        fallback: 'invalid',
      );
      expect(fallback, 'invalid');
    });

    test('rejects duplicate declaration names after normalization', () {
      expect(
        () => service.parseDefinitions(
          '[{"name":"getWeather"},{"name":" getWeather "}]',
          handlerFor: (String _) =>
              (ToolParams _) async => null,
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('duplicates the name'),
          ),
        ),
      );
    });

    test('rejects required properties absent from their schema', () {
      expect(
        () => service.parseDefinitions(
          '''
[
  {
    "name": "getWeather",
    "parameters": {
      "type": "object",
      "properties": {"city": {"type": "string"}},
      "required": ["missing"]
    }
  }
]
''',
          handlerFor: (String _) =>
              (ToolParams _) async => null,
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('required list contains undeclared properties'),
          ),
        ),
      );
    });

    test('rejects required properties when properties is absent', () {
      expect(
        () => service.parseDefinitions(
          '''
[
  {
    "name": "getWeather",
    "parameters": {
      "type": "object",
      "required": ["city"]
    }
  }
]
''',
          handlerFor: (String _) =>
              (ToolParams _) async => null,
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('required list contains undeclared properties'),
          ),
        ),
      );
    });
  });

  group('HostToolService', () {
    const host = HostToolService();

    test('returns a deterministic clearly simulated weather result', () async {
      final first =
          await host.getWeather(
                ToolParams(<String, dynamic>{'city': 'Montréal'}),
              )
              as Map<String, Object?>;
      final second =
          await host.getWeather(
                ToolParams(<String, dynamic>{'city': 'Montréal'}),
              )
              as Map<String, Object?>;

      expect(second, first);
      expect(first['simulated'], isTrue);
      expect(first['source'], contains('not live weather data'));
    });

    test('arbitrary declaration names resolve to an explicit error', () async {
      final result =
          await host.handlerFor('launchRocket')(ToolParams(<String, dynamic>{}))
              as Map<String, Object?>;

      expect(result['error'], 'unsupported_tool');
      expect(result['message'], contains('nothing was executed'));
    });
  });
}
