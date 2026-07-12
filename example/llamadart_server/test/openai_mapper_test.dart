import 'package:llamadart/llamadart.dart';
import 'package:llamadart_server/llamadart_server.dart';
import 'package:test/test.dart';

void main() {
  group('parseChatCompletionRequest', () {
    test('parses a request with explicit sampling overrides', () {
      final request = parseChatCompletionRequest(<String, dynamic>{
        'model': 'llamadart-local',
        'messages': <Map<String, dynamic>>[
          <String, dynamic>{'role': 'system', 'content': 'You are concise.'},
          <String, dynamic>{'role': 'user', 'content': 'Say hello.'},
        ],
        'max_tokens': 64,
        'temperature': 0.2,
        'top_p': 0.8,
        'seed': 42,
        'stop': <String>['END'],
        'enable_thinking': true,
        'parallel_tool_calls': true,
      }, configuredModelId: 'llamadart-local');

      expect(request.stream, isFalse);
      expect(request.messages, hasLength(2));
      expect(request.params.maxTokens, 64);
      expect(request.params.temp, 0.2);
      expect(request.params.topP, 0.8);
      expect(request.params.penalty, 1.0);
      expect(request.params.seed, 42);
      expect(request.params.stopSequences, <String>['END']);
      expect(request.enableThinking, isTrue);
      expect(request.parallelToolCalls, isTrue);
    });

    test('uses the Qwen non-thinking profile by default', () {
      final request = parseChatCompletionRequest(<String, dynamic>{
        'model': 'llamadart-local',
        'messages': <Map<String, dynamic>>[
          <String, dynamic>{'role': 'user', 'content': 'Say hello.'},
        ],
      }, configuredModelId: 'llamadart-local');

      expect(request.enableThinking, isFalse);
      expect(request.parallelToolCalls, isFalse);
      expect(request.params.temp, 0.7);
      expect(request.params.topK, 20);
      expect(request.params.topP, 0.8);
      expect(request.params.minP, 0.0);
      expect(request.params.penalty, 1.0);
    });

    test('uses the Qwen thinking profile when enabled', () {
      final request = parseChatCompletionRequest(<String, dynamic>{
        'model': 'llamadart-local',
        'messages': <Map<String, dynamic>>[
          <String, dynamic>{'role': 'user', 'content': 'Think carefully.'},
        ],
        'enable_thinking': true,
      }, configuredModelId: 'llamadart-local');

      expect(request.enableThinking, isTrue);
      expect(request.params.temp, 1.0);
      expect(request.params.topK, 20);
      expect(request.params.topP, 0.95);
      expect(request.params.minP, 0.0);
      expect(request.params.penalty, 1.0);
    });

    test('rejects a non-boolean thinking control', () {
      expect(
        () => parseChatCompletionRequest(<String, dynamic>{
          'model': 'llamadart-local',
          'messages': <Map<String, dynamic>>[
            <String, dynamic>{'role': 'user', 'content': 'Say hello.'},
          ],
          'enable_thinking': 'false',
        }, configuredModelId: 'llamadart-local'),
        throwsA(
          isA<OpenAiHttpException>().having(
            (OpenAiHttpException error) => error.param,
            'param',
            'enable_thinking',
          ),
        ),
      );
    });

    test('parses tools and required tool choice', () {
      final request = parseChatCompletionRequest(<String, dynamic>{
        'model': 'llamadart-local',
        'messages': <Map<String, dynamic>>[
          <String, dynamic>{
            'role': 'user',
            'content': 'What is weather in Seoul?',
          },
        ],
        'tools': <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'function',
            'function': <String, dynamic>{
              'name': 'get_weather',
              'description': 'Get weather by city',
              'parameters': <String, dynamic>{
                'type': 'object',
                'properties': <String, dynamic>{
                  'city': <String, dynamic>{'type': 'string'},
                },
                'required': <String>['city'],
              },
            },
          },
        ],
        'tool_choice': 'required',
      }, configuredModelId: 'llamadart-local');

      expect(request.tools, isNotNull);
      expect(request.tools, hasLength(1));
      expect(request.tools!.first.name, 'get_weather');
      expect(request.toolChoice, ToolChoice.required);
    });

    test('honors a named function tool choice', () {
      final request = parseChatCompletionRequest(<String, dynamic>{
        'model': 'llamadart-local',
        'messages': <Map<String, dynamic>>[
          <String, dynamic>{'role': 'user', 'content': 'Tell me the time.'},
        ],
        'tools': <Map<String, dynamic>>[
          _toolDefinition('get_weather'),
          _toolDefinition('get_time'),
        ],
        'tool_choice': <String, dynamic>{
          'type': 'function',
          'function': <String, dynamic>{'name': 'get_time'},
        },
      }, configuredModelId: 'llamadart-local');

      expect(request.toolChoice, ToolChoice.required);
      expect(request.tools, hasLength(1));
      expect(request.tools!.single.name, 'get_time');
    });

    test('rejects a named function choice that is not in tools', () {
      expect(
        () => parseChatCompletionRequest(<String, dynamic>{
          'model': 'llamadart-local',
          'messages': <Map<String, dynamic>>[
            <String, dynamic>{'role': 'user', 'content': 'Tell me the time.'},
          ],
          'tools': <Map<String, dynamic>>[_toolDefinition('get_weather')],
          'tool_choice': <String, dynamic>{
            'type': 'function',
            'function': <String, dynamic>{'name': 'get_time'},
          },
        }, configuredModelId: 'llamadart-local'),
        throwsA(
          isA<OpenAiHttpException>().having(
            (OpenAiHttpException error) => error.param,
            'param',
            'tool_choice.function.name',
          ),
        ),
      );
    });

    test('preserves a standard client-managed tool transcript', () {
      final request = parseChatCompletionRequest(<String, dynamic>{
        'model': 'llamadart-local',
        'messages': <Map<String, dynamic>>[
          <String, dynamic>{
            'role': 'user',
            'content': 'What is the weather in Seoul?',
          },
          <String, dynamic>{
            'role': 'assistant',
            'content': null,
            'tool_calls': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 'call_weather_1',
                'type': 'function',
                'function': <String, dynamic>{
                  'name': 'get_weather',
                  'arguments': '{"location":"Seoul"}',
                },
              },
            ],
          },
          <String, dynamic>{
            'role': 'tool',
            'tool_call_id': 'call_weather_1',
            'content': '{"condition":"sunny","temperature_c":23}',
          },
        ],
        'tools': <Map<String, dynamic>>[_toolDefinition('get_weather')],
        'tool_choice': 'none',
      }, configuredModelId: 'llamadart-local');

      final assistant = request.messages[1].toJson();
      final toolCalls = assistant['tool_calls'] as List<dynamic>;
      final toolCall = toolCalls.single as Map<String, dynamic>;
      final function = toolCall['function'] as Map<String, dynamic>;
      final toolResult = request.messages[2].toJson();

      expect(assistant['content'], isNull);
      expect(toolCall['id'], 'call_weather_1');
      expect(function['arguments'], '{"location":"Seoul"}');
      expect(toolResult['tool_call_id'], 'call_weather_1');
      expect(toolResult['name'], 'get_weather');
      expect(toolResult['content'], '{"condition":"sunny","temperature_c":23}');
    });

    test('rejects incomplete or unlinked tool result messages', () {
      final request = <String, dynamic>{
        'model': 'llamadart-local',
        'messages': <Map<String, dynamic>>[
          <String, dynamic>{'role': 'user', 'content': 'What is the weather?'},
          <String, dynamic>{
            'role': 'assistant',
            'content': null,
            'tool_calls': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 'call_weather_1',
                'type': 'function',
                'function': <String, dynamic>{
                  'name': 'get_weather',
                  'arguments': '{"location":"Seoul"}',
                },
              },
            ],
          },
          <String, dynamic>{
            'role': 'tool',
            'tool_call_id': 'call_missing',
            'content': 'No result',
          },
        ],
      };

      expect(
        () => parseChatCompletionRequest(
          request,
          configuredModelId: 'llamadart-local',
        ),
        throwsA(
          isA<OpenAiHttpException>().having(
            (OpenAiHttpException error) => error.param,
            'param',
            'messages.tool_call_id',
          ),
        ),
      );
    });

    test('rejects transcripts with unresolved tool calls', () {
      final request = <String, dynamic>{
        'model': 'llamadart-local',
        'messages': <Map<String, dynamic>>[
          <String, dynamic>{'role': 'user', 'content': 'What is the weather?'},
          <String, dynamic>{
            'role': 'assistant',
            'content': null,
            'tool_calls': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 'call_weather_1',
                'type': 'function',
                'function': <String, dynamic>{
                  'name': 'get_weather',
                  'arguments': '{"location":"Seoul"}',
                },
              },
              <String, dynamic>{
                'id': 'call_weather_2',
                'type': 'function',
                'function': <String, dynamic>{
                  'name': 'get_weather',
                  'arguments': '{"location":"Tokyo"}',
                },
              },
            ],
          },
          <String, dynamic>{
            'role': 'tool',
            'tool_call_id': 'call_weather_1',
            'content': 'Sunny',
          },
        ],
      };

      expect(
        () => parseChatCompletionRequest(
          request,
          configuredModelId: 'llamadart-local',
        ),
        throwsA(
          isA<OpenAiHttpException>().having(
            (OpenAiHttpException error) => error.param,
            'param',
            'messages.tool_call_id',
          ),
        ),
      );
    });

    test('rejects tool call IDs reused after their results', () {
      final request = <String, dynamic>{
        'model': 'llamadart-local',
        'messages': <Map<String, dynamic>>[
          <String, dynamic>{'role': 'user', 'content': 'What is the weather?'},
          <String, dynamic>{
            'role': 'assistant',
            'content': null,
            'tool_calls': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 'call_weather_1',
                'type': 'function',
                'function': <String, dynamic>{
                  'name': 'get_weather',
                  'arguments': '{"location":"Seoul"}',
                },
              },
            ],
          },
          <String, dynamic>{
            'role': 'tool',
            'tool_call_id': 'call_weather_1',
            'content': 'Sunny',
          },
          <String, dynamic>{
            'role': 'assistant',
            'content': null,
            'tool_calls': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 'call_weather_1',
                'type': 'function',
                'function': <String, dynamic>{
                  'name': 'get_weather',
                  'arguments': '{"location":"Tokyo"}',
                },
              },
            ],
          },
        ],
      };

      expect(
        () => parseChatCompletionRequest(
          request,
          configuredModelId: 'llamadart-local',
        ),
        throwsA(
          isA<OpenAiHttpException>().having(
            (OpenAiHttpException error) => error.param,
            'param',
            'messages.tool_calls.id',
          ),
        ),
      );
    });

    test('rejects assistant tool calls without an ID', () {
      expect(
        () => parseChatCompletionRequest(<String, dynamic>{
          'model': 'llamadart-local',
          'messages': <Map<String, dynamic>>[
            <String, dynamic>{
              'role': 'user',
              'content': 'What is the weather?',
            },
            <String, dynamic>{
              'role': 'assistant',
              'content': null,
              'tool_calls': <Map<String, dynamic>>[
                <String, dynamic>{
                  'type': 'function',
                  'function': <String, dynamic>{
                    'name': 'get_weather',
                    'arguments': '{"location":"Seoul"}',
                  },
                },
              ],
            },
          ],
        }, configuredModelId: 'llamadart-local'),
        throwsA(
          isA<OpenAiHttpException>().having(
            (OpenAiHttpException error) => error.param,
            'param',
            'messages.tool_calls.id',
          ),
        ),
      );
    });

    test('throws for n > 1', () {
      expect(
        () => parseChatCompletionRequest(<String, dynamic>{
          'model': 'llamadart-local',
          'messages': <Map<String, dynamic>>[
            <String, dynamic>{'role': 'user', 'content': 'hi'},
          ],
          'n': 2,
        }, configuredModelId: 'llamadart-local'),
        throwsA(
          isA<OpenAiHttpException>().having(
            (OpenAiHttpException error) => error.statusCode,
            'statusCode',
            400,
          ),
        ),
      );
    });
  });

  group('parseEmbeddingsRequest', () {
    test('parses single-string input with default encoding format', () {
      final request = parseEmbeddingsRequest(<String, dynamic>{
        'model': 'llamadart-local',
        'input': 'hello world',
      }, configuredModelId: 'llamadart-local');

      expect(request.model, 'llamadart-local');
      expect(request.inputs, <String>['hello world']);
      expect(request.encodingFormat, 'float');
    });

    test('parses array input with explicit float format', () {
      final request = parseEmbeddingsRequest(<String, dynamic>{
        'model': 'llamadart-local',
        'input': <String>['hello', 'world'],
        'encoding_format': 'float',
      }, configuredModelId: 'llamadart-local');

      expect(request.inputs, <String>['hello', 'world']);
      expect(request.encodingFormat, 'float');
    });

    test('throws for unsupported encoding format', () {
      expect(
        () => parseEmbeddingsRequest(<String, dynamic>{
          'model': 'llamadart-local',
          'input': 'hello',
          'encoding_format': 'base64',
        }, configuredModelId: 'llamadart-local'),
        throwsA(
          isA<OpenAiHttpException>().having(
            (OpenAiHttpException error) => error.param,
            'param',
            'encoding_format',
          ),
        ),
      );
    });

    test('throws when input is not string or string array', () {
      expect(
        () => parseEmbeddingsRequest(<String, dynamic>{
          'model': 'llamadart-local',
          'input': 123,
        }, configuredModelId: 'llamadart-local'),
        throwsA(
          isA<OpenAiHttpException>().having(
            (OpenAiHttpException error) => error.param,
            'param',
            'input',
          ),
        ),
      );
    });
  });

  group('toOpenAiChatCompletionChunk', () {
    test('includes assistant role on first chunk', () {
      final chunk = LlamaCompletionChunk(
        id: 'chatcmpl-123',
        object: 'chat.completion.chunk',
        created: 123,
        model: 'ignored',
        choices: <LlamaCompletionChunkChoice>[
          LlamaCompletionChunkChoice(
            index: 0,
            delta: LlamaCompletionChunkDelta(content: 'Hello'),
          ),
        ],
      );

      final json = toOpenAiChatCompletionChunk(
        chunk,
        model: 'llamadart-local',
        includeRole: true,
      );

      final choices = json['choices'] as List<dynamic>;
      final choice = choices.first as Map<String, dynamic>;
      final delta = choice['delta'] as Map<String, dynamic>;

      expect(json['model'], 'llamadart-local');
      expect(delta['role'], 'assistant');
      expect(delta['content'], 'Hello');
      expect(choice['finish_reason'], isNull);
    });

    test(
      'defaults content to empty string on first chunk with empty content',
      () {
        final chunk = LlamaCompletionChunk(
          id: 'chatcmpl-123',
          object: 'chat.completion.chunk',
          created: 123,
          model: 'ignored',
          choices: <LlamaCompletionChunkChoice>[
            LlamaCompletionChunkChoice(
              index: 0,
              delta: LlamaCompletionChunkDelta(),
            ),
          ],
        );

        final json = toOpenAiChatCompletionChunk(
          chunk,
          model: 'llamadart-local',
          includeRole: true,
        );

        final choices = json['choices'] as List<dynamic>;
        final choice = choices.first as Map<String, dynamic>;
        final delta = choice['delta'] as Map<String, dynamic>;

        expect(delta['role'], 'assistant');
        expect(delta['content'], '');
      },
    );

    test('includes reasoning_content when thinking delta is present', () {
      final chunk = LlamaCompletionChunk(
        id: 'chatcmpl-456',
        object: 'chat.completion.chunk',
        created: 456,
        model: 'ignored',
        choices: <LlamaCompletionChunkChoice>[
          LlamaCompletionChunkChoice(
            index: 0,
            delta: LlamaCompletionChunkDelta(thinking: 'I should call a tool.'),
          ),
        ],
      );

      final json = toOpenAiChatCompletionChunk(
        chunk,
        model: 'llamadart-local',
        includeRole: false,
      );

      final choices = json['choices'] as List<dynamic>;
      final choice = choices.first as Map<String, dynamic>;
      final delta = choice['delta'] as Map<String, dynamic>;

      expect(delta['reasoning_content'], 'I should call a tool.');
      expect(delta.containsKey('content'), isFalse);
    });
  });

  group('OpenAiChatCompletionAccumulator', () {
    test('merges tool call argument fragments', () {
      final accumulator = OpenAiChatCompletionAccumulator();

      accumulator.addChunk(
        LlamaCompletionChunk(
          id: 'chatcmpl-123',
          object: 'chat.completion.chunk',
          created: 123,
          model: 'ignored',
          choices: <LlamaCompletionChunkChoice>[
            LlamaCompletionChunkChoice(
              index: 0,
              delta: LlamaCompletionChunkDelta(
                toolCalls: <LlamaCompletionChunkToolCall>[
                  LlamaCompletionChunkToolCall(
                    index: 0,
                    id: 'call_abc',
                    type: 'function',
                    function: LlamaCompletionChunkFunction(
                      name: 'get_weather',
                      arguments: '{"city":"Se',
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );

      accumulator.addChunk(
        LlamaCompletionChunk(
          id: 'chatcmpl-123',
          object: 'chat.completion.chunk',
          created: 123,
          model: 'ignored',
          choices: <LlamaCompletionChunkChoice>[
            LlamaCompletionChunkChoice(
              index: 0,
              delta: LlamaCompletionChunkDelta(
                toolCalls: <LlamaCompletionChunkToolCall>[
                  LlamaCompletionChunkToolCall(
                    index: 0,
                    function: LlamaCompletionChunkFunction(arguments: 'oul"}'),
                  ),
                ],
              ),
              finishReason: 'tool_calls',
            ),
          ],
        ),
      );

      final response = accumulator.toResponseJson(
        id: 'chatcmpl-123',
        created: 123,
        model: 'llamadart-local',
        promptTokens: 10,
        completionTokens: 5,
      );

      final choices = response['choices'] as List<dynamic>;
      final choice = choices.first as Map<String, dynamic>;
      final message = choice['message'] as Map<String, dynamic>;
      final toolCalls = message['tool_calls'] as List<dynamic>;
      final toolCall = toolCalls.first as Map<String, dynamic>;
      final function = toolCall['function'] as Map<String, dynamic>;

      expect(choice['finish_reason'], 'tool_calls');
      expect(function['name'], 'get_weather');
      expect(function['arguments'], '{"city":"Seoul"}');
      expect(message['content'], isNull);
    });

    test('preserves assistant content alongside tool calls', () {
      final accumulator = OpenAiChatCompletionAccumulator();

      accumulator.addChunk(
        LlamaCompletionChunk(
          id: 'chatcmpl-content-and-tool',
          object: 'chat.completion.chunk',
          created: 123,
          model: 'ignored',
          choices: <LlamaCompletionChunkChoice>[
            LlamaCompletionChunkChoice(
              index: 0,
              delta: LlamaCompletionChunkDelta(
                content: 'I will check the weather. ',
                toolCalls: <LlamaCompletionChunkToolCall>[
                  LlamaCompletionChunkToolCall(
                    index: 0,
                    id: 'call_weather_1',
                    type: 'function',
                    function: LlamaCompletionChunkFunction(
                      name: 'get_weather',
                      arguments: '{"location":"Seoul"}',
                    ),
                  ),
                ],
              ),
              finishReason: 'tool_calls',
            ),
          ],
        ),
      );

      final response = accumulator.toResponseJson(
        id: 'chatcmpl-content-and-tool',
        created: 123,
        model: 'llamadart-local',
        promptTokens: 10,
        completionTokens: 5,
      );

      final choice =
          (response['choices'] as List<dynamic>).single as Map<String, dynamic>;
      final message = choice['message'] as Map<String, dynamic>;

      expect(choice['finish_reason'], 'tool_calls');
      expect(message['content'], 'I will check the weather. ');
      expect(message['tool_calls'], isNotEmpty);
    });

    test('preserves reasoning_content in non-stream response payload', () {
      final accumulator = OpenAiChatCompletionAccumulator();

      accumulator.addChunk(
        LlamaCompletionChunk(
          id: 'chatcmpl-789',
          object: 'chat.completion.chunk',
          created: 789,
          model: 'ignored',
          choices: <LlamaCompletionChunkChoice>[
            LlamaCompletionChunkChoice(
              index: 0,
              delta: LlamaCompletionChunkDelta(
                thinking: 'Reasoning step.',
                content: 'Final answer.',
              ),
              finishReason: 'stop',
            ),
          ],
        ),
      );

      final response = accumulator.toResponseJson(
        id: 'chatcmpl-789',
        created: 789,
        model: 'llamadart-local',
        promptTokens: 4,
        completionTokens: 3,
      );

      final choices = response['choices'] as List<dynamic>;
      final choice = choices.first as Map<String, dynamic>;
      final message = choice['message'] as Map<String, dynamic>;

      expect(message['content'], 'Final answer.');
      expect(message['reasoning_content'], 'Reasoning step.');
    });

    test('does not infer tool calls from content-only text', () {
      final accumulator = OpenAiChatCompletionAccumulator();

      accumulator.addChunk(
        LlamaCompletionChunk(
          id: 'chatcmpl-101',
          object: 'chat.completion.chunk',
          created: 101,
          model: 'ignored',
          choices: <LlamaCompletionChunkChoice>[
            LlamaCompletionChunkChoice(
              index: 0,
              delta: LlamaCompletionChunkDelta(
                content:
                    "```tool_code\nget_weather(city='Seoul', unit='celsius')\n```",
              ),
              finishReason: 'stop',
            ),
          ],
        ),
      );

      final response = accumulator.toResponseJson(
        id: 'chatcmpl-101',
        created: 101,
        model: 'llamadart-local',
        promptTokens: 10,
        completionTokens: 5,
      );

      final choice =
          (response['choices'] as List<dynamic>).first as Map<String, dynamic>;
      final message = choice['message'] as Map<String, dynamic>;

      expect(choice['finish_reason'], 'stop');
      expect(message.containsKey('tool_calls'), isFalse);
      expect(
        message['content'],
        "```tool_code\nget_weather(city='Seoul', unit='celsius')\n```",
      );
    });
  });

  group('SSE helpers', () {
    test('encodes data and done markers', () {
      expect(encodeSseData(<String, dynamic>{'x': 1}), 'data: {"x":1}\n\n');
      expect(encodeSseDone(), 'data: [DONE]\n\n');
    });
  });
}

Map<String, dynamic> _toolDefinition(String name) {
  return <String, dynamic>{
    'type': 'function',
    'function': <String, dynamic>{
      'name': name,
      'description': 'Test tool $name.',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'location': <String, dynamic>{'type': 'string'},
        },
      },
    },
  };
}
