import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_chat_example/providers/chat_provider.dart';
import 'package:llamadart_chat_example/models/chat_settings.dart';
import 'package:llamadart_chat_example/models/downloadable_model.dart';
import 'package:llamadart_chat_example/services/chat_service.dart';
import 'package:llamadart_chat_example/services/model_service_base.dart'
    as app_model_service;

import 'mocks.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ChatProvider provider;
  late MockChatService mockChatService;
  late MockSettingsService mockSettingsService;
  late MockLlamaEngine mockEngine;

  setUp(() async {
    mockEngine = MockLlamaEngine();
    mockChatService = MockChatService(engine: mockEngine);
    mockSettingsService = MockSettingsService();
    final initialSettings = const ChatSettings(modelPath: "test_model.gguf");
    mockSettingsService.settings = initialSettings;

    provider = ChatProvider(
      chatService: mockChatService,
      settingsService: mockSettingsService,
      initialSettings: initialSettings,
    );
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  group('ChatProvider Unit Tests', () {
    test('Initial state', () {
      expect(provider.messages, isEmpty);
      expect(provider.isInitializing, isFalse);
      expect(provider.settings.toolsEnabled, isFalse);
    });

    test('active model name omits remote URL credentials', () {
      final credentialedProvider = ChatProvider(
        chatService: MockChatService(),
        settingsService: MockSettingsService(),
        initialSettings: const ChatSettings(
          modelPath:
              'https://example.com/models/tiny.gguf?token=secret#signed-fragment',
        ),
      );
      addTearDown(credentialedProvider.dispose);

      expect(credentialedProvider.activeModelName, 'tiny.gguf');
    });

    test('loadModel success', () async {
      await provider.loadModel();

      expect(provider.isLoaded, isTrue);
      expect(provider.error, isNull);

      expect(
        provider.messages.any(
          (m) => m.text.contains('Model loaded successfully'),
        ),
        isTrue,
      );
      expect(mockEngine.initialized, isTrue);
      expect(provider.maxGenerationTokens, greaterThan(0));
    });

    test(
      'loadModel disables structured controls for LiteRT-LM web metadata',
      () async {
        final initialSettings = const ChatSettings(
          modelPath: 'https://example.com/gemma-4-web.litertlm',
          toolsEnabled: true,
          thinkingEnabled: true,
        );
        final settingsService = MockSettingsService()
          ..settings = initialSettings;
        final liteRtWebProvider = ChatProvider(
          chatService: MockChatService(
            engine: _MetadataEngine(const {
              'general.architecture': 'litert-lm',
              'llamadart.litert_lm_web.chat_scope': 'single-turn-text',
              'llamadart.litert_lm_web.structured_chat': 'false',
              'tokenizer.chat_template':
                  '{% for message in messages %}{% if loop.last %}{{ message["content"] }}{% endif %}{% endfor %}',
            }),
          ),
          settingsService: settingsService,
          initialSettings: initialSettings,
        );
        addTearDown(liteRtWebProvider.dispose);

        await liteRtWebProvider.loadModel();

        expect(liteRtWebProvider.templateSupportsTools, isFalse);
        expect(liteRtWebProvider.thinkingControlsSupported, isFalse);
        expect(liteRtWebProvider.settings.toolsEnabled, isFalse);
        expect(liteRtWebProvider.settings.thinkingEnabled, isFalse);
        expect(
          liteRtWebProvider.messages.map((message) => message.text),
          contains(
            contains(
              'LiteRT-LM Web currently exposes single-turn text generation only',
            ),
          ),
        );

        liteRtWebProvider.updateToolsEnabled(true);
        liteRtWebProvider.updateThinkingEnabled(true);

        expect(liteRtWebProvider.settings.toolsEnabled, isFalse);
        expect(liteRtWebProvider.settings.thinkingEnabled, isFalse);
      },
    );

    test(
      'web remote load prefetches model before runtime load and shows download stage',
      () async {
        final webEngine = MockLlamaEngine();
        final modelService = _RecordingModelService();
        final webProvider = ChatProvider(
          chatService: ChatService(engine: webEngine),
          settingsService: mockSettingsService,
          modelService: modelService,
          enableWebModelPrefetch: true,
          initialSettings: const ChatSettings(
            modelPath: 'https://example.com/models/tiny.gguf',
            mmprojPath: 'https://example.com/models/mmproj.gguf',
          ),
        );
        addTearDown(webProvider.dispose);

        final labels = <String>[];
        final progress = <double>[];
        webProvider.addListener(() {
          labels.add(webProvider.activeBackend);
          progress.add(webProvider.loadingProgress);
        });

        await webProvider.loadModel();

        expect(modelService.downloadCalls, 1);
        expect(modelService.lastModel?.url, webProvider.settings.modelPath);
        expect(modelService.lastModel?.mmprojUrl, isNull);
        expect(webEngine.lastLoadedModelUrl, webProvider.settings.modelPath);
        expect(webProvider.isLoaded, isTrue);
        expect(webProvider.error, isNull);
        expect(labels, contains('Downloading model 50%'));
        expect(labels, contains('Preparing WebGPU runtime...'));
        expect(labels, contains('Loading model into memory...'));
        expect(progress.any((value) => value > 0.14 && value < 0.72), isTrue);
      },
    );

    test('web remote load skips cache prefetch for credentialed urls', () async {
      final webEngine = MockLlamaEngine();
      final modelService = _RecordingModelService();
      final webProvider = ChatProvider(
        chatService: ChatService(engine: webEngine),
        settingsService: mockSettingsService,
        modelService: modelService,
        enableWebModelPrefetch: true,
        initialSettings: const ChatSettings(
          modelPath:
              'https://user:pass@example.com/models/tiny.gguf?token=secret#frag',
          mmprojPath: 'https://example.com/models/mmproj.gguf?sig=secret',
        ),
      );
      addTearDown(webProvider.dispose);

      final labels = <String>[];
      webProvider.addListener(() {
        labels.add(webProvider.activeBackend);
      });

      await webProvider.loadModel();

      expect(modelService.downloadCalls, 0);
      expect(webEngine.lastLoadedModelUrl, webProvider.settings.modelPath);
      expect(webProvider.isLoaded, isTrue);
      expect(webProvider.error, isNull);
      expect(
        labels,
        contains(
          'Browser cache skipped for credentialed URL; loading from network...',
        ),
      );
    });

    test(
      'web remote load skips prefetch when cache bridge is unavailable',
      () async {
        final webEngine = MockLlamaEngine();
        final modelService = _RecordingModelService(supportsPrefetch: false);
        final webProvider = ChatProvider(
          chatService: ChatService(engine: webEngine),
          settingsService: mockSettingsService,
          modelService: modelService,
          enableWebModelPrefetch: true,
          initialSettings: const ChatSettings(
            modelPath: 'https://example.com/models/tiny.gguf',
          ),
        );
        addTearDown(webProvider.dispose);

        await webProvider.loadModel();

        expect(modelService.downloadCalls, 0);
        expect(webEngine.lastLoadedModelUrl, webProvider.settings.modelPath);
        expect(webProvider.isLoaded, isTrue);
        expect(webProvider.error, isNull);
      },
    );

    test(
      'web remote load falls back to network when browser cache storage fails',
      () async {
        final webEngine = MockLlamaEngine();
        final modelService = _RecordingModelService(
          downloadError: Exception(
            'Failed to store prefetched model in browser cache.',
          ),
        );
        final webProvider = ChatProvider(
          chatService: ChatService(engine: webEngine),
          settingsService: mockSettingsService,
          modelService: modelService,
          enableWebModelPrefetch: true,
          initialSettings: const ChatSettings(
            modelPath: 'https://example.com/models/tiny.gguf',
          ),
        );
        addTearDown(webProvider.dispose);

        final labels = <String>[];
        webProvider.addListener(() {
          labels.add(webProvider.activeBackend);
        });

        await webProvider.loadModel();

        expect(modelService.downloadCalls, 1);
        expect(webEngine.lastLoadedModelUrl, webProvider.settings.modelPath);
        expect(webProvider.isLoaded, isTrue);
        expect(webProvider.error, isNull);
        expect(
          labels,
          contains('Browser cache unavailable; loading from network...'),
        );
      },
    );

    test(
      'web prefetch failure redacts signed urls from user-facing error',
      () async {
        final webProvider = ChatProvider(
          chatService: ChatService(engine: MockLlamaEngine()),
          settingsService: mockSettingsService,
          modelService: _RecordingModelService(
            downloadError: DioException(
              requestOptions: RequestOptions(
                path: 'https://example.com/models/tiny.gguf?token=secret',
              ),
              message:
                  'Failed https://user:pass@example.com/models/tiny.gguf?token=secret#frag',
            ),
          ),
          enableWebModelPrefetch: true,
          initialSettings: const ChatSettings(
            modelPath: 'https://example.com/models/tiny.gguf',
          ),
        );
        addTearDown(webProvider.dispose);

        await webProvider.loadModel();

        expect(webProvider.isLoaded, isFalse);
        expect(webProvider.error, isNotNull);
        expect(
          webProvider.error,
          contains('https://example.com/models/tiny.gguf'),
        );
        expect(webProvider.error, isNot(contains('token=secret')));
        expect(webProvider.error, isNot(contains('user:pass')));
        expect(webProvider.error, isNot(contains('#frag')));
      },
    );

    test(
      'web reload unloads existing runtime before prefetch can fail',
      () async {
        final webEngine = _UnloadRecordingEngine()..initialized = true;
        final webProvider = ChatProvider(
          chatService: ChatService(engine: webEngine),
          settingsService: mockSettingsService,
          modelService: _RecordingModelService(
            downloadError: Exception('offline'),
          ),
          enableWebModelPrefetch: true,
          initialSettings: const ChatSettings(
            modelPath: 'https://example.com/models/tiny.gguf',
          ),
        );
        addTearDown(webProvider.dispose);

        await webProvider.loadModel();

        expect(webEngine.unloadModelCalls, 1);
        expect(webEngine.initialized, isFalse);
        expect(webProvider.isLoaded, isFalse);
      },
    );

    test('loadConfiguredMmproj attaches projector to loaded model', () async {
      await provider.loadModel();
      provider.updateMmprojPath('test-mmproj.gguf');

      final loaded = await provider.loadConfiguredMmproj();

      expect(loaded, isTrue);
      expect(provider.hasConfiguredMmproj, isTrue);
      expect(provider.isMmprojLoaded, isTrue);
      expect(mockEngine.loadMultimodalProjectorCalls, 1);
    });

    test('clearMmprojPath unloads active projector immediately', () async {
      final mmprojProvider = ChatProvider(
        chatService: mockChatService,
        settingsService: mockSettingsService,
        initialSettings: const ChatSettings(
          modelPath: 'test_model.gguf',
          mmprojPath: 'test-mmproj.gguf',
        ),
      );

      await mmprojProvider.loadModel();
      expect(mmprojProvider.isMmprojLoaded, isTrue);

      await mmprojProvider.clearMmprojPath();

      expect(mmprojProvider.hasConfiguredMmproj, isFalse);
      expect(mmprojProvider.isMmprojLoaded, isFalse);
      expect(mockEngine.unloadMultimodalProjectorCalls, 1);
    });

    test(
      'Gemma projector audio warning requires declared audio capability',
      () async {
        for (final declaresAudio in [false, true]) {
          final gemmaProvider = ChatProvider(
            chatService: MockChatService(engine: MockLlamaEngine()),
            settingsService: mockSettingsService,
            initialSettings: ChatSettings(
              modelPath: 'gemma-4-test.gguf',
              mmprojPath: 'gemma-4-mmproj.gguf',
              modelSupportsVision: true,
              modelSupportsAudio: declaresAudio,
            ),
          );
          addTearDown(gemmaProvider.dispose);

          await gemmaProvider.loadModel();

          expect(
            gemmaProvider.messages.any(
              (message) => message.text.contains(
                'Gemma 4 GGUF projector currently exposes vision only',
              ),
            ),
            declaresAudio,
          );
        }
      },
    );

    test('loadModel failure', () async {
      final failingProvider = ChatProvider(
        chatService: mockChatService,
        settingsService: mockSettingsService,
        initialSettings: const ChatSettings(modelPath: ""),
      );

      await failingProvider.loadModel();

      expect(failingProvider.isLoaded, isFalse);
      expect(failingProvider.error, isNotNull);
    });

    test('sendMessage updates token count', () async {
      await provider.loadModel();
      expect(provider.currentTokens, 0);

      await provider.sendMessage("Hello");

      // MockEngine returns 5 for prompt tokens, and yields 1 response token (which we count as 1 increment)
      // Total expected: 5 (prompt) + 8 (generated tokens from mock backend yield) = 13
      // Wait, let's look at MockLlamaBackend:
      // yield [72, 105, 32, 116, 104, 101, 114, 101]; // "Hi there"
      // That's one yield. Our current implementation increments _currentTokens for each YIELD in the stream.
      // MockLlamaEngine.create yields once. So 1 generated token.
      // ChatProvider _currentTokens only tracks generated tokens.
      expect(provider.currentTokens, 1);
    });

    test('empty generation does not leave a ghost assistant row', () async {
      final emptyEngine = MockLlamaEngine()..createChunkContents = const [];
      final emptyProvider = ChatProvider(
        chatService: MockChatService(engine: emptyEngine),
        settingsService: mockSettingsService,
        initialSettings: const ChatSettings(modelPath: 'test_model.gguf'),
      );
      addTearDown(emptyProvider.dispose);

      await emptyProvider.loadModel();
      await emptyProvider.sendMessage('Hello');

      expect(
        emptyProvider.messages.where((message) => message.isUser),
        hasLength(1),
      );
      expect(
        emptyProvider.messages.where(
          (message) => !message.isUser && !message.isInfo,
        ),
        isEmpty,
      );
    });

    test('generation errors redact credentialed URLs', () async {
      final failingProvider = ChatProvider(
        chatService: MockChatService(
          engine: _FailingCreateEngine(
            Exception(
              'Request failed for '
              'https://example.com/model.gguf?token=secret#signed-fragment',
            ),
          ),
        ),
        settingsService: mockSettingsService,
        initialSettings: const ChatSettings(modelPath: 'test_model.gguf'),
      );
      addTearDown(failingProvider.dispose);

      await failingProvider.loadModel();
      await failingProvider.sendMessage('Hello');

      final errorMessage = failingProvider.messages.last;
      expect(errorMessage.isInfo, isTrue);
      expect(failingProvider.canRegenerateLastResponse, isFalse);
      expect(errorMessage.text, contains('https://example.com/model.gguf'));
      expect(errorMessage.text, isNot(contains('token=secret')));
      expect(errorMessage.text, isNot(contains('signed-fragment')));
    });

    test(
      'web remote load prefetches .litertlm models before runtime load',
      () async {
        final webEngine = MockLlamaEngine();
        final modelService = _RecordingModelService();
        final webProvider = ChatProvider(
          chatService: ChatService(engine: webEngine),
          settingsService: mockSettingsService,
          modelService: modelService,
          enableWebModelPrefetch: true,
          initialSettings: const ChatSettings(
            modelPath:
                'https://example.com/models/gemma-4-E2B-it-web.litertlm?download=true',
          ),
        );
        addTearDown(webProvider.dispose);

        await webProvider.loadModel();

        // LiteRT-LM web can consume cached browser bytes as a Blob, so the app
        // should prefetch once and let the backend initialize from CacheStorage.
        expect(modelService.downloadCalls, 1);
        expect(webEngine.lastLoadedModelUrl, webProvider.settings.modelPath);
        expect(webProvider.isLoaded, isTrue);
        expect(webProvider.error, isNull);
      },
    );

    test(
      'sendMessage swallows unsupported getTokenCount without an error bubble',
      () async {
        // The web LiteRT-LM backend exposes no tokenizer, so the post-reply
        // getTokenCount throws. That must not surface as a chat bubble,
        // whether the backend raises LlamaUnsupportedException or the raw
        // UnsupportedError.
        for (final error in <Object>[
          LlamaUnsupportedException('no tokenizer'),
          UnsupportedError('no tokenizer'),
        ]) {
          final tokenlessProvider = ChatProvider(
            chatService: MockChatService(engine: _TokenizerlessEngine(error)),
            settingsService: mockSettingsService,
            initialSettings: const ChatSettings(
              modelPath: 'test_model.litertlm',
            ),
          );
          addTearDown(tokenlessProvider.dispose);

          await tokenlessProvider.loadModel();
          await tokenlessProvider.sendMessage('Hello');

          expect(
            tokenlessProvider.messages.any(
              (m) => m.text.contains('Tokenization is not supported'),
            ),
            isFalse,
            reason:
                'unsupported tokenization must not become a bubble ($error)',
          );
          expect(
            tokenlessProvider.messages.any((m) => m.text.startsWith('Error:')),
            isFalse,
          );
          final assistant = tokenlessProvider.messages
              .where((m) => !m.isUser && !m.isInfo)
              .last;
          expect(assistant.text, 'Hi there');
          expect(assistant.tokenCount, greaterThan(0));
        }
      },
    );

    test('sendMessage prefers native perf token counts for metrics', () async {
      final perfEngine = MockLlamaEngine()
        ..performanceContext = const BackendPerfContextData(
          loadMs: 0,
          promptEvalMs: 250,
          evalMs: 2000,
          sampleMs: 0,
          promptEvalTokens: 26,
          evalTokens: 32,
          sampleCount: 32,
          reusedGraphs: 0,
        );
      final perfProvider = ChatProvider(
        chatService: MockChatService(engine: perfEngine),
        settingsService: mockSettingsService,
        initialSettings: const ChatSettings(modelPath: 'test_model.litertlm'),
      );

      await perfProvider.loadModel();
      await perfProvider.sendMessage('Hello');

      expect(perfProvider.currentTokens, 32);
      expect(perfProvider.lastNativePromptEvalTokens, 26);
      expect(perfProvider.lastNativeEvalTokens, 32);
      expect(perfProvider.lastDecodeTokensPerSecond, closeTo(16, 0.001));
    });

    test(
      'sendMessage corrects chunk overcount with native token count',
      () async {
        final perfEngine = MockLlamaEngine()
          ..createChunkContents = const ['A', 'B', 'C', 'D']
          ..performanceContext = const BackendPerfContextData(
            loadMs: 0,
            promptEvalMs: 250,
            evalMs: 1000,
            sampleMs: 0,
            promptEvalTokens: 8,
            evalTokens: 2,
            sampleCount: 2,
            reusedGraphs: 0,
          );
        final perfProvider = ChatProvider(
          chatService: MockChatService(engine: perfEngine),
          settingsService: mockSettingsService,
          initialSettings: const ChatSettings(modelPath: 'test_model.litertlm'),
        );

        await perfProvider.loadModel();
        await perfProvider.sendMessage('Hello');

        expect(perfProvider.currentTokens, 2);
        expect(perfProvider.lastNativeEvalTokens, 2);
        expect(perfProvider.lastDecodeTokensPerSecond, closeTo(2, 0.001));
      },
    );

    test('normalizes generic JSON response envelope for display', () async {
      final jsonEngine = _JsonResponseEngine();
      final jsonProvider = ChatProvider(
        chatService: MockChatService(engine: jsonEngine),
        settingsService: mockSettingsService,
        initialSettings: const ChatSettings(modelPath: 'test_model.gguf'),
      );

      await jsonProvider.loadModel();
      await jsonProvider.sendMessage('hello');

      final assistant = jsonProvider.messages
          .where((m) => !m.isUser && !m.isInfo)
          .last;
      expect(assistant.text, equals('Hello from JSON envelope.'));
      expect(assistant.debugBadges, contains('fmt:generic'));
      expect(assistant.debugBadges, contains('think:none'));
    });

    test('extracts think tags into dedicated thinking content', () async {
      final thinkingEngine = _ThinkTaggedResponseEngine();
      final thinkingProvider = ChatProvider(
        chatService: MockChatService(engine: thinkingEngine),
        settingsService: mockSettingsService,
        initialSettings: const ChatSettings(modelPath: 'test_model.gguf'),
      );

      await thinkingProvider.loadModel();
      thinkingProvider.updateThinkingEnabled(true);
      await thinkingProvider.sendMessage('reason briefly');

      final assistant = thinkingProvider.messages
          .where((m) => !m.isUser && !m.isInfo)
          .last;
      expect(assistant.text, equals('Final answer.'));
      expect(assistant.thinkingText, equals('plan first'));
      expect(assistant.debugBadges, contains('think:tag-parse'));
    });

    test('extracts Ministral-style plain reasoning fallback', () async {
      final engine = _MinistralPlainReasoningEngine();
      final providerWithFallback = ChatProvider(
        chatService: MockChatService(engine: engine),
        settingsService: mockSettingsService,
        initialSettings: const ChatSettings(modelPath: 'test_model.gguf'),
      );

      await providerWithFallback.loadModel();
      providerWithFallback.updateToolsEnabled(true);
      providerWithFallback.updateThinkingEnabled(true);
      await providerWithFallback.sendMessage('hi');

      final assistant = providerWithFallback.messages
          .where((m) => !m.isUser && !m.isInfo)
          .last;
      expect(assistant.thinkingText, contains('user has greeted me'));
      expect(assistant.text, equals('Hello! How can I help you today?'));
      expect(assistant.debugBadges, contains('think:parse'));
    });

    test('passes user-declared tools into generation when enabled', () async {
      final captureEngine = _ToolCaptureEngine();
      final customProvider = ChatProvider(
        chatService: MockChatService(engine: captureEngine),
        settingsService: mockSettingsService,
        initialSettings: const ChatSettings(modelPath: 'test_model.gguf'),
      );

      await customProvider.loadModel();
      final saved = customProvider.updateToolDeclarations('''
[
  {
    "name": "lookup_city",
    "description": "Lookup city info",
    "parameters": {
      "type": "object",
      "properties": {
        "city": {"type": "string"}
      },
      "required": ["city"]
    }
  }
]
''');
      expect(saved, isTrue);
      customProvider.updateToolsEnabled(true);

      await customProvider.sendMessage('find seoul');

      expect(captureEngine.createCallCount, 1);
      expect(captureEngine.lastToolChoice, ToolChoice.auto);
      expect(captureEngine.lastTools, isNotNull);
      expect(captureEngine.lastTools, hasLength(1));
      expect(captureEngine.lastTools!.first.name, 'lookup_city');
    });

    test('handles tool-call responses in a single pass', () async {
      final engine = _SinglePassToolCallEngine();
      final singlePassProvider = ChatProvider(
        chatService: MockChatService(engine: engine),
        settingsService: mockSettingsService,
        initialSettings: const ChatSettings(modelPath: 'test_model.gguf'),
      );

      await singlePassProvider.loadModel();
      singlePassProvider.updateToolsEnabled(true);
      singlePassProvider.resetToolDeclarations();

      await singlePassProvider.sendMessage('what time is it?');

      expect(engine.createCallCount, 1);
      final assistant = singlePassProvider.messages
          .where((m) => !m.isUser && !m.isInfo)
          .last;
      expect(assistant.isToolCall, isTrue);
      expect(
        assistant.parts?.whereType<LlamaToolCallContent>().length,
        equals(1),
      );
    });

    test(
      'parses FunctionGemma tool-call text into structured tool parts',
      () async {
        final engine = _FunctionGemmaRawCallTextEngine();
        final customProvider = ChatProvider(
          chatService: MockChatService(engine: engine),
          settingsService: mockSettingsService,
          initialSettings: const ChatSettings(modelPath: 'test_model.gguf'),
        );

        await customProvider.loadModel();
        customProvider.updateToolsEnabled(true);
        customProvider.resetToolDeclarations();

        await customProvider.sendMessage('weather in london');

        final assistant = customProvider.messages
            .where((m) => !m.isUser && !m.isInfo)
            .last;
        final toolCalls =
            assistant.parts?.whereType<LlamaToolCallContent>().toList(
              growable: false,
            ) ??
            const <LlamaToolCallContent>[];
        expect(assistant.isToolCall, isTrue);
        expect(toolCalls, hasLength(1));
        expect(toolCalls.first.name, equals('getWeather'));
        expect(toolCalls.first.arguments, equals({'city': 'London'}));
      },
    );

    test('rejects invalid tool declaration payload', () async {
      final result = provider.updateToolDeclarations('{"name":"bad"}');

      expect(result, isFalse);
      expect(provider.toolDeclarationsError, isNotNull);
      expect(provider.declaredToolCount, 0);
    });

    test('rejects non-string nested parameter description', () async {
      final result = provider.updateToolDeclarations('''
[
  {
    "name": "bad_nested_description",
    "parameters": {
      "type": "object",
      "properties": {
        "city": {
          "type": "string",
          "description": 1
        }
      }
    }
  }
]
''');

      expect(result, isFalse);
      expect(provider.toolDeclarationsError, isNotNull);
      expect(provider.toolDeclarationsError, contains('description'));
      expect(provider.declaredToolCount, 0);
    });

    test('invalid declarations in initial settings do not crash provider', () {
      final invalidSettingsProvider = ChatProvider(
        chatService: mockChatService,
        settingsService: mockSettingsService,
        initialSettings: const ChatSettings(
          modelPath: 'test_model.gguf',
          toolDeclarations:
              '[{"name":"x","parameters":{"type":"object","properties":{"a":{"type":"string","description":1}}}}]',
        ),
      );

      expect(invalidSettingsProvider.toolDeclarationsError, isNotNull);
      expect(invalidSettingsProvider.declaredToolCount, 0);
    });

    test('clearConversation resets tokens', () async {
      await provider.loadModel();
      await provider.sendMessage("Hello");
      expect(provider.currentTokens, greaterThan(0));

      provider.clearConversation();

      expect(provider.currentTokens, 0);
    });

    test('regenerate replaces the latest assistant response', () async {
      await provider.loadModel();
      mockEngine.createChunkContents = const ['First response'];
      await provider.sendMessage('Hello');

      expect(provider.canRegenerateLastResponse, isTrue);
      expect(mockEngine.createCalls, 1);
      expect(
        provider.messages.where((message) => message.isUser),
        hasLength(1),
      );
      final firstGenerationTokens = provider.currentTokens;
      expect(provider.messages.last.generatedTokenCount, firstGenerationTokens);

      mockEngine.createChunkContents = const ['Replacement response'];
      await provider.regenerateLastResponse();

      expect(mockEngine.createCalls, 2);
      expect(
        provider.messages.where((message) => message.isUser),
        hasLength(1),
      );
      expect(provider.messages.last.text, 'Replacement response');
      expect(provider.canRegenerateLastResponse, isTrue);
      expect(provider.currentTokens, firstGenerationTokens);
    });

    test('delete last conversation resets to a fresh one', () async {
      final initialId = provider.activeConversationId;

      await provider.deleteConversation(initialId);

      expect(provider.conversations.length, 1);
      expect(provider.activeConversationId, isNot(initialId));
      expect(provider.messages, isEmpty);
    });

    test('passes thinking controls to generation call', () async {
      final engine = _ThinkingControlCaptureEngine();
      final customProvider = ChatProvider(
        chatService: MockChatService(engine: engine),
        settingsService: mockSettingsService,
        initialSettings: const ChatSettings(modelPath: 'test_model.gguf'),
      );

      await customProvider.loadModel();
      customProvider.updateThinkingEnabled(false);
      customProvider.updateThinkingBudgetTokens(256);

      await customProvider.sendMessage('hello');

      expect(engine.lastEnableThinking, isFalse);
      expect(engine.lastTemplateKwargs?['enable_thinking'], isFalse);
      expect(engine.lastTemplateKwargs?['thinking_budget'], 256);
      expect(engine.lastTemplateKwargs?['reasoning_budget'], 256);
    });

    test(
      'shows multimodal context overflow guidance on prompt eval failure',
      () async {
        final engine = _FailingCreateEngine(
          Exception(
            'Multimodal prompt evaluation failed: 1. '
            'The active context window may be too small for this image and conversation history.',
          ),
        );
        final customProvider = ChatProvider(
          chatService: MockChatService(engine: engine),
          settingsService: mockSettingsService,
          initialSettings: const ChatSettings(modelPath: 'test_model.gguf'),
        );

        await customProvider.loadModel();
        await customProvider.sendMessage('hi');

        final infoMessage = customProvider.messages.where((m) => m.isInfo).last;
        expect(
          infoMessage.text,
          contains('exceeded the active context window'),
        );
        expect(
          customProvider.messages.any(
            (message) => !message.isUser && message.text.trim() == '...',
          ),
          isFalse,
        );
      },
    );

    test('updateSettings', () {
      provider.updateTemperature(0.5);
      expect(provider.settings.temperature, 0.5);

      provider.updateTopK(20);
      expect(provider.settings.topK, 20);

      provider.updateLogLevel(LlamaLogLevel.info);
      expect(provider.settings.logLevel, LlamaLogLevel.info);

      provider.updateNativeLogLevel(LlamaLogLevel.warn);
      expect(provider.settings.nativeLogLevel, LlamaLogLevel.warn);
    });

    test('Max enables Auto tuning and a manual layer disables it', () {
      provider.updateGpuLayers(99);
      expect(provider.settings.autoTuneModelParams, isTrue);

      provider.updateGpuLayers(48);
      expect(provider.settings.autoTuneModelParams, isFalse);
    });

    test('updateContextSize supports auto mode', () {
      provider.updateContextSize(0);
      expect(provider.settings.contextSize, 0);

      provider.updateContextSize(256);
      expect(provider.settings.contextSize, 512);
    });

    test('switching backend updates preference without model reload', () async {
      provider.updateGpuLayers(48);
      expect(provider.settings.gpuLayers, 48);
      final backendBeforeChange = provider.activeBackend;

      await provider.updatePreferredBackend(GpuBackend.cpu);

      expect(provider.settings.preferredBackend, GpuBackend.cpu);
      expect(provider.settings.gpuLayers, 48);
      expect(provider.activeBackend, backendBeforeChange);

      await provider.updatePreferredBackend(GpuBackend.auto);

      expect(provider.settings.preferredBackend, GpuBackend.auto);
      expect(provider.settings.gpuLayers, 48);
      expect(provider.activeBackend, backendBeforeChange);
    });

    test(
      'switching from zero-layer CPU to auto restores GPU offload',
      () async {
        provider.updateGpuLayers(0);
        await provider.updatePreferredBackend(GpuBackend.cpu);
        final backendBeforeChange = provider.activeBackend;

        await provider.updatePreferredBackend(GpuBackend.auto);

        expect(provider.settings.preferredBackend, GpuBackend.auto);
        expect(provider.settings.gpuLayers, 99);
        expect(provider.activeBackend, backendBeforeChange);
        expect(
          provider.messages.last.text,
          contains('GPU offload restored to Max'),
        );
      },
    );

    test('applyModelPreset updates generation and tool settings', () {
      const model = DownloadableModel(
        name: 'Preset model',
        description: 'Preset test model',
        url: 'https://example.com/model.gguf',
        filename: 'model.gguf',
        sizeBytes: 1,
        supportsToolCalling: true,
        preset: ModelPreset(
          temperature: 0.1,
          topK: 12,
          topP: 0.8,
          contextSize: 8192,
          maxTokens: 512,
          gpuLayers: 99,
        ),
      );

      provider.applyModelPreset(model);

      expect(provider.settings.temperature, 0.1);
      expect(provider.settings.topK, 12);
      expect(provider.settings.topP, 0.8);
      expect(provider.settings.contextSize, 8192);
      expect(provider.settings.maxTokens, 512);
      expect(provider.settings.gpuLayers, 99);
      expect(provider.settings.autoTuneModelParams, isTrue);
      expect(provider.settings.modelBytesHint, model.sizeBytes);
      expect(provider.settings.toolsEnabled, isFalse);
    });

    test('persisted Auto intent re-estimates a partial prior result', () async {
      final engine = _LargeMemoryEstimateEngine();
      final customProvider = ChatProvider(
        chatService: MockChatService(engine: engine),
        settingsService: mockSettingsService,
        initialSettings: const ChatSettings(
          modelPath: 'large-model.gguf',
          preferredBackend: GpuBackend.auto,
          gpuLayers: 66,
          contextSize: 4096,
          modelBytesHint: 20 * 1024 * 1024 * 1024,
          autoTuneModelParams: true,
          autoTuneRequestedContextSize: 16384,
        ),
      );

      await customProvider.loadModel();

      expect(customProvider.settings.gpuLayers, ModelParams.maxGpuLayers);
      expect(customProvider.settings.contextSize, 16384);
      expect(customProvider.settings.autoTuneModelParams, isTrue);
    });

    test('applyModelPreset disables tools when unsupported', () {
      const model = DownloadableModel(
        name: 'No tools model',
        description: 'No tools preset model',
        url: 'https://example.com/no-tools.gguf',
        filename: 'no-tools.gguf',
        sizeBytes: 1,
        supportsToolCalling: false,
      );

      provider.updateToolsEnabled(true);
      provider.applyModelPreset(model);

      expect(provider.settings.toolsEnabled, isFalse);
    });

    test(
      'auto backend keeps preference while runtime backend is detected',
      () async {
        final engine = _MacFallbackEstimateEngine();
        final customProvider = ChatProvider(
          chatService: MockChatService(engine: engine),
          settingsService: mockSettingsService,
          initialSettings: const ChatSettings(
            modelPath: 'test_model.gguf',
            gpuLayers: 32,
            preferredBackend: GpuBackend.auto,
          ),
        );

        await customProvider.loadModel();

        expect(customProvider.settings.gpuLayers, 32);
        expect(customProvider.settings.preferredBackend, GpuBackend.auto);
        expect(customProvider.activeBackend, 'METAL');
      },
    );

    test(
      'reload keeps gpu layers when backend is explicitly selected',
      () async {
        final customProvider = ChatProvider(
          chatService: mockChatService,
          settingsService: mockSettingsService,
          initialSettings: const ChatSettings(
            modelPath: 'test_model.gguf',
            gpuLayers: 32,
            preferredBackend: GpuBackend.metal,
          ),
        );

        await customProvider.loadModel();
        expect(customProvider.settings.gpuLayers, 32);

        await customProvider.unloadModel();
        await customProvider.loadModel();
        expect(customProvider.settings.gpuLayers, 32);
        expect(customProvider.settings.preferredBackend, GpuBackend.metal);
      },
    );

    test(
      'applyModelPreset preserves manual tool preference when supported',
      () {
        const model = DownloadableModel(
          name: 'Forced tool model',
          description: 'Force tool test model',
          url: 'https://example.com/forced-tools.gguf',
          filename: 'forced-tools.gguf',
          sizeBytes: 1,
          supportsToolCalling: true,
        );

        provider.updateToolsEnabled(true);
        provider.applyModelPreset(model);

        expect(provider.settings.toolsEnabled, isTrue);
      },
    );

    test('built-in catalog is focused and Unsloth-first', () {
      expect(
        DownloadableModel.defaultModels.map((model) => model.name),
        orderedEquals(const [
          'FunctionGemma 270M',
          'Qwen3.5 0.8B Instruct',
          'Qwen3-ASR 0.6B',
          'Gemma 4 E2B it',
          'Gemma 4 E2B LiteRT-LM',
          'Gemma 4 E4B it',
          'Gemma 4 12B it',
          'Gemma 4 26B A4B it',
          'Gemma 4 31B it',
          'Qwen3.6 35B A3B',
        ]),
      );

      final ggufModels = DownloadableModel.defaultModels.where(
        (model) => model.filename.endsWith('.gguf'),
      );
      for (final model in ggufModels) {
        if (model.supportsSpeechToText) {
          expect(model.distribution, 'ggml-org');
          expect(model.url, contains('huggingface.co/ggml-org/'));
        } else {
          expect(model.distribution, 'Unsloth');
          expect(model.url, contains('huggingface.co/unsloth/'));
        }
      }
    });

    test('Qwen3-ASR catalog entry pins its complete verified bundle', () {
      final model = DownloadableModel.defaultModels.singleWhere(
        (model) => model.name == 'Qwen3-ASR 0.6B',
      );
      final modelSource = model.modelSource as RemoteModelAssetSource;
      final projectorSource =
          model.multimodalProjectorSource as RemoteModelAssetSource;

      expect(model.supportsAudio, isTrue);
      expect(model.supportsSpeechToTextFor(web: false), isTrue);
      expect(model.supportsSpeechToTextFor(web: true), isFalse);
      expect(model.isNativeDesktopOnly, isTrue);
      expect(model.sizeBytesFor(web: false), 1019141728);
      expect(model.preset.temperature, 0);
      expect(model.preset.topK, 1);
      expect(model.preset.topP, 1);
      expect(model.preset.penalty, 1);
      expect(model.preset.contextSize, 4096);
      expect(model.preset.maxTokens, 1024);
      expect(model.preset.thinkingEnabled, isFalse);
      expect(modelSource.sizeBytes, 804749248);
      expect(
        modelSource.sha256,
        'bca259818b50ca7c4c05e9bdb35a5dc04fa039653a6d6f3f0f331f96f6aa1971',
      );
      expect(projectorSource.sizeBytes, 214392480);
      expect(
        projectorSource.sha256,
        '41a342b5e4c514e968cb756de6cd1b7be39eff43c44c57a2ef5fc6522e36603d',
      );
      expect(
        modelSource.url,
        contains('928ab958557df9aa2ef1c93e0e83c7ad0933fae2'),
      );
      expect(
        projectorSource.url,
        contains('928ab958557df9aa2ef1c93e0e83c7ad0933fae2'),
      );
    });

    test('Qwen3.5 0.8B uses Unsloth Q4_K_M non-thinking defaults', () {
      final qwenModels = DownloadableModel.defaultModels
          .where((model) => model.name.startsWith('Qwen3.5 '))
          .toList(growable: false);

      expect(qwenModels, hasLength(1));

      for (final model in qwenModels) {
        expect(model.url, contains('huggingface.co/unsloth/Qwen3.5-'));
        expect(model.url, contains('Q4_K_M.gguf'));
        expect(model.supportsThinking, isTrue);
        expect(model.preset.thinkingEnabled, isFalse);
        expect(model.preset.temperature, 0.7);
        expect(model.preset.topK, 20);
        expect(model.preset.topP, 0.8);
        expect(model.preset.penalty, 1.0);
      }

      final small = qwenModels.singleWhere(
        (model) => model.name == 'Qwen3.5 0.8B Instruct',
      );
      expect(small.preset.contextSize, 4096);
    });

    test('large models are native-desktop-only while Gemma E4B is not', () {
      final desktopModels = DownloadableModel.defaultModels
          .where((model) => model.isNativeDesktopOnly)
          .toList(growable: false);

      expect(
        desktopModels.map((model) => model.name),
        orderedEquals(const [
          'Qwen3-ASR 0.6B',
          'Gemma 4 12B it',
          'Gemma 4 26B A4B it',
          'Gemma 4 31B it',
          'Qwen3.6 35B A3B',
        ]),
      );
      for (final model in desktopModels) {
        expect(model.isAvailableFor(web: false, mobile: false), isTrue);
        expect(model.isAvailableFor(web: false, mobile: true), isFalse);
        expect(model.isAvailableFor(web: true, mobile: false), isFalse);
      }

      final gemmaE4b = DownloadableModel.defaultModels.singleWhere(
        (model) => model.name == 'Gemma 4 E4B it',
      );
      expect(gemmaE4b.isNativeDesktopOnly, isFalse);
      expect(gemmaE4b.isAvailableFor(web: false, mobile: true), isTrue);
      expect(gemmaE4b.supportsAudioFor(web: false), isTrue);
    });

    test('Qwen3-ASR preset persists the dedicated STT declaration', () {
      final model = DownloadableModel.defaultModels.singleWhere(
        (model) => model.name == 'Qwen3-ASR 0.6B',
      );

      provider.applyModelPreset(model);

      expect(provider.settings.modelSupportsAudio, isTrue);
      expect(provider.settings.modelSupportsSpeechToText, isTrue);
    });

    test('Gemma 4 presets expose platform-specific audio capabilities', () {
      final ggufModel = DownloadableModel.defaultModels.singleWhere(
        (model) => model.name == 'Gemma 4 E2B it',
      );
      final liteRtModel = DownloadableModel.defaultModels.singleWhere(
        (model) => model.name == 'Gemma 4 E2B LiteRT-LM',
      );

      expect(ggufModel.supportsAudioFor(web: false), isTrue);
      expect(ggufModel.supportsAudioFor(web: true), isFalse);
      expect(
        ggufModel.mediaInputModeFor(web: false),
        ModelMediaInputMode.externalProjector,
      );
      expect(liteRtModel.supportsAudioFor(web: false), isTrue);
      expect(liteRtModel.supportsAudioFor(web: true), isFalse);
      expect(
        liteRtModel.mediaInputModeFor(web: false),
        ModelMediaInputMode.direct,
      );
      expect(
        liteRtModel.mediaInputModeFor(web: true),
        ModelMediaInputMode.none,
      );
    });

    test(
      'native LiteRT-LM preset enables direct audio after model load',
      () async {
        final liteRtModel = DownloadableModel.defaultModels.singleWhere(
          (model) => model.name == 'Gemma 4 E2B LiteRT-LM',
        );

        provider.updateModelPath('gemma-4-E2B-it.litertlm');
        provider.applyModelPreset(liteRtModel);
        await provider.loadModel();

        expect(provider.settings.modelSupportsAudio, isTrue);
        expect(provider.settings.directMediaInput, isTrue);
        expect(provider.supportsAudio, isTrue);
        expect(provider.canAttachMedia, isTrue);
        expect(provider.hasConfiguredMmproj, isFalse);
      },
    );

    test('applyModelPreset prefers CPU for Qwen3.5 0.8B on Android', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final qwenModel = DownloadableModel.defaultModels.singleWhere(
        (model) => model.name == 'Qwen3.5 0.8B Instruct',
      );

      provider.applyModelPreset(qwenModel);

      expect(provider.settings.preferredBackend, GpuBackend.cpu);
      expect(provider.settings.gpuLayers, 0);
    });

    test('applyModelPreset reduces Android context for Qwen3.5 0.8B', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final qwenModel = DownloadableModel.defaultModels.singleWhere(
        (model) => model.name == 'Qwen3.5 0.8B Instruct',
      );

      provider.applyModelPreset(qwenModel);

      expect(provider.settings.contextSize, 2048);
    });

    test('applyModelPreset uses LiteRT-LM preset values on Android', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final liteRtModel = DownloadableModel.defaultModels.singleWhere(
        (model) => model.name == 'Gemma 4 E2B LiteRT-LM',
      );

      provider.applyModelPreset(liteRtModel);

      expect(provider.settings.preferredBackend, GpuBackend.auto);
      expect(provider.settings.gpuLayers, liteRtModel.preset.gpuLayers);
      expect(provider.settings.contextSize, liteRtModel.preset.contextSize);
      expect(provider.settings.maxTokens, liteRtModel.preset.maxTokens);
    });
  });

  group('MockChatService Tests', () {
    test('cleanResponse trims whitespace', () {
      final result = mockChatService.cleanResponse('  hello world  ');
      expect(result, '  hello world  '); // MockChatService doesn't trim
    });
  });
}

