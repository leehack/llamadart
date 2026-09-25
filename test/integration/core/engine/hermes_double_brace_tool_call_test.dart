@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:llamadart/llamadart.dart';
import 'package:test/test.dart';

import 'tool_calling_integration_test.dart';

class _TemplateBackend extends MockLlamaBackend {
  _TemplateBackend(this.template);

  final String template;

  @override
  Future<Map<String, String>> modelMetadata(int modelHandle) async => {
    'tokenizer.chat_template': template,
  };
}

final Map<String, dynamic> _fixture =
    jsonDecode(
          File(
            'test/fixtures/hermes_double_brace_tool_call.json',
          ).readAsStringSync(),
        )
        as Map<String, dynamic>;
final List<Map<String, dynamic>> _cases = (_fixture['cases'] as List)
    .cast<Map<String, dynamic>>();

final ToolDefinition _weatherTool = ToolDefinition(
  name: 'get_weather',
  description: 'Returns current weather for a city.',
  parameters: [ToolParam.string('city', description: 'City name')],
  handler: (_) async => 'Sunny',
);

void main() {
  final qwen25Template = File(
    _fixture['template'] as String,
  ).readAsStringSync();
  final templates = <String, String>{
    'Qwen2.5': qwen25Template,
    'Qwen3': File('test/fixtures/templates/Qwen3-4B.jinja').readAsStringSync(),
  };

  test('Qwen2.5 template prints the double-brace tool example', () async {
    expect(
      sha256.convert(utf8.encode(qwen25Template)).toString(),
      _fixture['template_sha256'],
    );
    final engine = LlamaEngine(_TemplateBackend(qwen25Template));
    addTearDown(engine.dispose);
    await engine.loadModel('mock-qwen25.gguf');

    final rendered = await engine.chatTemplate(
      [
        LlamaChatMessage.fromText(
          role: LlamaChatRole.user,
          text: _fixture['user_prompt'] as String,
        ),
      ],
      tools: [_weatherTool],
    );

    expect(rendered.format, ChatFormat.hermes.index);
    expect(
      rendered.prompt,
      contains(
        '<tool_call>\n'
        '{{"name": <function-name>, "arguments": <args-json-object>}}\n'
        '</tool_call>',
      ),
    );
  });

  for (final entry in _cases) {
    final name = entry['name'] as String;
    final emission = entry['emission'] as String;
    final expected = entry['expected'] as Map<String, dynamic>;
    final expectedCalls = (expected['tool_calls'] as List)
        .cast<Map<String, dynamic>>();

    test('$name extracts the call that upstream rejects', () {
      final upstream = entry['upstream_result'] as Map<String, dynamic>;
      expect(upstream['tool_calls'], isEmpty);

      final parsed = ChatTemplateEngine.parse(
        ChatFormat.hermes.index,
        emission,
        tools: [_weatherTool],
      );

      expect(parsed.content, expected['content']);
      expect(parsed.toolCalls, hasLength(expectedCalls.length));
      for (var i = 0; i < expectedCalls.length; i++) {
        expect(parsed.toolCalls[i].function?.name, expectedCalls[i]['name']);
        expect(
          jsonDecode(parsed.toolCalls[i].function!.arguments!),
          expectedCalls[i]['arguments'],
        );
      }
    });

    final splits = <String, List<String>>{
      'one piece': [emission],
      'characters': emission.split(''),
      if (entry['pieces'] != null)
        'recorded pieces': (entry['pieces'] as List).cast<String>(),
    };
    for (final MapEntry(key: templateName, value: template)
        in templates.entries) {
      for (final MapEntry(key: splitName, value: pieces) in splits.entries) {
        test(
          '$name on $templateName as $splitName keeps session history clean',
          () async {
            final backend = _TemplateBackend(template);
            final engine = LlamaEngine(backend);
            addTearDown(engine.dispose);
            await engine.loadModel('mock.gguf');
            backend.queueResponse(pieces);
            final session = ChatSession(engine);

            final chunks = await session
                .create(
                  [LlamaTextContent(_fixture['user_prompt'] as String)],
                  tools: [_weatherTool],
                  toolChoice: ToolChoice.auto,
                )
                .toList();

            expect(
              chunks.map((c) => c.choices.single.delta.content ?? '').join(),
              isEmpty,
            );
            final reply = session.history.last;
            expect(reply.role, LlamaChatRole.assistant);
            final call = reply.parts.single as LlamaToolCallContent;
            expect(call.name, expectedCalls.single['name']);
            expect(call.arguments, expectedCalls.single['arguments']);
          },
        );
      }
    }

    test('$name after Qwen3 thinking keeps the reasoning', () async {
      final backend = _TemplateBackend(templates['Qwen3']!);
      final engine = LlamaEngine(backend);
      addTearDown(engine.dispose);
      await engine.loadModel('mock-qwen3.gguf');
      backend.queueResponse([
        '<think>\nParis weather.\n</think>\n\n',
        ...emission.split(''),
      ]);

      final chunks = await engine
          .create(
            [
              LlamaChatMessage.fromText(
                role: LlamaChatRole.user,
                text: _fixture['user_prompt'] as String,
              ),
            ],
            tools: [_weatherTool],
            toolChoice: ToolChoice.auto,
          )
          .toList();

      String join(String? Function(LlamaCompletionChunkDelta) field) =>
          chunks.map((c) => field(c.choices.single.delta) ?? '').join();
      expect(join((d) => d.thinking), 'Paris weather.');
      expect(join((d) => d.content), isEmpty);
      final call = chunks
          .expand((c) => c.choices.single.delta.toolCalls ?? const [])
          .single;
      expect(call.function?.name, expectedCalls.single['name']);
    });
  }
}
