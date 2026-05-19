import 'dart:typed_data';

import 'package:llamadart/src/core/models/chat/chat_message.dart';
import 'package:llamadart/src/core/models/chat/chat_role.dart';
import 'package:llamadart/src/core/models/chat/content_part.dart';
import 'package:llamadart/src/core/template/chat_format.dart';
import 'package:llamadart/src/core/template/template_workarounds.dart';
import 'package:test/test.dart';

void main() {
  group('TemplateWorkarounds', () {
    test('normalizeToolCallArgs converts string arguments to object', () {
      final messages = [
        <String, dynamic>{
          'role': 'assistant',
          'tool_calls': [
            {
              'type': 'function',
              'function': {'name': 'weather', 'arguments': '{"city":"Seoul"}'},
            },
          ],
        },
      ];

      TemplateWorkarounds.normalizeToolCallArgs(messages);

      final args =
          (messages.first['tool_calls'] as List).first['function']['arguments'];
      expect(args, equals({'city': 'Seoul'}));
    });

    test('normalizeToolCallArgs supports dynamic map values', () {
      final messages = [
        <String, dynamic>{
          'role': 'assistant',
          'tool_calls': [
            {
              'type': 'function',
              'function': {
                'name': 'weather',
                'arguments': <Object, Object>{'city': 'Seoul', 7: true},
              },
            },
          ],
        },
      ];

      TemplateWorkarounds.normalizeToolCallArgs(messages);

      final args =
          (messages.first['tool_calls'] as List).first['function']['arguments'];
      expect(args, equals({'city': 'Seoul', '7': true}));
    });

    test('normalizeToolCallArgs rejects non-object JSON arguments', () {
      final messages = [
        <String, dynamic>{
          'role': 'assistant',
          'tool_calls': [
            {
              'type': 'function',
              'function': {'name': 'weather', 'arguments': '[1,2,3]'},
            },
          ],
        },
      ];

      expect(
        () => TemplateWorkarounds.normalizeToolCallArgs(messages),
        throwsFormatException,
      );
    });

    test('useGenericSchema converts OpenAI tool call shape', () {
      final messages = [
        <String, dynamic>{
          'role': 'assistant',
          'tool_calls': [
            {
              'type': 'function',
              'id': 'call_1',
              'function': {
                'name': 'weather',
                'arguments': {'city': 'Seoul'},
              },
            },
          ],
        },
      ];

      TemplateWorkarounds.useGenericSchema(messages);

      final call = (messages.first['tool_calls'] as List).first;
      expect(
        call,
        equals({
          'name': 'weather',
          'arguments': {'city': 'Seoul'},
          'id': 'call_1',
        }),
      );
    });

    test('moveToolCallsToContent appends JSON and removes tool_calls', () {
      final messages = [
        <String, dynamic>{
          'role': 'assistant',
          'content': 'prefix:',
          'tool_calls': [
            {
              'name': 'weather',
              'arguments': {'city': 'Seoul'},
            },
          ],
        },
      ];

      TemplateWorkarounds.moveToolCallsToContent(messages);

      final message = messages.first;
      expect(message.containsKey('tool_calls'), isFalse);
      expect(message['content'], contains('prefix:'));
      expect(message['content'], contains('"tool_calls"'));
      expect(message['content'], contains('\n  "tool_calls"'));
      expect(message['content'], contains('"weather"'));
    });

    test(
      'applyFormatWorkarounds returns before serializing byte-backed multimodal content without tool calls',
      () {
        final imageBytes = Uint8List.fromList([1, 2, 3, 4]);
        final input = [
          LlamaChatMessage.withContent(
            role: LlamaChatRole.user,
            content: [
              LlamaImageContent(bytes: imageBytes, width: 1, height: 1),
              const LlamaTextContent('Extract text.'),
            ],
          ),
        ];

        final output = TemplateWorkarounds.applyFormatWorkarounds(
          input,
          ChatFormat.glm45,
        );

        expect(identical(output, input), isTrue);
        final image = output.first.parts.whereType<LlamaImageContent>().single;
        expect(identical(image.bytes, imageBytes), isTrue);
        expect(
          output.first.parts.whereType<LlamaTextContent>().single.text,
          equals('Extract text.'),
        );
      },
    );

    test(
      'applyFormatWorkarounds preserves multimodal content when tool calls are normalized',
      () {
        const input = [
          LlamaChatMessage.withContent(
            role: LlamaChatRole.user,
            content: [
              LlamaImageContent(path: '/tmp/page.png'),
              LlamaTextContent('Extract text.'),
            ],
          ),
          LlamaChatMessage.withContent(
            role: LlamaChatRole.assistant,
            content: [
              LlamaToolCallContent(
                id: 'call_1',
                name: 'lookup',
                arguments: {'query': 'ocr'},
                rawJson: '{"query":"ocr"}',
              ),
            ],
          ),
        ];

        final output = TemplateWorkarounds.applyFormatWorkarounds(
          input,
          ChatFormat.glm45,
        );

        expect(output.first.parts[0], isA<LlamaImageContent>());
        expect(
          output.first.parts.whereType<LlamaTextContent>().single.text,
          equals('Extract text.'),
        );
        final toolCall = output.last.parts
            .whereType<LlamaToolCallContent>()
            .single;
        expect(toolCall.name, equals('lookup'));
        expect(toolCall.arguments, equals({'query': 'ocr'}));
      },
    );

    test(
      'applyFormatWorkarounds preserves audio content when tool calls are normalized',
      () {
        final audioBytes = Uint8List.fromList([82, 73, 70, 70]);
        final input = [
          LlamaChatMessage.withContent(
            role: LlamaChatRole.user,
            content: [
              LlamaAudioContent(bytes: audioBytes),
              const LlamaTextContent('Transcribe audio.'),
            ],
          ),
          const LlamaChatMessage.withContent(
            role: LlamaChatRole.assistant,
            content: [
              LlamaToolCallContent(
                id: 'call_1',
                name: 'lookup',
                arguments: {'query': 'audio'},
                rawJson: '{"query":"audio"}',
              ),
            ],
          ),
        ];

        final output = TemplateWorkarounds.applyFormatWorkarounds(
          input,
          ChatFormat.glm45,
        );

        final audio = output.first.parts.whereType<LlamaAudioContent>().single;
        expect(identical(audio.bytes, audioBytes), isTrue);
        expect(
          output.first.parts.whereType<LlamaTextContent>().single.text,
          equals('Transcribe audio.'),
        );
        final toolCall = output.last.parts
            .whereType<LlamaToolCallContent>()
            .single;
        expect(toolCall.name, equals('lookup'));
        expect(toolCall.arguments, equals({'query': 'audio'}));
      },
    );

    test('applyFormatWorkarounds applies Granite chain', () {
      final input = [
        LlamaChatMessage.withContent(
          role: LlamaChatRole.assistant,
          content: [
            const LlamaToolCallContent(
              name: 'weather',
              arguments: {'city': 'Seoul'},
              rawJson: '{"city":"Seoul"}',
            ),
          ],
        ),
      ];

      final output = TemplateWorkarounds.applyFormatWorkarounds(
        input,
        ChatFormat.granite,
      );

      final json = output.first.toJson();
      expect(json.containsKey('tool_calls'), isFalse);
      expect(json['content'], isA<String>());
      expect(json['content'], contains('"tool_calls"'));
      expect(json['content'], contains('"weather"'));
    });
  });
}