class _MetadataEngine extends MockLlamaEngine {
  final Map<String, String> metadata;

  _MetadataEngine(this.metadata);

  @override
  Future<Map<String, String>> getMetadata() async => metadata;
}

class _JsonResponseEngine extends MockLlamaEngine {
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
    yield LlamaCompletionChunk(
      id: 'json-id',
      object: 'chat.completion.chunk',
      created: 1,
      model: 'mock-model',
      choices: [
        LlamaCompletionChunkChoice(
          index: 0,
          delta: LlamaCompletionChunkDelta(
            content: '{"response":"Hello from JSON envelope."}',
          ),
        ),
      ],
    );
  }
}

class _ThinkTaggedResponseEngine extends MockLlamaEngine {
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
    yield LlamaCompletionChunk(
      id: 'think-id',
      object: 'chat.completion.chunk',
      created: 1,
      model: 'mock-model',
      choices: [
        LlamaCompletionChunkChoice(
          index: 0,
          delta: LlamaCompletionChunkDelta(
            content: '<think>plan first</think>Final answer.',
          ),
        ),
      ],
    );
  }
}

class _MinistralPlainReasoningEngine extends MockLlamaEngine {
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
    yield LlamaCompletionChunk(
      id: 'ministral-plain-id',
      object: 'chat.completion.chunk',
      created: 1,
      model: 'mock-model',
      choices: [
        LlamaCompletionChunkChoice(
          index: 0,
          delta: LlamaCompletionChunkDelta(
            content:
                'Alright, the user has greeted me. I should respond politely.\n\nResponse:\n"Hello! How can I help you today?"Hello! How can I help you today?',
          ),
        ),
      ],
    );
  }
}

