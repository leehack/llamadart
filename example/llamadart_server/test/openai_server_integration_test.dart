import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_server/llamadart_server.dart';
import 'package:relic/relic.dart';
import 'package:test/test.dart';

void main() {
  group('OpenAiApiServer', () {
    late _FakeApiServerEngine fakeEngine;
    late _RunningServer server;
    late http.Client client;

    setUp(() async {
      fakeEngine = _FakeApiServerEngine();
      server = await _startServer(fakeEngine);
      client = http.Client();
    });

    tearDown(() async {
      client.close();
      await server.close();
    });

    test('GET /v1/models returns configured model', () async {
      final response = await client.get(server.uri('/v1/models'));
      expect(response.statusCode, 200);

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      expect(json['object'], 'list');

      final data = json['data'] as List<dynamic>;
      final first = data.first as Map<String, dynamic>;
      expect(first['id'], 'test-model');
      expect(first['object'], 'model');
    });

    test('GET /openapi.json returns expected spec paths', () async {
      final response = await client.get(server.uri('/openapi.json'));
      expect(response.statusCode, 200);

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      expect(json['openapi'], '3.1.0');

      final servers = json['servers'] as List<dynamic>;
      final firstServer = servers.first as Map<String, dynamic>;
      expect(firstServer['url'], server.uri('/').origin);

      final paths = json['paths'] as Map<String, dynamic>;
      expect(paths.containsKey('/openapi.json'), isTrue);
      expect(paths.containsKey('/docs'), isTrue);
      expect(paths.containsKey('/v1/models'), isTrue);
      expect(paths.containsKey('/v1/chat/completions'), isTrue);
      expect(paths.containsKey('/v1/embeddings'), isTrue);

      final components = json['components'] as Map<String, dynamic>;
      final schemas = components['schemas'] as Map<String, dynamic>;
      final chatRequest =
          schemas['ChatCompletionRequest'] as Map<String, dynamic>;
      final properties = chatRequest['properties'] as Map<String, dynamic>;
      final thinking = properties['enable_thinking'] as Map<String, dynamic>;
      expect(thinking['default'], isFalse);
      final parallel =
          properties['parallel_tool_calls'] as Map<String, dynamic>;
      expect(parallel['default'], isFalse);
      final example = chatRequest['example'] as Map<String, dynamic>;
      expect(example['enable_thinking'], isFalse);

      final chatPath = paths['/v1/chat/completions'] as Map<String, dynamic>;
      final chatPost = chatPath['post'] as Map<String, dynamic>;
      final requestBody = chatPost['requestBody'] as Map<String, dynamic>;
      final content = requestBody['content'] as Map<String, dynamic>;
      final jsonContent = content['application/json'] as Map<String, dynamic>;
      final examples = jsonContent['examples'] as Map<String, dynamic>;
      expect(
        examples.keys,
        containsAll(<String>[
          'basic',
          'streaming',
          'tool_call_initial',
          'tool_call_streaming',
          'tool_call_streaming_with_thinking',
          'tool_result_follow_up',
        ]),
      );

      final toolCallSummaries = <String>[
        for (final key in <String>[
          'tool_call_initial',
          'tool_call_streaming',
          'tool_call_streaming_with_thinking',
          'tool_result_follow_up',
        ])
          (examples[key] as Map<String, dynamic>)['summary'] as String,
      ];
      expect(toolCallSummaries, everyElement(startsWith('Tool call:')));

      final thinkingExample =
          examples['tool_call_streaming_with_thinking'] as Map<String, dynamic>;
      final thinkingValue = thinkingExample['value'] as Map<String, dynamic>;
      final thinkingMessages = thinkingValue['messages'] as List<dynamic>;
      final thinkingSystem = thinkingMessages.first as Map<String, dynamic>;
      expect(thinkingValue['stream'], isTrue);
      expect(thinkingValue['enable_thinking'], isTrue);
      expect(thinkingValue['tool_choice'], 'auto');
      expect(thinkingSystem['content'], contains('must call get_weather'));

      final followUp =
          examples['tool_result_follow_up'] as Map<String, dynamic>;
      final followUpValue = followUp['value'] as Map<String, dynamic>;
      final followUpMessages = followUpValue['messages'] as List<dynamic>;
      final assistant = followUpMessages[1] as Map<String, dynamic>;
      final toolCalls = assistant['tool_calls'] as List<dynamic>;
      final call = toolCalls.single as Map<String, dynamic>;
      final tool = followUpMessages[2] as Map<String, dynamic>;
      expect(call['id'], tool['tool_call_id']);
      expect(tool.containsKey('name'), isFalse);
    });

    test('GET /docs serves Swagger UI HTML', () async {
      final response = await client.get(server.uri('/docs'));
      expect(response.statusCode, 200);
      expect(response.headers['content-type'], startsWith('text/html'));
      expect(response.body, contains('SwaggerUIBundle'));
      expect(response.body, contains('/openapi.json'));
    });

    test('POST /v1/chat/completions returns OpenAI-shaped response', () async {
      final response = await client.post(
        server.uri('/v1/chat/completions'),
        headers: <String, String>{'Content-Type': 'application/json'},
        body: jsonEncode(<String, dynamic>{
          'model': 'test-model',
          'messages': <Map<String, dynamic>>[
            <String, dynamic>{'role': 'user', 'content': 'Say hi'},
          ],
        }),
      );

      expect(response.statusCode, 200);
      final json = jsonDecode(response.body) as Map<String, dynamic>;

      expect(json['object'], 'chat.completion');
      expect(json['model'], 'test-model');

      final choices = json['choices'] as List<dynamic>;
      final choice = choices.first as Map<String, dynamic>;
      final message = choice['message'] as Map<String, dynamic>;

      expect(message['role'], 'assistant');
      expect(message['content'], 'Hello world');
      expect(choice['finish_reason'], 'stop');

      final usage = json['usage'] as Map<String, dynamic>;
      expect(usage['prompt_tokens'], 7);
      expect(usage['completion_tokens'], 2);
      expect(usage['total_tokens'], 9);
      expect(fakeEngine.cancelCount, greaterThan(0));
      expect(fakeEngine.templateEnableThinkingCalls, <bool>[false]);
      expect(fakeEngine.enableThinkingCalls, <bool>[false]);
      expect(fakeEngine.templateParallelToolCalls, <bool>[false]);
      expect(fakeEngine.parallelToolCalls, <bool>[false]);
    });

    test('forwards enable_thinking to the engine', () async {
      final response = await client.post(
        server.uri('/v1/chat/completions'),
        headers: <String, String>{'Content-Type': 'application/json'},
        body: jsonEncode(<String, dynamic>{
          'model': 'test-model',
          'messages': <Map<String, dynamic>>[
            <String, dynamic>{'role': 'user', 'content': 'Think carefully.'},
          ],
          'enable_thinking': true,
        }),
      );

      expect(response.statusCode, 200);
      expect(fakeEngine.templateEnableThinkingCalls, <bool>[true]);
      expect(fakeEngine.enableThinkingCalls, <bool>[true]);
    });

    test('forwards only the named forced tool to the engine', () async {
      final response = await client.post(
        server.uri('/v1/chat/completions'),
        headers: <String, String>{'Content-Type': 'application/json'},
        body: jsonEncode(<String, dynamic>{
          'model': 'test-model',
          'messages': <Map<String, dynamic>>[
            <String, dynamic>{'role': 'user', 'content': 'Tell me the time.'},
          ],
          'tools': <Map<String, dynamic>>[
            _weatherToolDefinition(),
            _timeToolDefinition(),
          ],
          'tool_choice': <String, dynamic>{
            'type': 'function',
            'function': <String, dynamic>{'name': 'get_time'},
          },
        }),
      );

      expect(response.statusCode, 200);
      expect(fakeEngine.toolDefinitionsCalls, hasLength(1));
      expect(fakeEngine.toolDefinitionsCalls.single, hasLength(1));
      expect(fakeEngine.toolDefinitionsCalls.single!.single.name, 'get_time');
    });

    test('forwards parallel_tool_calls to the engine', () async {
      final response = await client.post(
        server.uri('/v1/chat/completions'),
        headers: <String, String>{'Content-Type': 'application/json'},
        body: jsonEncode(<String, dynamic>{
          'model': 'test-model',
          'messages': <Map<String, dynamic>>[
            <String, dynamic>{
              'role': 'user',
              'content': 'Get weather and time for Seoul.',
            },
          ],
          'tools': <Map<String, dynamic>>[
            _weatherToolDefinition(),
            _timeToolDefinition(),
          ],
          'parallel_tool_calls': true,
        }),
      );

      expect(response.statusCode, 200);
      expect(fakeEngine.templateParallelToolCalls, <bool>[true]);
      expect(fakeEngine.parallelToolCalls, <bool>[true]);
    });

    test('POST /v1/embeddings returns OpenAI-shaped response', () async {
      final response = await client.post(
        server.uri('/v1/embeddings'),
        headers: <String, String>{'Content-Type': 'application/json'},
        body: jsonEncode(<String, dynamic>{
          'model': 'test-model',
          'input': <String>['hello world', 'goodbye'],
          'encoding_format': 'float',
        }),
      );

      expect(response.statusCode, 200);
      final json = jsonDecode(response.body) as Map<String, dynamic>;

      expect(json['object'], 'list');
      expect(json['model'], 'test-model');

      final data = json['data'] as List<dynamic>;
      expect(data, hasLength(2));

      final first = data.first as Map<String, dynamic>;
      expect(first['object'], 'embedding');
      expect(first['index'], 0);
      expect(first['embedding'], isA<List<dynamic>>());

      final usage = json['usage'] as Map<String, dynamic>;
      expect(usage['prompt_tokens'], 3);
      expect(usage['total_tokens'], 3);
    });

    test(
      'POST /v1/chat/completions stream mode returns SSE and DONE',
      () async {
        final request = http.Request('POST', server.uri('/v1/chat/completions'))
          ..headers['Content-Type'] = 'application/json'
          ..body = jsonEncode(<String, dynamic>{
            'model': 'test-model',
            'stream': true,
            'enable_thinking': true,
            'messages': <Map<String, dynamic>>[
              <String, dynamic>{'role': 'user', 'content': 'stream please'},
            ],
          });

        final streamed = await client.send(request);
        expect(streamed.statusCode, 200);
        expect(
          streamed.headers['content-type'],
          startsWith('text/event-stream'),
        );

        final body = await streamed.stream.bytesToString();
        expect(body, contains('data: [DONE]\n\n'));
        expect(body, contains('"object":"chat.completion.chunk"'));
        expect(body, contains('"role":"assistant"'));
        expect(fakeEngine.enableThinkingCalls, <bool>[true]);
      },
    );
  });

  group('OpenAiApiServer auth', () {
    late _RunningServer server;
    late http.Client client;

    setUp(() async {
      server = await _startServer(_FakeApiServerEngine(), apiKey: 'dev-key');
      client = http.Client();
    });

    tearDown(() async {
      client.close();
      await server.close();
    });

    test('requires bearer token for /v1 routes when api key is set', () async {
      final unauthorized = await client.get(server.uri('/v1/models'));
      expect(unauthorized.statusCode, 401);

      final unauthorizedJson =
          jsonDecode(unauthorized.body) as Map<String, dynamic>;
      final error = unauthorizedJson['error'] as Map<String, dynamic>;
      expect(error['type'], 'authentication_error');

      final authorized = await client.get(
        server.uri('/v1/models'),
        headers: <String, String>{'Authorization': 'Bearer dev-key'},
      );
      expect(authorized.statusCode, 200);
    });

    test('OpenAPI marks secured operations when api key is enabled', () async {
      final response = await client.get(server.uri('/openapi.json'));
      expect(response.statusCode, 200);

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final paths = json['paths'] as Map<String, dynamic>;

      final modelsPath = paths['/v1/models'] as Map<String, dynamic>;
      final modelsGet = modelsPath['get'] as Map<String, dynamic>;
      final modelsSecurity = modelsGet['security'] as List<dynamic>;
      expect(modelsSecurity, isNotEmpty);

      final chatPath = paths['/v1/chat/completions'] as Map<String, dynamic>;
      final chatPost = chatPath['post'] as Map<String, dynamic>;
      final chatSecurity = chatPost['security'] as List<dynamic>;
      expect(chatSecurity, isNotEmpty);

      final embeddingsPath = paths['/v1/embeddings'] as Map<String, dynamic>;
      final embeddingsPost = embeddingsPath['post'] as Map<String, dynamic>;
      final embeddingsSecurity = embeddingsPost['security'] as List<dynamic>;
      expect(embeddingsSecurity, isNotEmpty);
    });
  });

  group('OpenAiApiServer busy state', () {
    late _BlockingApiServerEngine blockingEngine;
    late _RunningServer server;
    late http.Client client;

    setUp(() async {
      blockingEngine = _BlockingApiServerEngine();
      server = await _startServer(blockingEngine);
      client = http.Client();
    });

    tearDown(() async {
      blockingEngine.release();
      client.close();
      await server.close();
    });

    test('returns 429 while another generation is in progress', () async {
      final firstFuture = client.post(
        server.uri('/v1/chat/completions'),
        headers: <String, String>{'Content-Type': 'application/json'},
        body: jsonEncode(<String, dynamic>{
          'model': 'test-model',
          'messages': <Map<String, dynamic>>[
            <String, dynamic>{'role': 'user', 'content': 'first'},
          ],
        }),
      );

      await Future<void>.delayed(const Duration(milliseconds: 50));

      final second = await client.post(
        server.uri('/v1/chat/completions'),
        headers: <String, String>{'Content-Type': 'application/json'},
        body: jsonEncode(<String, dynamic>{
          'model': 'test-model',
          'messages': <Map<String, dynamic>>[
            <String, dynamic>{'role': 'user', 'content': 'second'},
          ],
        }),
      );

      expect(second.statusCode, 429);
      final json = jsonDecode(second.body) as Map<String, dynamic>;
      final error = json['error'] as Map<String, dynamic>;
      expect(error['type'], 'rate_limit_error');
      expect(error['code'], 'server_busy');

      blockingEngine.release();
      final first = await firstFuture;
      expect(first.statusCode, 200);
    });
  });

  group('OpenAiApiServer client-managed tool flow', () {
    late _ClientManagedToolApiServerEngine toolEngine;
    late _RunningServer server;
    late http.Client client;

    setUp(() async {
      toolEngine = _ClientManagedToolApiServerEngine();
      server = await _startServer(toolEngine);
      client = http.Client();
    });

    tearDown(() async {
      client.close();
      await server.close();
    });

    test(
      'returns tool calls and accepts client-provided tool results',
      () async {
        final initialResponse = await client.post(
          server.uri('/v1/chat/completions'),
          headers: <String, String>{'Content-Type': 'application/json'},
          body: jsonEncode(<String, dynamic>{
            'model': 'test-model',
            'messages': <Map<String, dynamic>>[
              <String, dynamic>{
                'role': 'user',
                'content': 'Call get_weather for Seoul.',
              },
            ],
            'tools': <Map<String, dynamic>>[_weatherToolDefinition()],
            'tool_choice': 'required',
          }),
        );

        expect(initialResponse.statusCode, 200);
        final initialJson =
            jsonDecode(initialResponse.body) as Map<String, dynamic>;
        final initialChoice =
            (initialJson['choices'] as List<dynamic>).single
                as Map<String, dynamic>;
        final assistantMessage =
            initialChoice['message'] as Map<String, dynamic>;
        final toolCall =
            (assistantMessage['tool_calls'] as List<dynamic>).single
                as Map<String, dynamic>;
        final toolCallId = toolCall['id'] as String;

        expect(initialChoice['finish_reason'], 'tool_calls');
        expect(assistantMessage['content'], isNull);
        expect(toolCallId, 'call_weather_1');
        expect(toolEngine.createCalls, hasLength(1));

        final followUpResponse = await client.post(
          server.uri('/v1/chat/completions'),
          headers: <String, String>{'Content-Type': 'application/json'},
          body: jsonEncode(<String, dynamic>{
            'model': 'test-model',
            'messages': <dynamic>[
              <String, dynamic>{
                'role': 'user',
                'content': 'Call get_weather for Seoul.',
              },
              assistantMessage,
              <String, dynamic>{
                'role': 'tool',
                'tool_call_id': toolCallId,
                'content': '{"location":"Seoul","condition":"sunny"}',
              },
            ],
            'tools': <Map<String, dynamic>>[_weatherToolDefinition()],
            'tool_choice': 'none',
          }),
        );

        expect(followUpResponse.statusCode, 200);
        final followUpJson =
            jsonDecode(followUpResponse.body) as Map<String, dynamic>;
        final followUpChoice =
            (followUpJson['choices'] as List<dynamic>).single
                as Map<String, dynamic>;
        final followUpMessage =
            followUpChoice['message'] as Map<String, dynamic>;

        expect(followUpChoice['finish_reason'], 'stop');
        expect(followUpMessage['content'], 'The weather in Seoul is sunny.');

        expect(toolEngine.createCalls, hasLength(2));
        final replayedMessages = toolEngine.createCalls[1];
        expect(
          replayedMessages.map((LlamaChatMessage message) => message.role),
          <LlamaChatRole>[
            LlamaChatRole.user,
            LlamaChatRole.assistant,
            LlamaChatRole.tool,
          ],
        );
        final replayedCall = replayedMessages[1].parts
            .whereType<LlamaToolCallContent>()
            .single;
        final replayedResult = replayedMessages[2].parts
            .whereType<LlamaToolResultContent>()
            .single;
        expect(replayedCall.rawJson, '{"location":"Seoul"}');
        expect(replayedResult.id, toolCallId);
        expect(replayedResult.name, 'get_weather');
        expect(
          replayedResult.result,
          '{"location":"Seoul","condition":"sunny"}',
        );
      },
    );

    test('rejects incomplete client-provided tool results', () async {
      final response = await client.post(
        server.uri('/v1/chat/completions'),
        headers: <String, String>{'Content-Type': 'application/json'},
        body: jsonEncode(<String, dynamic>{
          'model': 'test-model',
          'tool_choice': 'none',
          'tools': <Map<String, dynamic>>[_weatherToolDefinition()],
          'messages': <Map<String, dynamic>>[
            <String, dynamic>{'role': 'user', 'content': 'Get the weather.'},
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
              'content': '{"location":"Seoul","temperature_c":23}',
            },
          ],
        }),
      );

      expect(response.statusCode, 400);
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final error = json['error'] as Map<String, dynamic>;
      expect(error['param'], 'messages.tool_call_id');
      expect(toolEngine.createCalls, isEmpty);
    });
  });
}

