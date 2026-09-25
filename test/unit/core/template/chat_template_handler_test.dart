import 'package:dinja/dinja.dart';
import 'package:llamadart/src/core/models/chat/chat_message.dart';
import 'package:llamadart/src/core/models/chat/chat_role.dart';
import 'package:llamadart/src/core/models/chat/chat_template_result.dart';
import 'package:llamadart/src/core/models/chat/content_part.dart';
import 'package:llamadart/src/core/models/tools/tool_definition.dart';
import 'package:llamadart/src/core/template/chat_format.dart';
import 'package:llamadart/src/core/template/chat_parse_result.dart';
import 'package:llamadart/src/core/template/chat_template_engine.dart';
import 'package:llamadart/src/core/template/chat_template_handler.dart';
import 'package:llamadart/src/core/template/template_internal_metadata.dart';
import 'package:test/test.dart';

void main() {
  test('renderTemplate injects chat_template_kwargs metadata', () {
    final handler = _FakeHandler();
    final output = handler.renderTemplate(
      Template('{{ foo }} {{ bar }}'),
      metadata: const {
        internalChatTemplateKwargsMetadataKey: '{"foo":"from-metadata"}',
      },
      context: const {'bar': 'from-context'},
    );

    expect(output, 'from-metadata from-context');
  });

  test('renderTemplate ignores invalid chat_template_kwargs metadata', () {
    final handler = _FakeHandler();
    final output = handler.renderTemplate(
      Template('{{ bar }}'),
      metadata: const {internalChatTemplateKwargsMetadataKey: '{not-json'},
      context: const {'bar': 'from-context'},
    );

    expect(output, 'from-context');
  });

  group('templates that read tool-call arguments as objects', () {
    const template =
        '{%- for message in messages -%}'
        '{%- for call in message.tool_calls or [] -%}'
        '{{ call.function.name }}:{{ call.function.arguments | tojson }};'
        '{%- endfor -%}'
        '{%- endfor -%}';
    const messages = <LlamaChatMessage>[
      LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'Weather?'),
      LlamaChatMessage.withContent(
        role: LlamaChatRole.assistant,
        content: <LlamaContentPart>[
          LlamaToolCallContent(
            id: 'call_0',
            name: 'get_weather',
            arguments: <String, dynamic>{'city': 'Paris'},
            rawJson: '{"city":"Paris"}',
          ),
        ],
      ),
    ];
    // These handlers move tool calls into message content as JSON text.
    const toolCallsInContent = <ChatFormat>{
      ChatFormat.generic,
      ChatFormat.granite,
    };

    for (final format in ChatFormat.values) {
      if (toolCallsInContent.contains(format)) continue;
      test('get parsed arguments from the ${format.name} handler', () {
        final result = ChatTemplateEngine.handlerFor(format).render(
          templateSource: template,
          messages: messages,
          metadata: const <String, String>{},
          addAssistant: false,
        );

        expect(result.prompt, contains('get_weather:{"city": "Paris"};'));
      });
    }
  });
}

class _FakeHandler extends ChatTemplateHandler {
  @override
  List<String> get additionalStops => const <String>[];

  @override
  ChatFormat get format => ChatFormat.generic;

  @override
  String? buildGrammar(List<ToolDefinition>? tools) {
    return null;
  }

  @override
  ChatParseResult parse(
    String output, {
    bool isPartial = false,
    bool parseToolCalls = true,
    bool thinkingForcedOpen = false,
  }) {
    return ChatParseResult(content: output);
  }

  @override
  LlamaChatTemplateResult render({
    required String templateSource,
    required List<LlamaChatMessage> messages,
    required Map<String, String> metadata,
    bool addAssistant = true,
    List<ToolDefinition>? tools,
    bool enableThinking = true,
  }) {
    throw UnimplementedError();
  }
}