class _ToolCaptureEngine extends MockLlamaEngine {
  int createCallCount = 0;
  List<ToolDefinition>? lastTools;
  ToolChoice? lastToolChoice;

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
    lastTools = tools;
    lastToolChoice = toolChoice;

    yield LlamaCompletionChunk(
      id: 'capture-id',
      object: 'chat.completion.chunk',
      created: 1,
      model: 'mock-model',
      choices: [
        LlamaCompletionChunkChoice(
          index: 0,
          delta: LlamaCompletionChunkDelta(content: 'ok'),
        ),
      ],
    );
  }
}

class _SinglePassToolCallEngine extends MockLlamaEngine {
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
      id: 'single-pass-tool-call',
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
                id: 'call_1',
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

class _ThinkingControlCaptureEngine extends MockLlamaEngine {
  bool? lastEnableThinking;
  Map<String, dynamic>? lastTemplateKwargs;

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
    lastEnableThinking = enableThinking;
    lastTemplateKwargs = chatTemplateKwargs;

    yield LlamaCompletionChunk(
      id: 'thinking-control',
      object: 'chat.completion.chunk',
      created: 1,
      model: 'mock-model',
      choices: [
        LlamaCompletionChunkChoice(
          index: 0,
          delta: LlamaCompletionChunkDelta(content: 'ok'),
        ),
      ],
    );
  }
}

