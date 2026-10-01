import 'package:llamadart/src/core/engine/chat_template_renderer.dart';
import 'package:llamadart/src/core/models/chat/chat_message.dart';
import 'package:llamadart/src/core/models/chat/chat_role.dart';
import 'package:llamadart/src/core/models/tools/tool_definition.dart';
import 'package:test/test.dart';

void main() {
  group('ChatTemplateRenderer', () {
    test('renders a template and counts tokens when requested', () async {
      var tokenizeAddSpecial = true;
      final result = await ChatTemplateRenderer.render(
        loadMetadata: () async => const {},
        tokenize: (text, {bool addSpecial = true}) async {
          tokenizeAddSpecial = addSpecial;
          return [1, 2, 3];
        },
        messages: const [
          LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'hello'),
        ],
        customTemplate:
            '{{ messages[0]["role"] }}: {{ messages[0]["content"] }}'
            '{% if add_generation_prompt %} assistant:{% endif %}',
      );

      expect(result.prompt, contains('user: hello'));
      expect(result.prompt, contains('assistant:'));
      expect(result.tokenCount, 3);
      expect(tokenizeAddSpecial, isFalse);
    });

    test('skips token count when tokenization is unsupported', () async {
      final result = await ChatTemplateRenderer.render(
        loadMetadata: () async => const {},
        tokenize: (text, {bool addSpecial = true}) async {
          throw UnsupportedError('tokenization unavailable');
        },
        messages: const [
          LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'hello'),
        ],
        customTemplate: '{{ messages[0]["content"] }}',
      );

      expect(result.prompt, 'hello');
      expect(result.tokenCount, isNull);
    });

    test('modelTemplate replaces the metadata template and its tool_use '
        'variant', () async {
      Future<String> render({
        String? modelTemplate,
        String? customTemplate,
        List<ToolDefinition>? tools,
      }) async {
        final result = await ChatTemplateRenderer.render(
          loadMetadata: () async => {
            'tokenizer.chat_template': 'METADATA:{{ messages[0]["content"] }}',
            'tokenizer.chat_template.tool_use':
                'TOOL_USE:{{ messages[-1]["content"] }}',
          },
          tokenize: (text, {bool addSpecial = true}) async => const [],
          messages: const [
            LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'hello'),
          ],
          tools: tools,
          modelTemplate: modelTemplate,
          customTemplate: customTemplate,
          includeTokenCount: false,
        );
        return result.prompt;
      }

      final tools = [
        ToolDefinition(
          name: 'noop',
          description: 'Does nothing',
          parameters: const [],
          handler: (_) async => null,
        ),
      ];
      const modelTemplate = 'MODEL:{{ messages[-1]["content"] }}';

      expect(await render(), 'METADATA:hello');
      expect(await render(tools: tools), startsWith('TOOL_USE:'));
      expect(await render(modelTemplate: ''), 'METADATA:hello');
      expect(await render(modelTemplate: modelTemplate), 'MODEL:hello');
      expect(
        await render(modelTemplate: modelTemplate, tools: tools),
        startsWith('MODEL:'),
      );
      expect(
        await render(
          modelTemplate: modelTemplate,
          customTemplate: 'CUSTOM:{{ messages[0]["content"] }}',
        ),
        'CUSTOM:hello',
      );
    });

    test('modelTemplate renders when metadata cannot be read', () async {
      final result = await ChatTemplateRenderer.render(
        loadMetadata: () async => throw StateError('no metadata'),
        tokenize: (text, {bool addSpecial = true}) async => const [],
        messages: const [
          LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'hello'),
        ],
        modelTemplate: 'MODEL:{{ messages[0]["content"] }}',
        includeTokenCount: false,
      );

      expect(result.prompt, 'MODEL:hello');
    });
  });
}
