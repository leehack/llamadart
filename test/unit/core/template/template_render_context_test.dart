import 'dart:convert';
import 'dart:typed_data';

import 'package:llamadart/src/core/models/chat/chat_message.dart';
import 'package:llamadart/src/core/models/chat/chat_role.dart';
import 'package:llamadart/src/core/models/chat/content_part.dart';
import 'package:llamadart/src/core/template/template_render_context.dart';
import 'package:test/test.dart';

void main() {
  group('TemplateRenderContext', () {
    for (final payload in <Object?>[
      {
        'city': 'Montréal 👋',
        'quote': '"line\\next\n',
        'nested': [17, true, null],
      },
      [
        1,
        {'value': '한글'},
      ],
      17,
      1.5,
      false,
      null,
      'unchanged "text" 👋',
    ]) {
      for (final multimodal in [false, true]) {
        test(
          'serializes typed tool result ${payload.runtimeType}, multimodal=$multimodal',
          () {
            final part = LlamaToolResultContent(
              id: 'call_0',
              name: 'get_weather',
              result: payload,
            );
            final message = LlamaChatMessage.withContent(
              role: LlamaChatRole.tool,
              content: [part],
            );
            final before = message.toJson();
            final rendered = TemplateRenderContext.messagesForTemplate([
              message,
            ], multimodal: multimodal).single;
            final expected = payload is String ? payload : jsonEncode(payload);
            expect(
              rendered['content'],
              multimodal
                  ? [
                      {'type': 'text', 'text': expected},
                    ]
                  : expected,
            );
            expect(rendered['tool_call_id'], 'call_0');
            expect(rendered['name'], 'get_weather');
            expect(message.toJson(), before);
            expect(identical(part.result, payload), true);
          },
        );
      }
    }
    for (final multimodal in [false, true]) {
      test('renders one tool message per tool result, '
          'multimodal=$multimodal', () {
        const message = LlamaChatMessage.withContent(
          role: LlamaChatRole.tool,
          content: [
            LlamaToolResultContent(
              id: 'call_0',
              name: 'get_weather',
              result: 'RESULT_ONE',
            ),
            LlamaToolResultContent(
              id: 'call_1',
              name: 'get_time',
              result: {'value': 'RESULT_TWO'},
            ),
          ],
        );
        Object content(String text) => multimodal
            ? [
                {'type': 'text', 'text': text},
              ]
            : text;

        expect(
          TemplateRenderContext.messagesForTemplate([
            message,
          ], multimodal: multimodal),
          [
            {
              'role': 'tool',
              'tool_call_id': 'call_0',
              'name': 'get_weather',
              'content': content('RESULT_ONE'),
            },
            {
              'role': 'tool',
              'tool_call_id': 'call_1',
              'name': 'get_time',
              'content': content('{"value":"RESULT_TWO"}'),
            },
          ],
        );
      });
    }

    group('splitToolResults', () {
      test('returns messages with at most one result unchanged', () {
        const messages = [
          LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'hi'),
          LlamaChatMessage.withContent(
            role: LlamaChatRole.tool,
            content: [LlamaToolResultContent(name: 'a', result: 'A')],
          ),
        ];

        expect(
          TemplateRenderContext.splitToolResults(messages),
          same(messages),
        );
      });

      test('keeps other parts, role and turn marker with the first result', () {
        const thinking = LlamaThinkingContent('why');
        const first = LlamaToolResultContent(name: 'a', result: 'A');
        const second = LlamaToolResultContent(name: 'b', result: 'B');
        const text = LlamaTextContent('note');
        const user = LlamaChatMessage.fromText(
          role: LlamaChatRole.user,
          text: 'hi',
        );

        final split = TemplateRenderContext.splitToolResults(const [
          user,
          LlamaChatMessage.withContent(
            role: LlamaChatRole.user,
            content: [thinking, first, second, text],
            continuesPreviousTurn: true,
          ),
        ]);

        expect(split, hasLength(3));
        expect(split[0], same(user));
        expect(split[1].parts, [thinking, first, text]);
        expect(split[2].parts, [second]);
        for (final message in split.skip(1)) {
          expect(message.role, LlamaChatRole.user);
          expect(message.continuesPreviousTurn, isTrue);
        }
      });

      test('splits repeated identical results', () {
        const result = LlamaToolResultContent(name: 'a', result: 'A');

        final split = TemplateRenderContext.splitToolResults(const [
          LlamaChatMessage.withContent(
            role: LlamaChatRole.tool,
            content: [result, result],
          ),
        ]);

        expect(split.map((message) => message.parts), [
          [result],
          [result],
        ]);
      });
    });

    test(
      'tool-result normalization does not stringify ordinary media parts',
      () {
        final message = LlamaChatMessage.withContent(
          role: LlamaChatRole.user,
          content: [
            const LlamaTextContent('look 👋'),
            LlamaImageContent(bytes: Uint8List.fromList([1, 2, 3])),
          ],
        );
        expect(
          TemplateRenderContext.messagesForTemplate([message]).single,
          message.toJson(),
        );
        expect(
          TemplateRenderContext.messagesForTemplate([
            message,
          ], multimodal: true).single,
          message.toJsonMultimodal(),
        );
      },
    );

    test('serializes tool-call policy without mutating typed messages', () {
      final imageBytes = Uint8List.fromList([1, 2, 3, 4]);
      final messages = [
        LlamaChatMessage.withContent(
          role: LlamaChatRole.user,
          content: [
            LlamaImageContent(bytes: imageBytes, width: 1, height: 1),
            const LlamaTextContent('Extract text.'),
          ],
        ),
        const LlamaChatMessage.withContent(
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

      final renderedMessages = TemplateRenderContext.messagesForTemplate(
        messages,
        toolCallSerialization: const TemplateToolCallSerialization(
          normalizeArguments: true,
          useGenericSchema: true,
          moveToolCallsToContent: true,
        ),
      );

      final sourceImage = messages.first.parts
          .whereType<LlamaImageContent>()
          .single;
      expect(identical(sourceImage.bytes, imageBytes), isTrue);
      expect(messages.last.parts, contains(isA<LlamaToolCallContent>()));

      final userContent = renderedMessages.first['content'] as List;
      expect(
        userContent.first['image_url']['url'],
        startsWith('data:image/jpeg;base64,'),
      );
      expect(
        userContent.last,
        equals({'type': 'text', 'text': 'Extract text.'}),
      );

      final assistantMessage = renderedMessages.last;
      expect(assistantMessage.containsKey('tool_calls'), isFalse);
      final content = assistantMessage['content'] as String;
      expect(content, contains('"tool_calls"'));
      expect(content, contains('"lookup"'));
      expect(content, contains('"query"'));
    });

    test('normalizes function arguments only in the render-context maps', () {
      const messages = [
        LlamaChatMessage.withContent(
          role: LlamaChatRole.assistant,
          content: [
            LlamaToolCallContent(
              name: 'weather',
              arguments: {'city': 'Seoul'},
              rawJson: '{"city":"Seoul"}',
            ),
          ],
        ),
      ];

      final renderedMessages = TemplateRenderContext.messagesForTemplate(
        messages,
        toolCallSerialization: const TemplateToolCallSerialization(
          normalizeArguments: true,
        ),
      );

      final call = (renderedMessages.single['tool_calls'] as List).single;
      expect(call['function']['arguments'], equals({'city': 'Seoul'}));
      final originalCall = messages.single.parts
          .whereType<LlamaToolCallContent>()
          .single;
      expect(originalCall.rawJson, equals('{"city":"Seoul"}'));
    });

    test('normalizes map tool-call arguments with non-string keys', () {
      final messages = [
        <String, dynamic>{
          'role': 'assistant',
          'tool_calls': [
            {
              'type': 'function',
              'function': {
                'name': 'lookup',
                'arguments': <Object?, Object?>{1: 'one', 'city': 'Seoul'},
              },
            },
          ],
        },
      ];

      TemplateRenderContext.normalizeToolCallArgs(messages);

      final call = (messages.single['tool_calls'] as List).single;
      expect(
        call['function']['arguments'],
        equals({'1': 'one', 'city': 'Seoul'}),
      );
    });

    test('rejects non-object JSON tool-call arguments', () {
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
        () => TemplateRenderContext.normalizeToolCallArgs(messages),
        throwsFormatException,
      );
    });

    test(
      'merges leading system message without losing following typed parts',
      () {
        const messages = [
          LlamaChatMessage.fromText(
            role: LlamaChatRole.system,
            text: 'You are concise.',
          ),
          LlamaChatMessage.withContent(
            role: LlamaChatRole.user,
            content: [
              LlamaImageContent(path: '/tmp/page.png'),
              LlamaTextContent('Extract text.'),
            ],
          ),
        ];

        final merged = TemplateRenderContext.mergeLeadingSystemMessage(
          messages,
          supportsSystemRole: false,
        );

        expect(merged, hasLength(1));
        expect(merged.single.role, equals(LlamaChatRole.user));
        expect(
          merged.single.parts.whereType<LlamaImageContent>(),
          hasLength(1),
        );
        expect(
          merged.single.parts.map((part) => part.runtimeType),
          equals([LlamaTextContent, LlamaImageContent, LlamaTextContent]),
        );
        expect(
          merged.single.parts.whereType<LlamaTextContent>().map(
            (part) => part.text,
          ),
          equals(['You are concise.', 'Extract text.']),
        );
      },
    );

    test(
      'can encode moved tool calls compactly for template compatibility',
      () {
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

        TemplateRenderContext.moveToolCallsToContent(messages, indentSpaces: 0);

        expect(messages.single.containsKey('tool_calls'), isFalse);
        expect(
          messages.single['content'],
          equals(
            'prefix:${jsonEncode({
              'tool_calls': [
                {
                  'name': 'weather',
                  'arguments': {'city': 'Seoul'},
                },
              ],
            })}',
          ),
        );
      },
    );

    test(
      'keeps only text from list content in text-oriented tool-call moves',
      () {
        final messages = [
          <String, dynamic>{
            'role': 'assistant',
            'content': [
              {
                'type': 'image_url',
                'image_url': {'url': 'data:image/jpeg;base64,abc'},
              },
              {
                'type': 'image_url',
                'image_url': {'url': 'file:///tmp/page.png'},
              },
              {'type': 'text', 'text': 'prefix:'},
            ],
            'tool_calls': [
              {
                'name': 'weather',
                'arguments': {'city': 'Seoul'},
              },
            ],
          },
        ];

        TemplateRenderContext.moveToolCallsToContent(messages, indentSpaces: 0);

        expect(messages.single.containsKey('tool_calls'), isFalse);
        final content = messages.single['content'];
        expect(content, isA<String>());
        expect(content, contains('prefix:'));
        expect(content, contains('"tool_calls"'));
        expect(content, contains('weather'));
        expect(content, isNot(contains('image_url')));
        expect(content, isNot(contains('data:image')));
        expect(content, isNot(contains('file:///tmp/page.png')));
      },
    );

    test(
      'keeps list content structured when explicitly preserving content parts',
      () {
        final messages = [
          <String, dynamic>{
            'role': 'assistant',
            'content': [
              {
                'type': 'image_url',
                'image_url': {'url': 'data:image/jpeg;base64,abc'},
              },
              {'type': 'text', 'text': 'prefix:'},
            ],
            'tool_calls': [
              {
                'name': 'weather',
                'arguments': {'city': 'Seoul'},
              },
            ],
          },
        ];

        TemplateRenderContext.moveToolCallsToContent(
          messages,
          indentSpaces: 0,
          preserveContentList: true,
        );

        expect(messages.single.containsKey('tool_calls'), isFalse);
        final content = messages.single['content'];
        expect(content, isA<List>());
        expect(content, hasLength(3));
        expect(content.first['type'], equals('image_url'));
        expect(content[1], equals({'type': 'text', 'text': 'prefix:'}));
        expect(content.last['type'], equals('text'));
        expect(content.last['text'], contains('"tool_calls"'));
      },
    );

    test('keeps moved tool calls as text parts for multimodal contexts', () {
      const messages = [
        LlamaChatMessage.withContent(
          role: LlamaChatRole.assistant,
          content: [
            LlamaTextContent('prefix:'),
            LlamaToolCallContent(
              name: 'weather',
              arguments: {'city': 'Seoul'},
              rawJson: '{"city":"Seoul"}',
            ),
          ],
        ),
      ];

      final renderedMessages = TemplateRenderContext.messagesForTemplate(
        messages,
        toolCallSerialization:
            TemplateToolCallSerialization.genericSchemaInContent,
        multimodal: true,
      );

      expect(renderedMessages.single.containsKey('tool_calls'), isFalse);
      final content = renderedMessages.single['content'];
      expect(content, isA<List>());
      expect(content, hasLength(2));
      expect(content.first, equals({'type': 'text', 'text': 'prefix:'}));
      expect(content.last['type'], equals('text'));
      expect(content.last['text'], contains('"tool_calls"'));
      expect(content.last['text'], contains('"weather"'));
    });

    test(
      'preserves audio parts when moving tool calls for multimodal contexts',
      () {
        const messages = [
          LlamaChatMessage.withContent(
            role: LlamaChatRole.assistant,
            content: [
              LlamaAudioContent(path: '/tmp/prompt.wav'),
              LlamaTextContent('prefix:'),
              LlamaToolCallContent(
                name: 'transcribe_hint',
                arguments: {'language': 'ko'},
                rawJson: '{"language":"ko"}',
              ),
            ],
          ),
        ];

        final renderedMessages = TemplateRenderContext.messagesForTemplate(
          messages,
          toolCallSerialization:
              TemplateToolCallSerialization.genericSchemaInContent,
          multimodal: true,
        );

        expect(renderedMessages.single.containsKey('tool_calls'), isFalse);
        final content = renderedMessages.single['content'];
        expect(content, isA<List>());
        expect(content, hasLength(3));
        expect(content.first, equals({'type': 'audio'}));
        expect(content[1], equals({'type': 'text', 'text': 'prefix:'}));
        expect(content.last['type'], equals('text'));
        expect(content.last['text'], contains('"tool_calls"'));
        expect(content.last['text'], contains('transcribe_hint'));
      },
    );
  });
}