class _MacFallbackEstimateEngine extends MockLlamaEngine {
  @override
  Future<({int total, int free})> getVramInfo() async => (total: 0, free: 0);

  @override
  Future<String> getBackendName() async => 'CPU, METAL';

  @override
  Future<String> getAvailableBackends() async => 'CPU, METAL';
}

class _LargeMemoryEstimateEngine extends MockLlamaEngine {
  @override
  Future<({int total, int free})> getVramInfo() async =>
      (total: 64 * 1024 * 1024 * 1024, free: 56 * 1024 * 1024 * 1024);

  @override
  Future<String> getBackendName() async => 'METAL';

  @override
  Future<String> getAvailableBackends() async => 'CPU, METAL';
}

class _UnloadRecordingEngine extends MockLlamaEngine {
  int unloadModelCalls = 0;

  @override
  Future<void> unloadModel() async {
    unloadModelCalls += 1;
    initialized = false;
  }
}

class _TokenizerlessEngine extends MockLlamaEngine {
  _TokenizerlessEngine(this.tokenCountError);

  final Object tokenCountError;

  @override
  Future<int> getTokenCount(String text) async => throw tokenCountError;
}

class _FailingCreateEngine extends MockLlamaEngine {
  _FailingCreateEngine(this.error);

  final Object error;

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
  }) {
    throw error;
  }
}