Future<_RunningServer> _startServer(
  ApiServerEngine engine, {
  String? apiKey,
}) async {
  final app = OpenAiApiServer(
    engine: engine,
    modelId: 'test-model',
    apiKey: apiKey,
  ).buildApp();

  final relicServer = await app.serve(
    address: InternetAddress.loopbackIPv4,
    port: 0,
  );

  return _RunningServer(relicServer);
}

class _RunningServer {
  final RelicServer _server;

  _RunningServer(this._server);

  Uri uri(String path) {
    return Uri.parse('http://127.0.0.1:${_server.port}$path');
  }

  Future<void> close() {
    return _server.close();
  }
}

class _FakeApiServerEngine implements ApiServerEngine {
  int cancelCount = 0;
  final List<bool> templateEnableThinkingCalls = <bool>[];
  final List<bool> enableThinkingCalls = <bool>[];
  final List<bool> templateParallelToolCalls = <bool>[];
  final List<bool> parallelToolCalls = <bool>[];
  final List<List<ToolDefinition>?> toolDefinitionsCalls =
      <List<ToolDefinition>?>[];

  @override
  bool get isReady => true;

  @override
  Future<LlamaChatTemplateResult> chatTemplate(
    List<LlamaChatMessage> messages, {
    bool addAssistant = true,
    List<ToolDefinition>? tools,
    ToolChoice toolChoice = ToolChoice.auto,
    bool parallelToolCalls = false,
    bool enableThinking = false,
  }) async {
    templateEnableThinkingCalls.add(enableThinking);
    templateParallelToolCalls.add(parallelToolCalls);
    return const LlamaChatTemplateResult(prompt: 'prompt', tokenCount: 7);
  }

