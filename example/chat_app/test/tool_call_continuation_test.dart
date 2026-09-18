import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_chat_example/models/chat_settings.dart';
import 'package:llamadart_chat_example/providers/chat_provider.dart';
import 'package:llamadart_chat_example/services/host_tool_service.dart';
import 'package:llamadart_chat_example/services/chat_session_service.dart';

import 'mocks.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  Future<ChatProvider> buildProvider(
    MockLlamaEngine engine, {
    HostToolService? hostToolService,
    String modelPath = 'test_model.gguf',
  }) async {
    final settings = ChatSettings(modelPath: modelPath);
    final settingsService = MockSettingsService()..settings = settings;
    final provider = ChatProvider(
      chatService: MockChatService(engine: engine),
      settingsService: settingsService,
      hostToolService: hostToolService,
      initialSettings: settings,
    );
    addTearDown(provider.dispose);

    await provider.loadModel();
    provider.updateToolsEnabled(true);
    provider.resetToolDeclarations();
    return provider;
  }

  Map<String, Object?> singleResultPayload(ChatProvider provider) {
    final toolMessage = provider.messages.firstWhere(
      (message) => message.role == LlamaChatRole.tool,
    );
    final results = toolMessage.parts!
        .whereType<LlamaToolResultContent>()
        .toList(growable: false);
    expect(results, hasLength(1));
    return results.first.result as Map<String, Object?>;
  }

  group('declared tool execution and continuation', () {
    test(
      'runs the declared handler and continues with a final answer',
      () async {
        final engine = _ScriptedToolCallEngine(
          toolCalls: const [
            _ScriptedToolCall(
              id: 'call_1',
              name: 'getWeather',
              arguments: '{"city":"Seoul"}',
            ),
          ],
          continuationText: 'Seoul currently reports the simulated conditions.',
        );
        final provider = await buildProvider(engine);

        await provider.sendMessage('what is the weather in Seoul?');

        expect(engine.createCallCount, 2);

        final toolCallMessage = provider.messages.firstWhere(
          (m) => m.isToolCall,
        );
        expect(toolCallMessage.generatedTokenCount, 1);
        final results = toolCallMessage.parts!
            .whereType<LlamaToolResultContent>()
            .toList(growable: false);
        expect(results, hasLength(1));
        expect(results.first.name, 'getWeather');
        expect(results.first.id, 'call_1');
        final payload = results.first.result as Map<String, Object?>;
        expect(payload['city'], 'Seoul');
        expect(payload['simulated'], isTrue);
        expect(payload['condition'], isA<String>());
        expect(payload['temperatureCelsius'], isA<int>());

        final toolHistoryMessage = provider.messages.firstWhere(
          (m) => m.role == LlamaChatRole.tool,
        );
        expect(
          toolHistoryMessage.parts!.whereType<LlamaToolResultContent>(),
          hasLength(1),
        );

        final last = provider.messages.last;
        expect(last.isUser, isFalse);
        expect(last.isToolCall, isFalse);
        expect(last.text, 'Seoul currently reports the simulated conditions.');
        expect(last.generatedTokenCount, 1);
        expect(provider.currentTokens, 2);

        final continuationRequest = engine.requests.last;
        expect(
          continuationRequest.any(
            (message) =>
                message.role == LlamaChatRole.assistant &&
                message.parts.whereType<LlamaToolCallContent>().isNotEmpty,
          ),
          isTrue,
        );
        expect(
          continuationRequest.any(
            (message) => message.role == LlamaChatRole.tool,
          ),
          isTrue,
        );

        final rebuilt = const ChatSessionService().rebuildFromMessages(
          engine: engine,
          contextSize: provider.contextSize,
          messages: provider.messages,
        );
        expect(rebuilt.history.map((message) => message.role), <LlamaChatRole>[
          LlamaChatRole.user,
          LlamaChatRole.assistant,
          LlamaChatRole.tool,
          LlamaChatRole.assistant,
        ]);
        expect(
          rebuilt.history[1].parts.whereType<LlamaToolResultContent>(),
          isEmpty,
        );
        expect(
          rebuilt.history[2].parts.whereType<LlamaToolResultContent>(),
          hasLength(1),
        );
      },
    );

    test('uses the same bounded continuation path for both backends', () async {
      for (final modelPath in <String>[
        'test_model.gguf',
        'test_model.litertlm',
      ]) {
        final engine = _ScriptedToolCallEngine(
          toolCalls: const [
            _ScriptedToolCall(
              id: 'call_backend',
              name: 'getWeather',
              arguments: '{"city":"Seoul"}',
            ),
          ],
          continuationText: 'Final answer.',
        );
        final provider = await buildProvider(engine, modelPath: modelPath);

        await provider.sendMessage('weather');

        expect(engine.createCallCount, 2, reason: modelPath);
        expect(
          engine.requests.last.map((message) => message.role),
          containsAllInOrder(<LlamaChatRole>[
            LlamaChatRole.user,
            LlamaChatRole.assistant,
            LlamaChatRole.tool,
          ]),
          reason: modelPath,
        );
        expect(provider.messages.last.text, 'Final answer.');
      }
    });

    test('returns a safe error result for an undeclared tool name', () async {
      final engine = _ScriptedToolCallEngine(
        toolCalls: const [
          _ScriptedToolCall(
            id: 'call_unknown',
            name: 'launchRocket',
            arguments: '{"target":"moon"}',
          ),
        ],
        continuationText: 'That tool is not available.',
      );
      final provider = await buildProvider(engine);

      await provider.sendMessage('launch a rocket');

      expect(engine.createCallCount, 2);
      final payload = singleResultPayload(provider);
      expect(payload['error'], 'unsupported_tool');
      expect(payload['tool'], 'launchRocket');
      expect(provider.messages.last.text, 'That tool is not available.');
    });

    test('reports a safe error result when the handler throws', () async {
      final engine = _ScriptedToolCallEngine(
        toolCalls: const [
          _ScriptedToolCall(
            id: 'call_boom',
            name: 'getWeather',
            arguments: '{"city":"Seoul"}',
          ),
        ],
        continuationText: 'The tool failed, so I cannot answer.',
      );
      final provider = await buildProvider(
        engine,
        hostToolService: _ThrowingHostToolService(),
      );

      await provider.sendMessage('weather please');

      expect(engine.createCallCount, 2);
      final payload = singleResultPayload(provider);
      expect(payload['error'], 'tool_execution_failed');
      expect(payload['message'], isNot(contains('simulated handler failure')));
      expect(payload['message'], contains('no result was produced'));
      expect(
        provider.messages.last.text,
        'The tool failed, so I cannot answer.',
      );
    });

    test('malformed arguments return a safe explicit result error', () async {
      final engine = _ScriptedToolCallEngine(
        toolCalls: const [
          _ScriptedToolCall(
            id: 'call_invalid',
            name: 'getWeather',
            arguments: 'not-json',
          ),
        ],
        continuationText: 'The request was invalid.',
      );
      final provider = await buildProvider(engine);

      await provider.sendMessage('weather');

      expect(engine.createCallCount, 2);
      final payload = singleResultPayload(provider);
      expect(payload['error'], 'invalid_arguments');
      expect(payload['message'], isNot(contains('not-json')));
      expect(provider.messages.last.text, 'The request was invalid.');
    });

    test('executes every call in one batch exactly once', () async {
      final engine = _ScriptedToolCallEngine(
        toolCalls: const [
          _ScriptedToolCall(
            id: 'call_a',
            name: 'getWeather',
            arguments: '{"city":"Seoul"}',
          ),
          _ScriptedToolCall(
            id: 'call_b',
            name: 'getWeather',
            arguments: '{"city":"Paris"}',
          ),
        ],
        continuationText: 'Both cities are covered.',
      );
      final spy = _CountingHostToolService();
      final provider = await buildProvider(engine, hostToolService: spy);

      await provider.sendMessage('compare Seoul and Paris');

      expect(spy.invocations, 2);
      final toolMessage = provider.messages.firstWhere(
        (message) => message.role == LlamaChatRole.tool,
      );
      final results = toolMessage.parts!
          .whereType<LlamaToolResultContent>()
          .toList(growable: false);
      expect(results.map((result) => result.id), ['call_a', 'call_b']);
      expect(
        results
            .map((result) => (result.result as Map<String, Object?>)['city'])
            .toList(),
        ['Seoul', 'Paris'],
      );
    });

    test('keeps the originating declarations for the continuation', () async {
      final engine = _ScriptedToolCallEngine(
        toolCalls: const [
          _ScriptedToolCall(
            id: 'call_frozen',
            name: 'getWeather',
            arguments: '{"city":"Seoul"}',
          ),
        ],
        continuationText: 'Final answer.',
      );
      late ChatProvider provider;
      final host = _CountingHostToolService(
        onInvoke: () => provider.updateToolDeclarations('[]'),
      );
      provider = await buildProvider(engine, hostToolService: host);

      await provider.sendMessage('weather');

      expect(engine.createCallCount, 2);
      expect(engine.requestedToolNames, <List<String>>[
        <String>['getWeather'],
        <String>['getWeather'],
      ]);
    });

    test('stops after one tool batch and one continuation', () async {
      final engine = _AlwaysToolCallEngine();
      final spy = _CountingHostToolService();
      final provider = await buildProvider(engine, hostToolService: spy);

      await provider.sendMessage('weather in Seoul');

      expect(engine.createCallCount, 2);
      expect(spy.invocations, 1);
      expect(
        provider.messages.where((m) => m.role == LlamaChatRole.tool),
        hasLength(1),
      );
      expect(provider.messages.where((m) => m.isToolCall), hasLength(2));
      final repeatedCall = provider.messages.last;
      expect(repeatedCall.parts!.whereType<LlamaToolResultContent>(), isEmpty);
    });

    test('removes an empty final continuation without another call', () async {
      final engine = _ScriptedToolCallEngine(
        toolCalls: const [
          _ScriptedToolCall(
            id: 'call_empty_final',
            name: 'getWeather',
            arguments: '{"city":"Seoul"}',
          ),
        ],
        continuationText: '',
      );
      final provider = await buildProvider(engine);

      await provider.sendMessage('weather');

      expect(engine.createCallCount, 2);
      expect(provider.messages.where((m) => m.isToolCall), hasLength(1));
      expect(
        provider.messages.where((m) => m.role == LlamaChatRole.tool),
        hasLength(1),
      );
      expect(
        provider.messages.where(
          (m) => !m.isUser && !m.isInfo && m.role != LlamaChatRole.tool,
        ),
        hasLength(1),
      );

      await provider.sendMessage('next question');

      expect(engine.createCallCount, 3);
      expect(
        engine.requests.last.map((message) => message.role),
        <LlamaChatRole>[
          LlamaChatRole.system,
          LlamaChatRole.user,
          LlamaChatRole.assistant,
          LlamaChatRole.tool,
          LlamaChatRole.user,
        ],
      );
    });

    test('does not execute a tool when the request missed context', () async {
      final engine = _OversizedContextToolCallEngine();
      final spy = _CountingHostToolService();
      final provider = await buildProvider(engine, hostToolService: spy);

      await provider.sendMessage('weather');

      expect(engine.createCallCount, 1);
      expect(spy.invocations, 0);
      expect(
        provider.messages.where((m) => m.role == LlamaChatRole.tool),
        isEmpty,
      );
      expect(
        provider.messages.any(
          (message) => message.text.contains('no longer fits'),
        ),
        isTrue,
      );
    });

    test('does not mutate a cleared conversation mid tool execution', () async {
      final engine = _ScriptedToolCallEngine(
        toolCalls: const [
          _ScriptedToolCall(
            id: 'call_stale',
            name: 'getWeather',
            arguments: '{"city":"Seoul"}',
          ),
        ],
        continuationText: 'Stale continuation must not appear.',
      );
      late ChatProvider provider;
      final hostToolService = _CountingHostToolService(
        onInvoke: () => provider.clearConversation(),
      );
      provider = await buildProvider(engine, hostToolService: hostToolService);

      await provider.sendMessage('weather in Seoul');

      expect(hostToolService.invocations, 1);
      expect(engine.createCallCount, 1);
      expect(
        provider.messages.any((m) => m.role == LlamaChatRole.tool),
        isFalse,
      );
      expect(
        provider.messages.any(
          (m) => m.text == 'Stale continuation must not appear.',
        ),
        isFalse,
      );
    });

    test(
      'does not mutate a switched conversation mid tool execution',
      () async {
        final engine = _ScriptedToolCallEngine(
          toolCalls: const [
            _ScriptedToolCall(
              id: 'call_switched',
              name: 'getWeather',
              arguments: '{"city":"Seoul"}',
            ),
          ],
          continuationText: 'Stale continuation must not appear.',
        );
        late ChatProvider provider;
        Future<void>? switchFuture;
        late String targetConversationId;
        final hostToolService = _CountingHostToolService(
          onInvoke: () {
            switchFuture = provider.switchConversation(targetConversationId);
          },
        );
        provider = await buildProvider(
          engine,
          hostToolService: hostToolService,
        );
        final sourceConversationId = provider.activeConversationId;
        provider.createConversation();
        targetConversationId = provider.activeConversationId;
        await provider.switchConversation(sourceConversationId);

        await provider.sendMessage('weather in Seoul');
        await switchFuture;

        expect(provider.activeConversationId, targetConversationId);
        expect(hostToolService.invocations, 1);
        expect(engine.createCallCount, 1);
        expect(
          provider.messages.any((m) => m.role == LlamaChatRole.tool),
          isFalse,
        );
        expect(
          provider.messages.any(
            (m) => m.text == 'Stale continuation must not appear.',
          ),
          isFalse,
        );
      },
    );

    test('leaves a plain text turn as a single generation', () async {
      final engine = MockLlamaEngine()..createChunkContents = const ['Hello.'];
      final provider = await buildProvider(engine);

      await provider.sendMessage('hi');

      expect(engine.createCalls, 1);
      expect(
        provider.messages.any((m) => m.role == LlamaChatRole.tool),
        isFalse,
      );
      expect(provider.messages.last.text, 'Hello.');
    });
  });
}