class _RecordingModelService
    implements
        app_model_service.ModelService,
        app_model_service.WebCachePrefetchModelService {
  _RecordingModelService({this.supportsPrefetch = true, this.downloadError});

  final bool supportsPrefetch;
  final Object? downloadError;
  int downloadCalls = 0;
  DownloadableModel? lastModel;

  @override
  Future<bool> supportsWebCachePrefetch() async => supportsPrefetch;

  @override
  Future<String> getModelsDirectory() async => 'browser-cache';

  @override
  Future<Set<String>> getDownloadedModels(
    List<DownloadableModel> models,
  ) async {
    return <String>{};
  }

  @override
  Future<app_model_service.ModelProfileCacheState> getModelCacheState(
    DownloadableModel model,
  ) async {
    final mmprojSource = model.multimodalProjectorSource;
    return app_model_service.ModelProfileCacheState(
      model: app_model_service.ModelAssetCacheState(
        role: ModelAssetRole.model,
        label: model.modelSource.displayName,
        isAvailable: false,
      ),
      multimodalProjector: mmprojSource == null
          ? null
          : app_model_service.ModelAssetCacheState(
              role: ModelAssetRole.multimodalProjector,
              label: mmprojSource.displayName,
              isAvailable: false,
            ),
    );
  }

  @override
  Future<void> downloadModel({
    required DownloadableModel model,
    required String modelsDir,
    required CancelToken cancelToken,
    required Function(double progress) onProgress,
    Function(app_model_service.ModelDownloadProgress progress)?
    onProgressDetail,
    required Function(String filename) onSuccess,
    required Function(dynamic error) onError,
  }) async {
    downloadCalls += 1;
    lastModel = model;
    if (downloadError != null) {
      onError(downloadError);
      return;
    }
    onProgress(0.0);
    onProgress(0.5);
    onProgress(1.0);
    onSuccess(model.filename);
  }

  @override
  Future<void> deleteModel(String modelsDir, DownloadableModel model) async {}
}

class _FunctionGemmaRawCallTextEngine extends MockLlamaEngine {
  @override
  Future<Map<String, String>> getMetadata() async => {
    'tokenizer.chat_template': '<start_function_declaration>',
  };

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
    yield LlamaCompletionChunk(
      id: 'function-gemma-tool',
      object: 'chat.completion.chunk',
      created: 1,
      model: 'mock-model',
      choices: [
        LlamaCompletionChunkChoice(
          index: 0,
          delta: LlamaCompletionChunkDelta(
            content:
                '<start_function_call>call getWeather{city:<escape>London<escape>}<end_function_call>',
          ),
        ),
      ],
    );
  }
}