  @override
  Stream<LlamaCompletionChunk> create(
    List<LlamaChatMessage> messages, {
    GenerationParams params = const GenerationParams(),
    List<ToolDefinition>? tools,
    ToolChoice? toolChoice,
    bool parallelToolCalls = false,
    bool enableThinking = false,
  }) async* {
    enableThinkingCalls.add(enableThinking);
    this.parallelToolCalls.add(parallelToolCalls);
    toolDefinitionsCalls.add(tools);
    yield LlamaCompletionChunk(
      id: 'chatcmpl-test',
      object: 'chat.completion.chunk',
      created: 1700000000,
      model: 'test-model',
      choices: <LlamaCompletionChunkChoice>[
        LlamaCompletionChunkChoice(
          index: 0,
          delta: LlamaCompletionChunkDelta(content: 'Hello '),
        ),
      ],
    );

    yield LlamaCompletionChunk(
      id: 'chatcmpl-test',
      object: 'chat.completion.chunk',
      created: 1700000000,
      model: 'test-model',
      choices: <LlamaCompletionChunkChoice>[
        LlamaCompletionChunkChoice(
          index: 0,
          delta: LlamaCompletionChunkDelta(content: 'world'),
          finishReason: 'stop',
        ),
      ],
    );
  }

  @override
  Future<int> getTokenCount(String text) async {
    return text.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
  }