class _AlwaysToolCallEngine extends MockLlamaEngine {
  int createCallCount = 0;

  @override
  Stream<LlamaCompletionChunk> create(
    List<LlamaChatMessage> messages, {
    GenerationParams? params,
    List<ToolDefinition>? tools,
    ToolChoice? toolChoice,
    bool parallelToolCalls = false,
    bool enableThinking = true,
    Map<String, dynamic>? responseFormat,
    String? sourceLangCode,
    String? targetLangCode,
    Map<String, dynamic>? chatTemplateKwargs,
    DateTime? templateNow,
  }) async* {
    createCallCount++;
    yield LlamaCompletionChunk(
      id: 'always-tool-call',
      object: 'chat.completion.chunk',
      created: 1,
      model: 'mock-model',
      choices: [
        LlamaCompletionChunkChoice(
          index: 0,
          delta: LlamaCompletionChunkDelta(
            toolCalls: [
              LlamaCompletionChunkToolCall(
                index: 0,
                id: 'call_repeat_$createCallCount',
                type: 'function',
                function: LlamaCompletionChunkFunction(
                  name: 'getWeather',
                  arguments: '{"city":"Seoul"}',
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _OversizedContextToolCallEngine extends _ScriptedToolCallEngine {
  _OversizedContextToolCallEngine()
    : super(
        toolCalls: const [
          _ScriptedToolCall(
            id: 'call_oversized',
            name: 'getWeather',
            arguments: '{"city":"Seoul"}',
          ),
        ],
        continuationText: 'Must not continue.',
      );

  @override
  Future<LlamaChatTemplateResult> chatTemplate(
    List<LlamaChatMessage> messages, {
    bool addAssistant = true,
    Map<String, dynamic>? jsonSchema,
    List<ToolDefinition>? tools,
    ToolChoice toolChoice = ToolChoice.auto,
    bool parallelToolCalls = false,
    bool enableThinking = true,
    Map<String, dynamic>? responseFormat,
    String? customTemplate,
    String? sourceLangCode,
    String? targetLangCode,
    bool includeTokenCount = true,
    Map<String, dynamic>? chatTemplateKwargs,
    DateTime? templateNow,
  }) async => const LlamaChatTemplateResult(
    prompt: 'oversized prompt',
    tokenCount: 100000,
  );
}

class _CountingHostToolService extends HostToolService {
  final void Function()? onInvoke;

  int invocations = 0;

  _CountingHostToolService({this.onInvoke});

  @override
  ToolHandler handlerFor(String toolName) {
    final delegate = super.handlerFor(toolName);
    return (ToolParams params) async {
      invocations += 1;
      onInvoke?.call();
      return delegate(params);
    };
  }
}

class _ThrowingHostToolService extends HostToolService {
  @override
  ToolHandler handlerFor(String toolName) {
    return (ToolParams params) async =>
        throw StateError('simulated handler failure');
  }
}

class _ScriptedToolCall {
  final String id;
  final String name;
  final String arguments;

  const _ScriptedToolCall({
    required this.id,
    required this.name,
    required this.arguments,
  });
}

class _ScriptedToolCallEngine extends MockLlamaEngine {
  final List<_ScriptedToolCall> toolCalls;
  final String continuationText;

  int createCallCount = 0;
  final List<List<LlamaChatMessage>> requests = <List<LlamaChatMessage>>[];
  final List<List<String>> requestedToolNames = <List<String>>[];

  _ScriptedToolCallEngine({
    required this.toolCalls,
    required this.continuationText,
  });

  @override
  Stream<LlamaCompletionChunk> create(
    List<LlamaChatMessage> messages, {
    GenerationParams? params,
    List<ToolDefinition>? tools,
    ToolChoice? toolChoice,
    bool parallelToolCalls = false,
    bool enableThinking = true,
    Map<String, dynamic>? responseFormat,
    String? sourceLangCode,
    String? targetLangCode,
    Map<String, dynamic>? chatTemplateKwargs,
    DateTime? templateNow,
  }) async* {
    createCallCount++;
    requests.add(List<LlamaChatMessage>.from(messages));
    requestedToolNames.add(
      tools?.map((tool) => tool.name).toList(growable: false) ?? const [],
    );

    if (createCallCount > 1) {
      yield LlamaCompletionChunk(
        id: 'continuation',
        object: 'chat.completion.chunk',
        created: 1,
        model: 'mock-model',
        choices: [
          LlamaCompletionChunkChoice(
            index: 0,
            delta: LlamaCompletionChunkDelta(content: continuationText),
          ),
        ],
      );
      return;
    }

    yield LlamaCompletionChunk(
      id: 'tool-call',
      object: 'chat.completion.chunk',
      created: 1,
      model: 'mock-model',
      choices: [
        LlamaCompletionChunkChoice(
          index: 0,
          delta: LlamaCompletionChunkDelta(
            toolCalls: [
              for (var index = 0; index < toolCalls.length; index++)
                LlamaCompletionChunkToolCall(
                  index: index,
                  id: toolCalls[index].id,
                  type: 'function',
                  function: LlamaCompletionChunkFunction(
                    name: toolCalls[index].name,
                    arguments: toolCalls[index].arguments,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