  @override
  Future<List<double>> embed(String input, {bool normalize = true}) async {
    return <double>[input.length.toDouble(), normalize ? 1.0 : 0.0];
  }

  @override
  Future<List<List<double>>> embedBatch(
    List<String> inputs, {
    bool normalize = true,
  }) async {
    return inputs
        .map(
          (input) => <double>[input.length.toDouble(), normalize ? 1.0 : 0.0],
        )
        .toList(growable: false);
  }

  @override
  void cancelGeneration() {
    cancelCount++;
  }
}

class _BlockingApiServerEngine extends _FakeApiServerEngine {
  final Completer<void> _releaseCompleter = Completer<void>();

  void release() {
    if (!_releaseCompleter.isCompleted) {
      _releaseCompleter.complete();
    }
  }

  @override
  Stream<LlamaCompletionChunk> create(
    List<LlamaChatMessage> messages, {
    GenerationParams params = const GenerationParams(),
    List<ToolDefinition>? tools,
    ToolChoice? toolChoice,
    bool parallelToolCalls = false,
    bool enableThinking = false,
  }) async* {
    await _releaseCompleter.future;
    yield LlamaCompletionChunk(
      id: 'chatcmpl-blocking',
      object: 'chat.completion.chunk',
      created: 1700000000,
      model: 'test-model',
      choices: <LlamaCompletionChunkChoice>[
        LlamaCompletionChunkChoice(
          index: 0,
          delta: LlamaCompletionChunkDelta(content: 'released'),
          finishReason: 'stop',
        ),
      ],
    );
  }
}

class _ClientManagedToolApiServerEngine implements ApiServerEngine {
  final List<List<LlamaChatMessage>> createCalls = <List<LlamaChatMessage>>[];

  @override
  bool get isReady => true;

  @override
  Future<LlamaChatTemplateResult> chatTemplate(
    List<LlamaChatMessage> messages, {
    bool addAssistant = true,
    List<ToolDefinition>? tools,
    ToolChoice toolChoice = ToolChoice.auto,
    bool parallelToolCalls = false,
    bool enableThinking = false,
  }) async {
    return LlamaChatTemplateResult(
      prompt: 'prompt',
      tokenCount: messages.length * 3,
    );
  }

  @override
  Stream<LlamaCompletionChunk> create(
    List<LlamaChatMessage> messages, {
    GenerationParams params = const GenerationParams(),
    List<ToolDefinition>? tools,
    ToolChoice? toolChoice,
    bool parallelToolCalls = false,
    bool enableThinking = false,
  }) async* {
    createCalls.add(List<LlamaChatMessage>.from(messages));
    final hasToolResult = messages.any(
      (message) => message.role == LlamaChatRole.tool,
    );

    if (!hasToolResult) {
      yield LlamaCompletionChunk(
        id: 'chatcmpl-tool-round-1',
        object: 'chat.completion.chunk',
        created: 1700001000,
        model: 'test-model',
        choices: <LlamaCompletionChunkChoice>[
          LlamaCompletionChunkChoice(
            index: 0,
            delta: LlamaCompletionChunkDelta(
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
      );
      return;
    }

    yield LlamaCompletionChunk(
      id: 'chatcmpl-tool-round-2',
      object: 'chat.completion.chunk',
      created: 1700001001,
      model: 'test-model',
      choices: <LlamaCompletionChunkChoice>[
        LlamaCompletionChunkChoice(
          index: 0,
          delta: LlamaCompletionChunkDelta(
            content: 'The weather in Seoul is sunny.',
          ),
          finishReason: 'stop',
        ),
      ],
    );
  }

  @override
  Future<int> getTokenCount(String text) async {
    return text.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
  }

  @override
  Future<List<double>> embed(String input, {bool normalize = true}) async {
    return <double>[input.length.toDouble(), normalize ? 1.0 : 0.0];
  }

  @override
  Future<List<List<double>>> embedBatch(
    List<String> inputs, {
    bool normalize = true,
  }) async {
    return inputs
        .map(
          (input) => <double>[input.length.toDouble(), normalize ? 1.0 : 0.0],
        )
        .toList(growable: false);
  }

  @override
  void cancelGeneration() {}
}

Map<String, dynamic> _weatherToolDefinition() {
  return <String, dynamic>{
    'type': 'function',
    'function': <String, dynamic>{
      'name': 'get_weather',
      'description': 'Get weather by location.',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'location': <String, dynamic>{'type': 'string'},
        },
        'required': <String>['location'],
      },
    },
  };
}

Map<String, dynamic> _timeToolDefinition() {
  return <String, dynamic>{
    'type': 'function',
    'function': <String, dynamic>{
      'name': 'get_time',
      'description': 'Get time by timezone.',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'timezone': <String, dynamic>{'type': 'string'},
        },
        'required': <String>['timezone'],
      },
    },
  };
}
