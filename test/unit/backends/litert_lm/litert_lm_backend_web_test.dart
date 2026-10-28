@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:llamadart/llamadart.dart' as api;
import 'package:llamadart/backend.dart' as spi;
import 'package:llamadart/src/backends/litert_lm/litert_lm_backend_web.dart';
import 'package:llamadart/src/backends/web/web_backend.dart';
import 'package:llamadart/src/core/engine/engine.dart';
import 'package:llamadart/src/core/engine/engine_observer.dart';
import 'package:llamadart/src/core/exceptions.dart';
import 'package:llamadart/src/core/models/chat/chat_message.dart';
import 'package:llamadart/src/core/models/chat/chat_role.dart';
import 'package:llamadart/src/core/models/chat/content_part.dart';
import 'package:llamadart/src/core/models/config/compute_device.dart';
import 'package:llamadart/src/core/models/config/gpu_backend.dart';
import 'package:llamadart/src/core/models/config/log_level.dart';
import 'package:llamadart/src/core/models/inference/generation_params.dart';
import 'package:llamadart/src/core/models/inference/model_params.dart';
import 'package:llamadart/src/core/models/model_format.dart';
import 'package:llamadart/src/core/template/chat_template_engine.dart';
import 'package:test/test.dart';
import 'package:web/web.dart';

import '../../../support/fake_navigator_gpu.dart';

mixin _GenerateOverride on spi.LlamaBackend {
  int generateCalls = 0;

  @override
  Stream<List<int>> generate(
    int contextHandle,
    String prompt,
    GenerationParams params, {
    List<LlamaContentPart>? parts,
  }) {
    generateCalls++;
    return Stream.value(utf8.encode('OVERRIDE'));
  }
}

mixin _NativeChatOverride on spi.LlamaBackend
    implements spi.BackendNativeChatGeneration {
  int nativeCalls = 0;

  @override
  bool get supportsNativeChatGeneration => true;

  @override
  Stream<List<int>> generateChat(
    int contextHandle,
    List<LlamaChatMessage> messages,
    GenerationParams params, {
    List<api.ToolDefinition>? tools,
    api.ToolChoice toolChoice = api.ToolChoice.auto,
    bool parallelToolCalls = false,
    bool enableThinking = true,
    Map<String, dynamic>? chatTemplateKwargs,
    String? sourceLangCode,
    String? targetLangCode,
    DateTime? templateNow,
  }) {
    nativeCalls++;
    return Stream.value(utf8.encode('EXPLICIT'));
  }
}

final class _LegacyLiteRtGenerate extends LiteRtLmBackend
    with _GenerateOverride {}

final class _LegacyLiteRtNative extends LiteRtLmBackend
    with _NativeChatOverride {}

final class _LegacyWebGenerate extends WebAutoBackend with _GenerateOverride {
  _LegacyWebGenerate() : super(liteRtLmFactory: LiteRtLmBackend.new);
}

final class _LegacyWebNative extends WebAutoBackend with _NativeChatOverride {
  _LegacyWebNative() : super(liteRtLmFactory: LiteRtLmBackend.new);
}

void main() {
  test('embedding engine names the CPU a deprecated preferred backend selects '
      'before I/O', () async {
    var creates = 0;
    _installFakeEngine(chunks: [], onCreate: (_) => creates++);
    final backend = LiteRtLmBackend(
      readyTimeout: Duration.zero,
      // ignore: deprecated_member_use_from_same_package
      preferredBackend: 'cpu',
    );
    addTearDown(backend.dispose);
    await expectLater(
      backend.modelLoad(
        'private.litertlm',
        const ModelParams(liteRtLmEmbeddingEngine: true),
      ),
      throwsA(
        isA<LlamaUnsupportedException>().having(
          (e) => e.message,
          'condition',
          contains('Failed to get external weight'),
        ),
      ),
    );
    expect(creates, 0);
  });

  for (final device in [ComputeDevice.cpu, ComputeDevice.gpu]) {
    test(
      'embedding engine rejects unqualified Web ${device.name} before I/O',
      () async {
        var creates = 0;
        _installFakeEngine(chunks: [], onCreate: (_) => creates++);
        final backend = LiteRtLmBackend(readyTimeout: Duration.zero);
        addTearDown(backend.dispose);
        await expectLater(
          backend.modelLoad(
            'private.litertlm',
            ModelParams(liteRtLmEmbeddingEngine: true, device: device),
          ),
          throwsA(
            isA<LlamaUnsupportedException>().having(
              (e) => e.message,
              'condition',
              contains(
                device == ComputeDevice.cpu
                    ? 'Failed to get external weight'
                    : 'parity',
              ),
            ),
          ),
        );
        expect(creates, 0);
        expect(backend.isReady, isFalse);
        expect(backend.supportsEmbeddings, isFalse);
      },
    );
  }

  setUp(_clearGlobals);
  tearDown(_clearGlobals);

  for (final (name, spi.LlamaBackend Function() factory) in [
    ('LiteRtLmBackend', _LegacyLiteRtGenerate.new),
    ('WebAutoBackend', _LegacyWebGenerate.new),
  ]) {
    test(
      '$name legacy subclass generate override serves raw and chat requests',
      () async {
        _installFakeEngine(
          textHistory: true,
          chunks: [_messageChunk('RUNTIME')],
        );
        final backend = factory();
        final engine = LlamaEngine(backend);
        addTearDown(engine.dispose);
        await engine.loadModelFromUrl('model.litertlm');
        expect((await engine.capabilities).supportsMultiTurnChat, isFalse);
        expect(await engine.generate('raw').join(), 'OVERRIDE');
        final chunks = await engine.create(const [
          LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'chat'),
        ]).toList();
        expect(chunks.map((chunk) => chunk.text).join(), 'OVERRIDE');
        expect((backend as _GenerateOverride).generateCalls, 2);
      },
    );
  }
  for (final (name, spi.LlamaBackend Function() factory) in [
    ('LiteRtLmBackend', _LegacyLiteRtNative.new),
    ('WebAutoBackend', _LegacyWebNative.new),
  ]) {
    test('$name explicit native SPI override serves chat requests', () async {
      _installFakeEngine(textHistory: true, chunks: [_messageChunk('RUNTIME')]);
      final backend = factory();
      final engine = LlamaEngine(backend);
      addTearDown(engine.dispose);
      await engine.loadModelFromUrl('model.litertlm');
      final chunks = await engine.create(const [
        LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'chat'),
      ]).toList();
      expect(chunks.map((chunk) => chunk.text).join(), 'EXPLICIT');
      expect((backend as _NativeChatOverride).nativeCalls, 1);
    });
  }
  for (final (name, factory, expected)
      in <(String, spi.LlamaBackend Function(), String)>[
        ('legacy generate', _LegacyLiteRtGenerate.new, 'OVERRIDE'),
        ('explicit native SPI', _LegacyLiteRtNative.new, 'EXPLICIT'),
      ]) {
    test(
      'text-history factory router preserves $name custom delegate',
      () async {
        _installFakeEngine(
          textHistory: true,
          chunks: [_messageChunk('RUNTIME')],
        );
        final engine = LlamaEngine(
          WebAutoBackend.withTextHistory(liteRtLmFactory: factory),
        );
        addTearDown(engine.dispose);
        await engine.loadModelFromUrl('model.litertlm');
        expect((await engine.capabilities).supportsMultiTurnChat, isFalse);
        final chunks = await engine.create(const [
          LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'chat'),
        ]).toList();
        expect(chunks.map((chunk) => chunk.text).join(), expected);
      },
    );
  }

  test(
    'default factory preserves legacy LiteRT Web requests and capabilities',
    () async {
      var prompts = <String>[];
      final prefaces = <Object?>[];
      _installFakeEngine(
        textHistory: true,
        chunks: [_messageChunk('legacy')],
        onPrompt: prompts.add,
        onCreateConversation: (config) =>
            prefaces.add(config.getProperty<JSAny?>('preface'.toJS)?.dartify()),
      );
      final engine = LlamaEngine(spi.LlamaBackend());
      addTearDown(engine.dispose);
      await engine.loadModelFromUrl('model.litertlm');
      expect((await engine.capabilities).supportsMultiTurnChat, isFalse);
      final chunks = await engine
          .create(
            const [
              LlamaChatMessage.fromText(
                role: LlamaChatRole.system,
                text: 'old system',
              ),
              LlamaChatMessage.fromText(
                role: LlamaChatRole.user,
                text: 'old user',
              ),
              LlamaChatMessage.fromText(
                role: LlamaChatRole.assistant,
                text: 'old answer',
              ),
              LlamaChatMessage.fromText(
                role: LlamaChatRole.user,
                text: 'latest',
              ),
            ],
            enableThinking: false,
            chatTemplateKwargs: const {'enable_thinking': false},
          )
          .toList();
      expect(chunks.map((chunk) => chunk.text).join(), 'legacy');
      expect(prompts, ['latest']);
      expect(prefaces, [null]);
    },
  );

  for (final (preface, historyApi, expected) in [
    (false, true, false),
    (true, false, false),
    (true, true, true),
  ]) {
    test(
      'text history probes consumed preface=$preface historyApi=$historyApi',
      () async {
        var prompts = 0;
        _installFakeEngine(
          textHistory: preface,
          historyApi: historyApi,
          chunks: [_messageChunk('ok')],
          onPrompt: (_) => prompts++,
        );
        final backend = LiteRtLmBackend.withTextHistory();
        final engine = LlamaEngine(backend);
        addTearDown(engine.dispose);
        expect(backend.supportsMultiTurnChat, isFalse);
        await engine.loadModelFromUrl('model.litertlm');
        expect((await engine.capabilities).supportsMultiTurnChat, expected);
        expect(prompts, 0, reason: 'Capability probe must run no inference');
        final request = engine.create(const [
          LlamaChatMessage.fromText(
            role: LlamaChatRole.system,
            text: 'Be terse.',
          ),
          LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'hi'),
        ]).toList();
        if (expected) {
          expect((await request).map((c) => c.text).join(), 'ok');
        } else {
          await expectLater(request, throwsA(isA<LlamaUnsupportedException>()));
          expect(prompts, 0);
          expect(
            (await engine.create(const [
              LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'hi'),
            ]).toList()).map((c) => c.text).join(),
            'ok',
          );
        }
        await engine.dispose();
        expect(backend.supportsMultiTurnChat, isFalse);
      },
    );
  }

  for (final output in ['<think>plan</think>answer', '<think>plan</think>']) {
    test(
      'text session replays visible assistant content after $output',
      () async {
        final prefaces = <Object?>[];
        _installFakeEngine(
          textHistory: true,
          chunks: [_messageChunk(output)],
          onCreateConversation: (config) => prefaces.add(
            config.getProperty<JSAny?>('preface'.toJS)?.dartify(),
          ),
        );
        final engine = LlamaEngine(spi.LlamaBackend.withTextHistory());
        addTearDown(engine.dispose);
        await engine.loadModelFromUrl('model.litertlm');
        final session = api.ChatSession(engine);
        await session.send('first');
        final assistant = session.history.last;
        expect(
          assistant.parts.whereType<LlamaThinkingContent>().single.thinking,
          'plan',
        );
        await session.send('next');
        expect(prefaces, [
          null,
          {
            'messages': [
              {'role': 'user', 'content': 'first'},
              {
                'role': 'assistant',
                'content': output.endsWith('answer') ? 'answer' : '',
              },
            ],
          },
        ]);
        expect(
          assistant.parts.whereType<LlamaThinkingContent>().single.thinking,
          'plan',
        );
      },
    );
  }

  test(
    'large hidden assistant reasoning is omitted from budgeting and replay',
    () async {
      final prefaces = <Object?>[];
      _installFakeEngine(
        textHistory: true,
        chunks: [_messageChunk('ok')],
        onCreateConversation: (config) =>
            prefaces.add(config.getProperty<JSAny?>('preface'.toJS)?.dartify()),
      );
      final engine = LlamaEngine(spi.LlamaBackend.withTextHistory());
      addTearDown(engine.dispose);
      await engine.loadModelFromUrl(
        'model.litertlm',
        modelParams: const ModelParams(contextSize: 128),
      );
      final hidden = 'PRIVATE PLAN ' * 1000;
      final assistant = LlamaChatMessage.withContent(
        role: LlamaChatRole.assistant,
        content: [LlamaThinkingContent(hidden), const LlamaTextContent('ack')],
      );
      final session = api.ChatSession(engine);
      session.addMessage(
        const LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'PINE'),
      );
      session.addMessage(assistant);
      final accounting = await engine.chatTemplate(session.history);
      expect(accounting.prompt, isNot(contains('PRIVATE')));
      expect(accounting.prompt, isNot(contains('reasoning_content')));
      await session.send('hi', params: const GenerationParams(maxTokens: 1));
      expect(session.lastRequestFitContext, isTrue);
      expect(prefaces, [
        {
          'messages': [
            {'role': 'user', 'content': 'PINE'},
            {'role': 'assistant', 'content': 'ack'},
          ],
        },
      ]);
      expect(
        assistant.parts.whereType<LlamaThinkingContent>().single.thinking,
        hidden,
      );
    },
  );

  test(
    'default session budget trims completed history before JS forwarding',
    () async {
      final prefaces = <Object?>[];
      _installFakeEngine(
        textHistory: true,
        chunks: [_messageChunk('ok')],
        onCreateConversation: (config) =>
            prefaces.add(config.getProperty<JSAny?>('preface'.toJS)?.dartify()),
      );
      final engine = LlamaEngine(spi.LlamaBackend.withTextHistory());
      addTearDown(engine.dispose);
      await engine.loadModelFromUrl(
        'model.litertlm',
        modelParams: const ModelParams(contextSize: 128),
      );
      final session = api.ChatSession(engine);
      session.addMessage(
        LlamaChatMessage.fromText(
          role: LlamaChatRole.user,
          text: 'PINE ' * 1000,
        ),
      );
      session.addMessage(
        const LlamaChatMessage.fromText(
          role: LlamaChatRole.assistant,
          text: 'ack',
        ),
      );
      await session.send('hi', params: const GenerationParams(maxTokens: 1));
      expect(session.lastRequestFitContext, isTrue);
      expect(prefaces, [
        null,
      ], reason: 'The completed oversized turn must be trimmed, not sent.');
      expect(session.history.map((message) => message.content), ['hi', 'ok']);
    },
  );

  test(
    'default session budget reports an oversized system prompt as not fitting',
    () async {
      final prefaces = <Object?>[];
      _installFakeEngine(
        textHistory: true,
        chunks: [_messageChunk('ok')],
        onCreateConversation: (config) =>
            prefaces.add(config.getProperty<JSAny?>('preface'.toJS)?.dartify()),
      );
      final engine = LlamaEngine(spi.LlamaBackend.withTextHistory());
      addTearDown(engine.dispose);
      await engine.loadModelFromUrl(
        'model.litertlm',
        modelParams: const ModelParams(contextSize: 128),
      );
      final system = 'ORCHID ' * 1000;
      final session = api.ChatSession(engine, systemPrompt: system);
      await session.send('hi', params: const GenerationParams(maxTokens: 1));
      expect(session.lastRequestFitContext, isFalse);
      expect(prefaces, [
        {
          'messages': [
            {'role': 'system', 'content': system},
          ],
        },
      ]);
    },
  );

  test(
    'full transcript accounting never replaces structured JS messages',
    () async {
      JSObject? config;
      String? sent;
      _installFakeEngine(
        textHistory: true,
        chunks: [_messageChunk('ok')],
        onCreateConversation: (value) => config = value,
        onPrompt: (value) => sent = value,
      );
      final engine = LlamaEngine(LiteRtLmBackend.withTextHistory());
      addTearDown(engine.dispose);
      await engine.loadModelFromUrl('model.litertlm');
      const messages = [
        LlamaChatMessage.fromText(
          role: LlamaChatRole.system,
          text: 'Be terse.',
        ),
        LlamaChatMessage.fromText(
          role: LlamaChatRole.user,
          text: 'Remember PINE.',
        ),
        LlamaChatMessage.fromText(role: LlamaChatRole.assistant, text: 'ack'),
        LlamaChatMessage.fromText(
          role: LlamaChatRole.user,
          text: 'Which word?',
        ),
      ];
      final accounting = await engine.chatTemplate(messages);
      expect(
        accounting.tokenCount,
        isNull,
        reason: 'No exact JS tokenizer is exposed.',
      );
      final serialized = jsonDecode(accounting.prompt) as List;
      expect(serialized.map((message) => (message as Map)['role']), [
        'system',
        'user',
        'assistant',
        'user',
      ]);
      expect(serialized.map((message) => (message as Map)['content']), [
        'Be terse.',
        'Remember PINE.',
        'ack',
        'Which word?',
      ]);
      await engine.create(messages).toList();
      expect(sent, 'Which word?');
      expect(config!.getProperty<JSObject>('preface'.toJS).dartify(), {
        'messages': [
          {'role': 'system', 'content': 'Be terse.'},
          {'role': 'user', 'content': 'Remember PINE.'},
          {'role': 'assistant', 'content': 'ack'},
        ],
      });
    },
  );

  test(
    'opt-in Web router forwards session history and isolates reset/other sessions',
    () async {
      final prefaces = <Object?>[];
      final prompts = <String>[];
      _installFakeEngine(
        textHistory: true,
        chunks: [_messageChunk('ack')],
        onPrompt: prompts.add,
        onCreateConversation: (config) =>
            prefaces.add(config.getProperty<JSAny?>('preface'.toJS)?.dartify()),
      );
      final engine = LlamaEngine(spi.LlamaBackend.withTextHistory());
      addTearDown(engine.dispose);
      await engine.loadModelFromUrl('model.litertlm');
      expect((await engine.capabilities).supportsMultiTurnChat, isTrue);
      final session = api.ChatSession(
        engine,
        maxContextTokens: 0,
        systemPrompt: 'Be terse.',
      );
      await session.send('Remember PINE.');
      await session.send('Which word?');
      expect(prefaces, [
        {
          'messages': [
            {'role': 'system', 'content': 'Be terse.'},
          ],
        },
        {
          'messages': [
            {'role': 'system', 'content': 'Be terse.'},
            {'role': 'user', 'content': 'Remember PINE.'},
            {'role': 'assistant', 'content': 'ack'},
          ],
        },
      ]);
      session.reset(keepSystemPrompt: false);
      await session.send('fresh');
      final other = api.ChatSession(engine, maxContextTokens: 0);
      await other.send('other');
      expect(prefaces.skip(2), [null, null]);
      expect(prompts, ['Remember PINE.', 'Which word?', 'fresh', 'other']);
    },
  );

  test(
    'structured text rejects unsupported roles/options before inference and recovers',
    () async {
      var prompts = 0;
      _installFakeEngine(
        textHistory: true,
        chunks: [_messageChunk('ok')],
        onPrompt: (_) => prompts++,
      );
      final engine = LlamaEngine(spi.LlamaBackend.withTextHistory());
      addTearDown(engine.dispose);
      await engine.loadModelFromUrl('model.litertlm');
      const user = LlamaChatMessage.fromText(
        role: LlamaChatRole.user,
        text: 'hi',
      );
      for (final role in [
        LlamaChatRole.tool,
        LlamaChatRole.system,
        LlamaChatRole.assistant,
      ]) {
        await expectLater(
          engine.create([
            LlamaChatMessage.fromText(role: role, text: 'x'),
          ]).toList(),
          throwsA(isA<LlamaUnsupportedException>()),
        );
      }
      await expectLater(
        engine.create(const [user], enableThinking: false).toList(),
        throwsA(isA<LlamaUnsupportedException>()),
      );
      await expectLater(
        engine
            .create(const [user], chatTemplateKwargs: const {'ignored': true})
            .toList(),
        throwsA(isA<LlamaUnsupportedException>()),
      );
      await expectLater(
        engine.create(const [user], parallelToolCalls: true).toList(),
        throwsA(isA<LlamaUnsupportedException>()),
      );
      await expectLater(
        engine.create(const [
          user,
        ], toolChoice: api.ToolChoice.required).toList(),
        throwsA(isA<LlamaUnsupportedException>()),
      );
      await expectLater(
        engine
            .create(
              const [user],
              tools: [
                api.ToolDefinition(
                  name: 'tool',
                  description: 'test',
                  parameters: const [],
                ),
              ],
            )
            .toList(),
        throwsA(isA<LlamaUnsupportedException>()),
      );
      await expectLater(
        engine.create([
          LlamaChatMessage.withContent(
            role: LlamaChatRole.user,
            content: [LlamaThinkingContent('private')],
          ),
        ]).toList(),
        throwsA(isA<LlamaUnsupportedException>()),
      );
      expect(prompts, 0);
      expect(
        (await engine.create(const [user]).toList()).map((c) => c.text).join(),
        'ok',
      );
      expect(prompts, 1);
    },
  );

  test(
    'unknown legacy roles are typed errors before template rendering',
    () async {
      var prompts = 0;
      _installFakeEngine(
        textHistory: true,
        chunks: [_messageChunk('ok')],
        onPrompt: (_) => prompts++,
      );
      final engine = LlamaEngine(spi.LlamaBackend.withTextHistory());
      addTearDown(engine.dispose);
      await engine.loadModelFromUrl('model.litertlm');
      await expectLater(
        engine.create(const [
          LlamaChatMessage(role: 'developer', content: 'unsupported'),
          LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'hi'),
        ]).toList(),
        throwsA(isA<LlamaUnsupportedException>()),
      );
      expect(prompts, 0);
    },
  );

  test('cancellation/reset does not seed another public session', () async {
    final fake = _installQueueFakeEngine(textHistory: true);
    final engine = LlamaEngine(spi.LlamaBackend.withTextHistory());
    addTearDown(() async {
      fake.finishAll();
      await engine.dispose();
    });
    await engine.loadModelFromUrl('model.litertlm');
    final old = api.ChatSession(
      engine,
      maxContextTokens: 0,
      systemPrompt: 'OLD SECRET',
    );
    final done = Completer<void>();
    Object? cancelledError;
    final subscription = old
        .create(const [LlamaTextContent('old')])
        .listen(
          (_) {},
          onDone: done.complete,
          onError: (Object error) => cancelledError = error,
        );
    await (await fake.started(0)).holding;
    old.reset(keepSystemPrompt: false);
    engine.cancelGeneration();
    (await fake.started(0)).finish();
    await done.future.timeout(const Duration(seconds: 2));
    await subscription.cancel();
    expect(
      cancelledError,
      anyOf(
        isNull,
        isA<LlamaStateException>().having(
          (error) => error.message,
          'early cancel',
          'Generation was cancelled before any output.',
        ),
      ),
    );
    final other = api.ChatSession(engine, maxContextTokens: 0);
    final request = other.send('fresh');
    (await fake.started(1)).finish();
    expect((await request).text, 'fresh;');
    expect(old.history, isEmpty);
    expect(fake.prefaces, [
      {
        'messages': [
          {'role': 'system', 'content': 'OLD SECRET'},
        ],
      },
      null,
    ]);
  });

  for (final decoration in ['', '  \n', 'suffix']) {
    test(
      'rejects canonical Qwen3 override before Web runtime creation: $decoration',
      () async {
        var creates = 0;
        _installFakeEngine(
          chunks: <JSAny?>[_messageChunk('hidden thinking')],
          onCreate: (_) => creates++,
        );
        final backend = LiteRtLmBackend();
        try {
          await expectLater(
            backend.modelLoadFromUrlAs(
              'https://example.com/download?id=42',
              ModelParams(
                chatTemplate: decoration == 'suffix'
                    ? '${api.liteRtLmQwen3ChatTemplate}\n{# customization #}'
                    : '$decoration${api.liteRtLmQwen3ChatTemplate}',
              ),
              ModelFormat.liteRtLm,
            ),
            throwsA(
              isA<LlamaUnsupportedException>().having(
                (error) => error.message,
                'message',
                allOf(
                  contains('Qwen3'),
                  contains('@litert-lm/core@0.18.0'),
                  contains('native'),
                ),
              ),
            ),
          );
          expect(creates, 0);
        } finally {
          await backend.dispose();
        }
      },
    );
  }

  test('rejects automatic tool loops before Web generation while '
      'manual completion remains usable', () async {
    var prompts = 0;
    var callbacks = 0;
    var toolRuns = 0;
    _installFakeEngine(
      onPrompt: (_) => prompts++,
      chunks: <JSAny?>[_messageChunk('Hello')],
    );
    final engine = LlamaEngine(LiteRtLmBackend());
    final session = api.ChatSession(engine, maxContextTokens: 0);
    final previous = api.LlamaChatMessage.fromText(
      role: api.LlamaChatRole.user,
      text: 'Existing turn',
    );
    session.addMessage(previous);
    final tools = [
      api.ToolDefinition(
        name: 'weather',
        description: 'Weather',
        parameters: const [],
        handler: (_) async {
          toolRuns++;
          return 'sunny';
        },
      ),
    ];
    try {
      await engine.loadModelFromUrl('https://example.com/model.litertlm');
      for (final resume in [false, true]) {
        await expectLater(
          session.completeWithTools(
            resume ? const [] : const [api.LlamaTextContent('New turn')],
            tools: tools,
            params: const api.GenerationParams(maxTokens: 1),
            onMessageAdded: (_) => callbacks++,
          ),
          throwsA(
            isA<api.LlamaUnsupportedException>().having(
              (error) => error.message,
              'diagnostic',
              contains('@0.18.0'),
            ),
          ),
        );
        expect(session.history, [same(previous)]);
      }
      await expectLater(
        session.sendWithTools('No tools', tools: const []),
        throwsA(isA<api.LlamaUnsupportedException>()),
      );
      expect(prompts, 0);
      expect(callbacks, 0);
      expect(toolRuns, 0);
      expect(session.history, [same(previous)]);

      final chunks = await engine.create(const [
        api.LlamaChatMessage.fromText(role: api.LlamaChatRole.user, text: 'hi'),
      ], params: const api.GenerationParams(maxTokens: 1)).toList();
      expect(chunks.map((chunk) => chunk.text).join(), 'Hello');
      expect(chunks.last.choices.single.finishReason, 'stop');
      expect(prompts, 1);
    } finally {
      await engine.dispose();
    }
  });

  test('reports the LiteRT-LM runtime', () {
    expect(LiteRtLmBackend().runtime, LlamaRuntime.liteRtLm);
  });

  test('loads .litertlm URL through preloaded LiteRT-LM Engine', () async {
    JSObject? lastEngineSettings;
    JSObject? lastConversationConfig;
    String? lastPrompt;
    var progress = <double>[];

    _installFakeEngine(
      onCreate: (settings) {
        lastEngineSettings = settings;
      },
      onCreateConversation: (config) {
        lastConversationConfig = config;
      },
      onPrompt: (prompt) {
        lastPrompt = prompt;
      },
      chunks: <JSAny?>[_messageChunk('Hello'), _messageChunk(' world')],
    );

    final backend = LiteRtLmBackend();
    final modelParams = ModelParams(
      contextSize: 2048,
      preferredBackend: GpuBackend.vulkan,
    );
    final modelHandle = await backend.modelLoadFromUrl(
      'https://example.com/gemma-4-E2B-it-web.litertlm?download=1',
      modelParams,
      onProgress: progress.add,
    );
    final contextHandle = await backend.contextCreate(modelHandle, modelParams);

    final settings = lastEngineSettings!;
    expect(
      (settings.getProperty('model'.toJS) as JSString).toDart,
      'https://example.com/gemma-4-E2B-it-web.litertlm?download=1',
    );
    expect((settings.getProperty('backend'.toJS) as JSNumber).toDartInt, 2);
    final executor =
        settings.getProperty('mainExecutorSettings'.toJS) as JSObject;
    expect(
      (executor.getProperty('maxNumTokens'.toJS) as JSNumber).toDartInt,
      2048,
    );
    expect(progress, <double>[0, 1]);
    expect(await backend.getBackendName(), 'LiteRT-LM web gpu');

    final output = await backend
        .generate(
          contextHandle,
          'Say hi',
          const GenerationParams(
            maxTokens: 8,
            temp: 0.2,
            topK: 7,
            topP: 0.5,
            seed: 42,
          ),
        )
        .expand((bytes) => bytes)
        .toList();

    expect(utf8.decode(output), 'Hello world');
    expect(lastPrompt, 'Say hi');

    final conversationConfig = lastConversationConfig!;
    final sessionConfig =
        conversationConfig.getProperty('sessionConfig'.toJS) as JSObject;
    expect(
      (sessionConfig.getProperty('maxOutputTokens'.toJS) as JSNumber).toDartInt,
      8,
    );
    expect(
      (sessionConfig.getProperty('samplerBackend'.toJS) as JSNumber).toDartInt,
      2,
    );
    final sampler = sessionConfig.getProperty('samplerParams'.toJS) as JSObject;
    expect((sampler.getProperty('k'.toJS) as JSNumber).toDartInt, 7);
    expect((sampler.getProperty('p'.toJS) as JSNumber).toDartDouble, 0.5);
    expect(
      (sampler.getProperty('temperature'.toJS) as JSNumber).toDartDouble,
      0.2,
    );
    expect((sampler.getProperty('seed'.toJS) as JSNumber).toDartInt, 42);
  });

  test('loads an extensionless URL only when declared LiteRT-LM', () async {
    const url = 'https://example.com/download?id=42';
    JSObject? lastEngineSettings;
    _installFakeEngine(
      onCreate: (settings) {
        lastEngineSettings = settings;
      },
      chunks: const <JSAny?>[],
    );
    final backend = LiteRtLmBackend();

    try {
      await expectLater(
        backend.modelLoadFromUrl(url, const ModelParams()),
        throwsArgumentError,
      );
      await expectLater(
        backend.modelLoadFromUrlAs(url, const ModelParams(), ModelFormat.gguf),
        throwsA(isA<LlamaUnsupportedException>()),
      );
      expect(lastEngineSettings, isNull);

      await backend.modelLoadFromUrlAs(
        url,
        const ModelParams(),
        ModelFormat.liteRtLm,
      );
      expect(
        (lastEngineSettings!.getProperty('model'.toJS) as JSString).toDart,
        url,
      );
    } finally {
      await backend.dispose();
    }
  });

  test('sends greedy top-k 1 to the JS sampler at temperature 0', () async {
    JSObject? lastConversationConfig;
    _installFakeEngine(
      onCreateConversation: (config) {
        lastConversationConfig = config;
      },
      chunks: <JSAny?>[_messageChunk('ok')],
    );

    final backend = LiteRtLmBackend();
    try {
      final modelHandle = await backend.modelLoadFromUrl(
        'https://example.com/model.litertlm',
        const ModelParams(),
      );
      final contextHandle = await backend.contextCreate(
        modelHandle,
        const ModelParams(),
      );
      await backend
          .generate(
            contextHandle,
            'Say ok',
            const GenerationParams(maxTokens: 8, temp: 0, topK: 40, topP: 0.9),
          )
          .toList();

      final sessionConfig =
          lastConversationConfig!.getProperty('sessionConfig'.toJS) as JSObject;
      final sampler =
          sessionConfig.getProperty('samplerParams'.toJS) as JSObject;
      expect((sampler.getProperty('k'.toJS) as JSNumber).toDartInt, 1);
      expect(
        (sampler.getProperty('temperature'.toJS) as JSNumber).toDartDouble,
        0,
      );
      expect((sampler.getProperty('p'.toJS) as JSNumber).toDartDouble, 0.9);
    } finally {
      await backend.dispose();
    }
  });

  test('loads cached .litertlm URL through CacheStorage Blob', () async {
    const cacheName = 'llamadart-webgpu-model-cache-v1';
    const modelUrl = 'https://example.com/gemma-web.litertlm?download=true';
    final cache = await window.caches.open(cacheName).toDart;
    await cache.put(modelUrl.toJS, Response('cached litert'.toJS)).toDart;
    addTearDown(() async {
      await window.caches.delete(cacheName).toDart;
    });

    JSAny? lastModelSetting;
    _installFakeEngine(
      onCreate: (settings) {
        lastModelSetting = settings.getProperty('model'.toJS);
      },
      chunks: <JSAny?>[_messageChunk('ok')],
    );

    final backend = LiteRtLmBackend();
    final modelHandle = await backend.modelLoadFromUrl(
      modelUrl,
      const ModelParams(),
    );

    expect(lastModelSetting, isNotNull);
    expect(lastModelSetting!.isA<Blob>(), isTrue);
    expect(
      await backend.modelMetadata(modelHandle),
      containsPair('llamadart.litert_lm_web.model_source', 'cache'),
    );
    expect(
      await backend.modelMetadata(modelHandle),
      containsPair('llamadart.litert_lm_web.model_cache_state', 'hit'),
    );
  });

  test('does not use cached Blob for credential-like .litertlm URLs', () async {
    const cacheName = 'llamadart-webgpu-model-cache-v1';
    const modelUrl = 'https://example.com/gemma-web.litertlm?token=secret';
    final cache = await window.caches.open(cacheName).toDart;
    await cache.put(modelUrl.toJS, Response('cached litert'.toJS)).toDart;
    addTearDown(() async {
      await window.caches.delete(cacheName).toDart;
    });

    JSAny? lastModelSetting;
    _installFakeEngine(
      onCreate: (settings) {
        lastModelSetting = settings.getProperty('model'.toJS);
      },
      chunks: <JSAny?>[_messageChunk('ok')],
    );

    final backend = LiteRtLmBackend();
    final modelHandle = await backend.modelLoadFromUrl(
      modelUrl,
      const ModelParams(),
    );

    expect(lastModelSetting, isA<JSString>());
    expect((lastModelSetting as JSString).toDart, modelUrl);
    expect(
      await backend.modelMetadata(modelHandle),
      containsPair('llamadart.litert_lm_web.model_source', 'network'),
    );
    expect(
      await backend.modelMetadata(modelHandle),
      containsPair('llamadart.litert_lm_web.model_cache_state', 'miss'),
    );
  });

  test('setLogLevel updates LiteRT-LM web console log level', () async {
    final backend = LiteRtLmBackend();

    await backend.setLogLevel(LlamaLogLevel.error);

    final raw = globalContext.getProperty<JSAny?>(
      '__llamadartLiteRtLmLogLevel'.toJS,
    );
    expect(raw, isA<JSNumber>());
    expect((raw as JSNumber).toDartInt, LlamaLogLevel.error.index);
  });

  test('names a model URL holding a lone or escaped % once decoded', () async {
    for (final (url, name) in const [
      ('https://example.com/m/qwen%20100%25.litertlm', 'qwen 100%.litertlm'),
      ('https://example.com/m/qwen 100%.litertlm', 'qwen 100%.litertlm'),
      ('https://example.com/m%C3.litertlm', null),
      ('https://example.com/m%3Ftoken%3DMetadataSecret.litertlm', null),
      ('https://example.com/m%2FMetadataSecret.litertlm', null),
    ]) {
      _installFakeEngine(chunks: <JSAny?>[_messageChunk('ok')]);
      final backend = LiteRtLmBackend();
      final modelHandle = await backend.modelLoadFromUrl(
        url,
        const ModelParams(),
      );

      final metadata = await backend.modelMetadata(modelHandle);
      await backend.dispose();

      expect(metadata['general.name'], name, reason: url);
    }
  });

  test(
    'shows a model URL without resolving it or keeping credentials',
    () async {
      for (final (url, name, display) in const [
        (
          'https://alice:Pw7secret@example.com/m/Pw7secret.litertlm',
          null,
          'https://',
        ),
        (
          'https://Pw7secret@example.com/m/Pw7secret.litertlm',
          null,
          'https://',
        ),
        (
          'https:alice:Pw7secret@example.com/m/Pw7secret.litertlm',
          null,
          'https://',
        ),
        (
          'https://alice:Pw7secret@example.com/m/model.litertlm',
          'model.litertlm',
          'https://example.com/m/model.litertlm',
        ),
        (
          'models/model.litertlm?sig=Sig7secret',
          'model.litertlm',
          'models/model.litertlm',
        ),
        (
          'blob:https://alice:Pw7secret@example.com/0f3c.litertlm',
          '0f3c.litertlm',
          'blob:',
        ),
        ('foo:alice:Pw7secret@example.com/m.litertlm', 'm.litertlm', 'foo:'),
        ('https://user:p%40ss@example.com/m/p@ss.litertlm', null, 'https://'),
        ('//user:Pw7secret@example.com/m/Pw7secret.litertlm', null, '//'),
      ]) {
        _installFakeEngine(chunks: <JSAny?>[_messageChunk('ok')]);
        final backend = LiteRtLmBackend();
        final modelHandle = await backend.modelLoadFromUrl(
          url,
          const ModelParams(),
        );

        final metadata = await backend.modelMetadata(modelHandle);
        await backend.dispose();

        expect(metadata['general.name'], name, reason: url);
        expect(metadata['litert_lm.model_url'], display, reason: url);
      }
    },
  );

  test(
    'exposes single-turn latest-message template for JS conversation runtime',
    () async {
      _installFakeEngine(chunks: <JSAny?>[_messageChunk('ok')]);

      final backend = LiteRtLmBackend();
      final modelHandle = await backend.modelLoadFromUrl(
        'https://example.com/model.litertlm',
        const ModelParams(),
      );

      final metadata = await backend.modelMetadata(modelHandle);
      expect(metadata, containsPair('general.architecture', 'litert-lm'));
      expect(metadata, containsPair('general.file_type', 'litertlm'));
      expect(
        metadata,
        containsPair('llamadart.litert_lm_web.chat_scope', 'single-turn-text'),
      );
      expect(
        metadata,
        containsPair('llamadart.litert_lm_web.structured_chat', 'false'),
      );
      expect(metadata, containsPair('general.name', 'model.litertlm'));
      expect(metadata, containsPair('llm.context_length', '4096'));
      expect(
        metadata,
        containsPair(
          'litert_lm.model_url',
          'https://example.com/model.litertlm',
        ),
      );
      final rendered = ChatTemplateEngine.render(
        templateSource: metadata['tokenizer.chat_template'],
        messages: const [
          LlamaChatMessage.fromText(
            role: LlamaChatRole.system,
            text: 'Be terse.',
          ),
          LlamaChatMessage.fromText(
            role: LlamaChatRole.user,
            text: 'Ignore this older turn.',
          ),
          LlamaChatMessage.fromText(
            role: LlamaChatRole.assistant,
            text: 'Older answer.',
          ),
          LlamaChatMessage.fromText(
            role: LlamaChatRole.user,
            text: 'What is 2+2?',
          ),
        ],
        metadata: metadata,
        addAssistant: true,
      );

      expect(rendered.prompt, 'What is 2+2?');
    },
  );

  for (final url in const [
    'https://alice:Pw7secret@example.com/models/model.litertlm'
        '?X-Amz-Signature=Sig7secret#Fr7secret',
    'https:alice:Pw7secret@example.com/models/model.litertlm',
  ]) {
    test('keeps $url secrets out of metadata and chunks', () async {
      _installFakeEngine(chunks: <JSAny?>[_messageChunk('ok')]);
      final engine = LlamaEngine(LiteRtLmBackend());
      try {
        await engine.loadModelFromUrl(url);
        final chunks = await engine.create(const [
          LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'hi'),
        ]).toList();
        final metadata = await engine.getMetadata();

        expect(
          metadata,
          containsPair(
            'litert_lm.model_url',
            'https://example.com/models/model.litertlm',
          ),
        );
        expect(
          metadata.values.join('\n'),
          allOf(
            isNot(contains('alice')),
            isNot(contains('Pw7secret')),
            isNot(contains('Sig7secret')),
            isNot(contains('Fr7secret')),
          ),
        );
        expect(chunks.map((chunk) => chunk.model).toSet(), {'model.litertlm'});
      } finally {
        await engine.dispose();
      }
    });
  }

  test(
    'forwards ordered text history through JS preface without replay',
    () async {
      String? lastPrompt;
      JSObject? config;
      _installFakeEngine(
        textHistory: true,
        onCreateConversation: (value) => config = value,
        chunks: <JSAny?>[_messageChunk('4')],
        onPrompt: (prompt) {
          lastPrompt = prompt;
        },
      );

      final engine = LlamaEngine(LiteRtLmBackend.withTextHistory());
      await engine.loadModelFromUrl(
        'https://example.com/gemma-4-E2B-it-web.litertlm',
        modelParams: const ModelParams(
          contextSize: 1024,
          preferredBackend: GpuBackend.vulkan,
        ),
      );

      final chunks = await engine.create(
        const [
          LlamaChatMessage.fromText(
            role: LlamaChatRole.system,
            text: 'Answer as JSON.',
          ),
          LlamaChatMessage.fromText(
            role: LlamaChatRole.user,
            text: 'Remember PINE.',
          ),
          LlamaChatMessage.fromText(
            role: LlamaChatRole.assistant,
            text: 'Older assistant turn.',
          ),
          LlamaChatMessage.fromText(
            role: LlamaChatRole.user,
            text: 'What is 2+2?',
          ),
        ],
        params: const GenerationParams(maxTokens: 8, temp: 0, topK: 1, topP: 1),
      ).toList();
      final text = chunks
          .map((chunk) => chunk.choices.first.delta.content ?? '')
          .join();

      expect(text, '4');
      expect(lastPrompt, 'What is 2+2?');
      expect(config!.getProperty<JSObject>('preface'.toJS).dartify(), {
        'messages': [
          {'role': 'system', 'content': 'Answer as JSON.'},
          {'role': 'user', 'content': 'Remember PINE.'},
          {'role': 'assistant', 'content': 'Older assistant turn.'},
        ],
      });
      expect((await engine.capabilities).supportsMultiTurnChat, isTrue);
      await engine.dispose();
    },
  );

  test('invalidates stale model and context handles after reload', () async {
    _installFakeEngine(chunks: <JSAny?>[_messageChunk('ok')]);

    final backend = LiteRtLmBackend();
    try {
      final firstModelHandle = await backend.modelLoadFromUrl(
        'https://example.com/first.litertlm',
        const ModelParams(),
      );
      final firstContextHandle = await backend.contextCreate(
        firstModelHandle,
        const ModelParams(),
      );

      final secondModelHandle = await backend.modelLoadFromUrl(
        'https://example.com/second.litertlm',
        const ModelParams(contextSize: 1024),
      );
      final secondContextHandle = await backend.contextCreate(
        secondModelHandle,
        const ModelParams(contextSize: 1024),
      );

      expect(secondModelHandle, isNot(firstModelHandle));
      expect(secondContextHandle, isNot(firstContextHandle));
      await expectLater(
        backend.modelMetadata(firstModelHandle),
        throwsStateError,
      );
      await expectLater(
        backend.getContextSize(firstContextHandle),
        throwsStateError,
      );
      await expectLater(
        backend.contextFree(firstContextHandle),
        throwsStateError,
      );
      await expectLater(backend.modelFree(firstModelHandle), throwsStateError);
      expect(
        await backend.modelMetadata(secondModelHandle),
        containsPair('general.name', 'second.litertlm'),
      );
      expect(await backend.getContextSize(secondContextHandle), 1024);
    } finally {
      await backend.dispose();
    }
  });

  test('rejects speculative decoding on LiteRT-LM web', () async {
    _installFakeEngine(chunks: <JSAny?>[]);

    final backend = LiteRtLmBackend();
    try {
      final modelHandle = await backend.modelLoadFromUrl(
        'https://example.com/model.litertlm',
        const ModelParams(),
      );
      final contextHandle = await backend.contextCreate(
        modelHandle,
        const ModelParams(),
      );

      await expectLater(
        backend.generate(
          contextHandle,
          'hello',
          const GenerationParams(speculativeDecoding: true),
        ),
        emitsError(
          isA<UnsupportedError>().having(
            (error) => error.message.toString(),
            'message',
            contains('speculativeDecoding'),
          ),
        ),
      );
    } finally {
      await backend.dispose();
    }
  });

  test('rejects presence penalty on LiteRT-LM web', () async {
    _installFakeEngine(chunks: <JSAny?>[]);

    final backend = LiteRtLmBackend();
    try {
      final modelHandle = await backend.modelLoadFromUrl(
        'https://example.com/model.litertlm',
        const ModelParams(),
      );
      final contextHandle = await backend.contextCreate(
        modelHandle,
        const ModelParams(),
      );

      await expectLater(
        backend.generate(
          contextHandle,
          'hello',
          const GenerationParams(presencePenalty: 1.5),
        ),
        emitsError(
          isA<UnsupportedError>().having(
            (error) => error.message.toString(),
            'message',
            contains('presencePenalty'),
          ),
        ),
      );
    } finally {
      await backend.dispose();
    }
  });

  for (final option in [
    'streamBatchTokenThreshold',
    'streamBatchByteThreshold',
  ]) {
    test('public engine rejects LiteRT Web $option and recovers', () async {
      var prompts = 0;
      _installFakeEngine(
        onPrompt: (_) {
          prompts++;
        },
        chunks: <JSAny?>[_messageChunk('Hello')],
      );
      final engine = LlamaEngine(LiteRtLmBackend());
      try {
        await engine.loadModel('https://example.com/model.litertlm');
        final params = const GenerationParams().copyWith(
          streamBatchTokenThreshold: option == 'streamBatchTokenThreshold'
              ? 1
              : null,
          streamBatchByteThreshold: option == 'streamBatchByteThreshold'
              ? 1
              : null,
        );
        await expectLater(
          engine.generate('hello', params: params),
          emitsError(
            isA<LlamaUnsupportedException>().having(
              (error) => error.toString(),
              'named option',
              contains(option),
            ),
          ),
        );
        expect(prompts, 0, reason: 'Rejection must precede model execution');
        expect(await engine.generate('hello').join(), 'Hello');
        expect(prompts, 1);
      } finally {
        await engine.dispose();
      }
    });
  }

  test('reports and rejects the options it does not apply', () async {
    var prompts = 0;
    _installFakeEngine(
      onPrompt: (_) {
        prompts++;
      },
      chunks: <JSAny?>[_messageChunk('Hello')],
    );
    final engine = LlamaEngine(LiteRtLmBackend());
    try {
      await engine.loadModel('https://example.com/model.litertlm');

      final capabilities = await engine.capabilities;
      expect(engine.runtime, LlamaRuntime.liteRtLm);
      expect(capabilities.runtime, LlamaRuntime.liteRtLm);
      expect(capabilities.backendName, startsWith('LiteRT-LM web'));
      expect(capabilities.supportsMultiTurnChat, isFalse);
      expect(capabilities.supportsToolCalling, isFalse);
      expect(capabilities.supportsVision, isFalse);
      expect(capabilities.supportsAudio, isFalse);
      expect(capabilities.supportsEmbeddings, isFalse);
      expect(capabilities.supportsStructuredOutput, isFalse);
      expect(capabilities.supportsGrammar, isFalse);
      expect(capabilities.supportsLazyGrammar, isFalse);
      expect(capabilities.supportsPenalty, isFalse);
      expect(capabilities.supportsPresencePenalty, isFalse);
      expect(capabilities.supportsMinP, isFalse);
      expect(capabilities.supportsThinkingBudget, isFalse);
      expect(capabilities.supportsStreamBatching, isFalse);
      expect(capabilities.speculativeDecodingStrategies, isEmpty);
      for (final (option, params) in [
        ('penalty', const GenerationParams(penalty: 1.3)),
        ('presencePenalty', const GenerationParams(presencePenalty: 0.5)),
        ('grammar', const GenerationParams(grammar: 'root ::= "a"')),
        (
          'speculativeDecoding',
          const GenerationParams(speculativeDecoding: true),
        ),
        (
          'streamBatchTokenThreshold',
          const GenerationParams(streamBatchTokenThreshold: 1),
        ),
        ('minP', const GenerationParams(minP: 0.1)),
        (
          'thinkingBudget',
          const GenerationParams(thinkingBudget: ThinkingBudget(maxTokens: 8)),
        ),
      ]) {
        await expectLater(
          engine.generate('hello', params: params),
          emitsError(
            isA<LlamaUnsupportedException>().having(
              (error) => error.toString(),
              'named option',
              contains(option),
            ),
          ),
        );
      }
      expect(prompts, 0);
    } finally {
      await engine.dispose();
    }
  });

  test('rejects thinking budget on LiteRT-LM web', () async {
    _installFakeEngine(chunks: <JSAny?>[]);

    final backend = LiteRtLmBackend();
    try {
      final modelHandle = await backend.modelLoadFromUrl(
        'https://example.com/model.litertlm',
        const ModelParams(),
      );
      final contextHandle = await backend.contextCreate(
        modelHandle,
        const ModelParams(),
      );

      await expectLater(
        backend.generate(
          contextHandle,
          'hello',
          const GenerationParams(thinkingBudget: ThinkingBudget(maxTokens: 16)),
        ),
        emitsError(
          isA<UnsupportedError>().having(
            (error) => error.message.toString(),
            'message',
            contains('thinkingBudget'),
          ),
        ),
      );
    } finally {
      await backend.dispose();
    }
  });

  test('rejects video media with actionable fallback guidance', () async {
    _installFakeEngine(chunks: <JSAny?>[]);

    final backend = LiteRtLmBackend();
    try {
      final modelHandle = await backend.modelLoadFromUrl(
        'https://example.com/model.litertlm',
        const ModelParams(),
      );
      final contextHandle = await backend.contextCreate(
        modelHandle,
        const ModelParams(),
      );

      await expectLater(
        backend.generate(
          contextHandle,
          'describe',
          const GenerationParams(),
          parts: [LlamaVideoContent(path: '/tmp/clip.mp4')],
        ),
        emitsError(
          isA<UnsupportedError>().having(
            (error) => error.message.toString(),
            'message',
            contains('image frames'),
          ),
        ),
      );
    } finally {
      await backend.dispose();
    }
  });

  test('rejects speculative decoding config on LiteRT-LM web', () async {
    _installFakeEngine(chunks: <JSAny?>[]);

    final backend = LiteRtLmBackend();
    try {
      final modelHandle = await backend.modelLoadFromUrl(
        'https://example.com/model.litertlm',
        const ModelParams(),
      );
      final contextHandle = await backend.contextCreate(
        modelHandle,
        const ModelParams(),
      );

      for (final config in const [
        SpeculativeDecodingConfig.mtp(),
        SpeculativeDecodingConfig.draftDspark(draftModelPath: 'draft.gguf'),
      ]) {
        await expectLater(
          backend.generate(
            contextHandle,
            'hello',
            GenerationParams(speculativeDecodingConfig: config),
          ),
          emitsError(
            isA<UnsupportedError>().having(
              (error) => error.message.toString(),
              'message',
              contains('speculativeDecodingConfig'),
            ),
          ),
        );
      }
    } finally {
      await backend.dispose();
    }
  });

  test('rejects unsupported context-time model params', () async {
    _installFakeEngine(chunks: <JSAny?>[]);

    final backend = LiteRtLmBackend();
    try {
      final modelHandle = await backend.modelLoadFromUrl(
        'https://example.com/model.litertlm',
        const ModelParams(),
      );

      await expectLater(
        () => backend.contextCreate(
          modelHandle,
          const ModelParams(batchSize: 128),
        ),
        throwsA(
          isA<LlamaUnsupportedException>().having(
            (error) => error.message,
            'message',
            contains('batchSize'),
          ),
        ),
      );

      await expectLater(
        () => backend.contextCreate(
          modelHandle,
          const ModelParams(
            liteRtLmActivationDataType: LiteRtLmActivationDataType.float16,
            liteRtLmPrefillChunkSize: 128,
            liteRtLmParallelFileSectionLoading: false,
            liteRtLmDispatchLibDir: '/vendor/litert',
            liteRtLmCacheDir: '/data/litert-cache',
            liteRtLmMaxProgramCacheBytes: 1024,
          ),
        ),
        throwsA(
          isA<LlamaUnsupportedException>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('native'),
              contains('liteRtLmActivationDataType'),
              contains('liteRtLmPrefillChunkSize'),
              contains('liteRtLmParallelFileSectionLoading'),
              contains('liteRtLmDispatchLibDir'),
              contains('liteRtLmCacheDir'),
              contains('liteRtLmMaxProgramCacheBytes'),
            ),
          ),
        ),
      );

      await expectLater(
        () => backend.contextCreate(
          modelHandle,
          const ModelParams(loadMtp: true, modelBytesHint: 1),
        ),
        throwsA(
          isA<LlamaUnsupportedException>().having(
            (error) => error.message,
            'message',
            contains('ModelParams: loadMtp, modelBytesHint.'),
          ),
        ),
      );

      await expectLater(
        () => backend.contextCreate(
          modelHandle,
          const ModelParams(contextSize: 0),
        ),
        throwsA(
          isA<LlamaUnsupportedException>().having(
            (error) => error.message,
            'message',
            contains('contextSize=0'),
          ),
        ),
      );

      await expectLater(
        () => backend.contextCreate(
          modelHandle,
          const ModelParams(liteRtLmBackend: LiteRtLmBackendPreference.npu),
        ),
        throwsA(
          isA<UnsupportedError>().having(
            (error) => error.message,
            'message',
            contains('NPU backend'),
          ),
        ),
      );
    } finally {
      await backend.dispose();
    }
  });

  test('rejects media content in direct chat-template calls', () async {
    _installFakeEngine(chunks: <JSAny?>[_messageChunk('ok')]);

    final backend = LiteRtLmBackend();
    try {
      final modelHandle = await backend.modelLoadFromUrl(
        'https://example.com/model.litertlm',
        const ModelParams(),
      );

      expect(
        await backend.applyChatTemplate(
          modelHandle,
          const <Map<String, dynamic>>[
            {
              'role': 'user',
              'content': [
                {'type': 'text', 'text': 'hello'},
                {'type': 'text', 'text': ' world'},
              ],
            },
          ],
          addAssistant: false,
        ),
        'hello world',
      );
      await expectLater(
        backend.applyChatTemplate(modelHandle, const <Map<String, dynamic>>[
          {
            'role': 'user',
            'content': [
              {
                'type': 'image_url',
                'image_url': {'url': 'https://example.com/cat.png'},
              },
            ],
          },
        ]),
        throwsUnsupportedError,
      );
    } finally {
      await backend.dispose();
    }
  });

  test(
    'text-history raw generation has typed option and media refusals',
    () async {
      _installFakeEngine(chunks: []);
      final backend = LiteRtLmBackend.withTextHistory();
      addTearDown(backend.dispose);
      final model = await backend.modelLoadFromUrl(
        'model.litertlm',
        const ModelParams(),
      );
      final context = await backend.contextCreate(model, const ModelParams());
      await expectLater(
        backend.generate(context, 'hi', const GenerationParams(minP: 0.1)),
        emitsError(isA<LlamaUnsupportedException>()),
      );
      await expectLater(
        backend.generate(
          context,
          'hi',
          const GenerationParams(),
          parts: [LlamaVideoContent(path: '/tmp/clip.mp4')],
        ),
        emitsError(isA<LlamaUnsupportedException>()),
      );
    },
  );

  test('rejects every load/custom template override explicitly', () async {
    _installFakeEngine(chunks: <JSAny?>[_messageChunk('ok')]);
    final backend = LiteRtLmBackend.withTextHistory();
    addTearDown(backend.dispose);
    for (final template in ['', 'custom {{ messages }}']) {
      await expectLater(
        backend.modelLoadFromUrl(
          'model.litertlm',
          ModelParams(chatTemplate: template),
        ),
        throwsA(isA<LlamaUnsupportedException>()),
      );
    }
    final model = await backend.modelLoadFromUrl(
      'model.litertlm',
      const ModelParams(),
    );
    for (final template in ['', 'custom {{ messages }}']) {
      await expectLater(
        backend.applyChatTemplate(model, const [
          {'role': 'user', 'content': 'hi'},
        ], customTemplate: template),
        throwsA(isA<LlamaUnsupportedException>()),
      );
    }
  });

  test('ignores the load template and an empty custom template, and rejects '
      'a non-empty one', () async {
    _installFakeEngine(chunks: <JSAny?>[_messageChunk('ok')]);

    final backend = LiteRtLmBackend();
    try {
      final modelHandle = await backend.modelLoadFromUrl(
        'https://example.com/model.litertlm',
        const ModelParams(chatTemplate: 'load {{ messages }}'),
      );
      const messages = <Map<String, dynamic>>[
        {'role': 'user', 'content': 'hello'},
      ];

      expect(await backend.applyChatTemplate(modelHandle, messages), 'hello');
      expect(
        await backend.applyChatTemplate(
          modelHandle,
          messages,
          customTemplate: '',
        ),
        'hello',
      );
      await expectLater(
        backend.applyChatTemplate(
          modelHandle,
          messages,
          customTemplate: 'custom {{ messages }}',
        ),
        throwsUnsupportedError,
      );
    } finally {
      await backend.dispose();
    }
  });

  test('reports zero VRAM without requiring web runtime', () async {
    final backend = LiteRtLmBackend(readyTimeout: Duration.zero);

    expect(await backend.getVramInfo(), (total: 0, free: 0));
  });

  test('validates LoRA context handles before unsupported errors', () async {
    _installFakeEngine(chunks: <JSAny?>[_messageChunk('ok')]);

    final backend = LiteRtLmBackend();
    try {
      final modelHandle = await backend.modelLoadFromUrl(
        'https://example.com/model.litertlm',
        const ModelParams(),
      );

      expect(
        () => backend.setLoraAdapter(123, 'adapter.lora', 1),
        throwsStateError,
      );
      final contextHandle = await backend.contextCreate(
        modelHandle,
        const ModelParams(),
      );
      expect(
        () => backend.setLoraAdapter(contextHandle, 'adapter.lora', 1),
        throwsUnsupportedError,
      );
      expect(
        () => backend.removeLoraAdapter(contextHandle, 'adapter.lora'),
        throwsUnsupportedError,
      );
      expect(
        () => backend.clearLoraAdapters(contextHandle),
        throwsUnsupportedError,
      );

      await backend.contextFree(contextHandle);
      expect(() => backend.clearLoraAdapters(contextHandle), throwsStateError);
    } finally {
      await backend.dispose();
    }
  });

  test('rejects unsupported multimodal operations consistently', () async {
    _installFakeEngine(chunks: <JSAny?>[_messageChunk('ok')]);

    final backend = LiteRtLmBackend();
    final modelHandle = await backend.modelLoadFromUrl(
      'https://example.com/model.litertlm',
      const ModelParams(),
    );

    expect(
      () => backend.multimodalContextCreate(modelHandle, 'mmproj.gguf'),
      throwsUnsupportedError,
    );
    expect(() => backend.multimodalContextFree(1), throwsUnsupportedError);
    expect(() => backend.supportsVision(1), throwsUnsupportedError);
    expect(() => backend.supportsAudio(1), throwsUnsupportedError);
  });

  test('loads LiteRT-LM Engine from module URL', () async {
    final moduleUrl =
        'data:text/javascript;charset=utf-8,${Uri.encodeComponent('''
      export const Backend = { CPU: 3, GPU_ARTISAN: 2, GPU: 4 };
      export const Engine = {
        async create(settings) {
          globalThis.__llamadartLiteRtLmModuleSettings = {
            model: settings.model,
            backend: settings.backend,
            maxNumTokens: settings.mainExecutorSettings?.maxNumTokens,
          };
          if (settings.backend !== 2) {
            throw new Error(`Unexpected backend: \${settings.backend}`);
          }
          return {
            async createConversation(config) {
              globalThis.__llamadartLiteRtLmModuleConversationConfig = config;
              return {
                sendMessageStreaming(prompt) {
                  globalThis.__llamadartLiteRtLmModulePrompt = prompt;
                  let sent = false;
                  return new ReadableStream({
                    pull(controller) {
                      if (sent) {
                        controller.close();
                        return;
                      }
                      sent = true;
                      controller.enqueue({
                        content: [{ type: 'text', text: 'Module ok' }],
                      });
                    },
                  });
                },
                cancel() {},
                async delete() {},
              };
            },
            async delete() {},
          };
        },
      };
    ''')}';

    final backend = LiteRtLmBackend(moduleUrl: moduleUrl);
    final modelHandle = await backend.modelLoadFromUrl(
      'https://example.com/module-model.litertlm',
      const ModelParams(contextSize: 1024, preferredBackend: GpuBackend.vulkan),
    );
    final contextHandle = await backend.contextCreate(
      modelHandle,
      const ModelParams(contextSize: 1024, preferredBackend: GpuBackend.vulkan),
    );

    final output = await backend
        .generate(
          contextHandle,
          'Module prompt',
          const GenerationParams(maxTokens: 8),
        )
        .expand((bytes) => bytes)
        .toList();

    expect(utf8.decode(output), 'Module ok');
    final settings =
        globalContext.getProperty('__llamadartLiteRtLmModuleSettings'.toJS)
            as JSObject;
    expect(
      (settings.getProperty('model'.toJS) as JSString).toDart,
      'https://example.com/module-model.litertlm',
    );
    expect((settings.getProperty('backend'.toJS) as JSNumber).toDartInt, 2);
    expect(
      (settings.getProperty('maxNumTokens'.toJS) as JSNumber).toDartInt,
      1024,
    );
    expect(
      (globalContext.getProperty('__llamadartLiteRtLmModulePrompt'.toJS)
              as JSString)
          .toDart,
      'Module prompt',
    );
  });

  test('applies stop sequences and cancels active conversation', () async {
    var cancelCalls = 0;
    var readerCancelCalls = 0;
    _installFakeEngine(
      chunks: <JSAny?>[_messageChunk('Hello ST'), _messageChunk('OP hidden')],
      onCancel: () {
        cancelCalls += 1;
      },
      onReaderCancel: () {
        readerCancelCalls += 1;
      },
    );

    final backend = LiteRtLmBackend();
    const params = ModelParams();
    await backend.modelLoadFromUrl(
      'https://example.com/model.litertlm',
      params,
    );
    await backend.contextCreate(1, params);

    final output = await backend
        .generate(
          1,
          'prompt',
          const GenerationParams(maxTokens: 16, stopSequences: ['STOP']),
        )
        .expand((bytes) => bytes)
        .toList();

    expect(utf8.decode(output), 'Hello ');
    expect(cancelCalls, 1);
    expect(readerCancelCalls, 1);
  });

  group('a cancelGeneration during a streamed reply', () {
    // Mirrors @litert-lm/core 0.18.0: Conversation.cancel() stops the native
    // run, whose cancelled status errors the stream and rejects the pending
    // read. [error] errors the stream without a cancel instead.
    String moduleUrl({
      String? error,
      String cancelError = "new Error('Task cancelled')",
    }) =>
        'data:text/javascript;charset=utf-8,${Uri.encodeComponent('''
      export const Backend = { CPU: 3, GPU_ARTISAN: 2, GPU: 4 };
      export const Engine = {
        async create() {
          return {
            async createConversation() {
              let fail = () => {};
              return {
                sendMessageStreaming() {
                  let pulls = 0;
                  return new ReadableStream({
                    start(controller) {
                      fail = (error) => controller.error(error);
                    },
                    pull(controller) {
                      if (pulls++ === 0) {
                        controller.enqueue({
                          content: [{ type: 'text', text: 'partial' }],
                        });
                        return;
                      }
                      globalThis.__llamadartLiteRtLmReadPending = true;
                      ${error == null ? '' : 'fail($error);'}
                    },
                  }, { highWaterMark: 0 });
                },
                cancel() {
                  fail($cancelError);
                },
                async delete() {},
              };
            },
            async delete() {},
          };
        },
      };
    ''')}';

    final userTurn = [
      LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'Reply'),
    ];

    Future<(LlamaEngine, _ResultRecorder)> loadEngine({
      String? error,
      String cancelError = "new Error('Task cancelled')",
    }) async {
      final recorder = _ResultRecorder();
      final engine = LlamaEngine(
        LiteRtLmBackend(
          moduleUrl: moduleUrl(error: error, cancelError: cancelError),
        ),
        observers: [recorder],
      );
      addTearDown(engine.dispose);
      await engine.loadModelFromUrl('https://example.com/model.litertlm');
      return (engine, recorder);
    }

    Future<void> cancelAtPendingRead(LlamaEngine engine) async {
      while (!globalContext.has('__llamadartLiteRtLmReadPending')) {
        await Future<void>.delayed(Duration.zero);
      }
      engine.cancelGeneration();
    }

    test('create ends with stop, as cancelled, when the pending read '
        'rejects', () async {
      final (engine, recorder) = await loadEngine();
      final completion = engine.complete(userTurn);
      await cancelAtPendingRead(engine);

      expect((await completion).finishReason, api.LlamaFinishReason.stop);
      expect(recorder.results.single.error, isNull);
      expect(recorder.results.single.cancelled, isTrue);
    });

    test('generate keeps the text before a cancel whose pending read '
        'rejects', () async {
      final (engine, recorder) = await loadEngine();
      final text = engine.generate('Reply').join();
      await cancelAtPendingRead(engine);

      expect(await text, 'partial');
      expect(recorder.results.single.error, isNull);
      expect(recorder.results.single.cancelled, isTrue);
    });

    for (final (error, diagnostic) in [
      ("new Error('GPU device lost')", 'GPU device lost'),
      (
        "new Error('Task cancelled: device lost')",
        'Task cancelled: device lost',
      ),
      ("new DOMException('aborted', 'AbortError')", 'aborted'),
      ("'Task cancelled'", 'Task cancelled'),
      ("({ message: 42 })", '[object Object]'),
      (
        "({ get message() { throw new Error('lookup failed'); }, "
            "toString() { return 'runtime fault'; } })",
        'runtime fault',
      ),
    ]) {
      test('surfaces $error after cancelGeneration', () async {
        final (engine, recorder) = await loadEngine(cancelError: error);
        final result = expectLater(
          engine.create(userTurn).toList(),
          throwsA(
            isA<LlamaInferenceException>().having(
              (error) => error.toString(),
              'original diagnostic',
              contains(diagnostic),
            ),
          ),
        );
        await cancelAtPendingRead(engine);
        await result;

        expect(recorder.results.single.error, isA<LlamaInferenceException>());
        expect(recorder.results.single.cancelled, isFalse);
      });
    }

    for (final error in [
      "new DOMException('aborted', 'AbortError')",
      "new Error('Task cancelled')",
    ]) {
      test('surfaces $error that no cancel requested', () async {
        final (engine, recorder) = await loadEngine(error: error);

        await expectLater(
          engine.create(userTurn).toList(),
          throwsA(isA<LlamaInferenceException>()),
        );
        expect(recorder.results.single.error, isA<LlamaInferenceException>());
        expect(recorder.results.single.cancelled, isFalse);
      });
    }
  });

  test('reports missing web runtime with actionable setup error', () async {
    final backend = LiteRtLmBackend(readyTimeout: Duration.zero);

    await expectLater(
      () => backend.modelLoadFromUrl(
        'https://example.com/model.litertlm',
        const ModelParams(),
      ),
      throwsA(
        isA<LlamaBackendInitializationException>().having(
          (error) => error.message,
          'message',
          contains('__llamadartLiteRtLmModuleUrl'),
        ),
      ),
    );
  });

  test('public engine wraps a missing web runtime in a model error', () async {
    final engine = LlamaEngine(LiteRtLmBackend(readyTimeout: Duration.zero));
    try {
      await expectLater(
        engine.loadModel('https://example.com/model.litertlm'),
        throwsA(
          isA<LlamaModelException>().having(
            (error) => '${error.details}',
            'details',
            contains('LiteRT-LM web runtime is not loaded'),
          ),
        ),
      );
      expect(engine.isReady, isFalse);
    } finally {
      await engine.dispose();
    }
  });

  test(
    'public engine rejects unsupported web model params and recovers',
    () async {
      var creates = 0;
      _installFakeEngine(
        onCreate: (_) {
          creates++;
        },
        chunks: <JSAny?>[_messageChunk('Hello')],
      );
      final engine = LlamaEngine(LiteRtLmBackend());
      try {
        await expectLater(
          engine.loadModel(
            'https://example.com/model.litertlm',
            modelParams: const ModelParams(batchSize: 128, useMlock: true),
          ),
          throwsA(
            isA<LlamaUnsupportedException>().having(
              (error) => error.message,
              'message',
              allOf(
                contains('LiteRtLmBackend web'),
                contains('batchSize'),
                contains('useMlock'),
              ),
            ),
          ),
        );
        expect(creates, 0, reason: 'Rejection must precede engine creation');
        expect(engine.isReady, isFalse);

        await engine.loadModel('https://example.com/model.litertlm');
        expect(await engine.generate('hello').join(), 'Hello');
      } finally {
        await engine.dispose();
      }
    },
  );

  group('a generation started after a cancel', () {
    const params = GenerationParams(maxTokens: 16);
    late _QueueFakeEngine fake;
    late LiteRtLmBackend backend;

    Future<void> load({bool rejectOnCancel = false}) async {
      fake = _installQueueFakeEngine(rejectOnCancel: rejectOnCancel);
      backend = LiteRtLmBackend();
      const modelParams = ModelParams();
      await backend.modelLoadFromUrl(
        'https://example.com/model.litertlm',
        modelParams,
      );
      await backend.contextCreate(1, modelParams);
    }

    setUp(load);

    tearDown(() async {
      fake.finishAll();
      await backend.dispose();
    });

    test('waits for a run stopped by cancelGeneration, then starts', () async {
      final first = _CollectedGeneration(backend.generate(1, 'first', params));
      final firstRun = await fake.started(0);
      await first.firstChunk;
      await firstRun.holding;

      backend.cancelGeneration();
      expect(firstRun.cancelCalls, 1);
      final second = _CollectedGeneration(
        backend.generate(1, 'second', params),
      );
      await _settle();
      expect(fake.runs, hasLength(1));
      expect(second.error, isNull);

      firstRun.finish();
      await first.done;
      expect(first.error, isNull);
      expect(first.text, 'first;');

      final secondRun = await fake.started(1);
      expect(secondRun.prompt, 'second');
      await second.firstChunk;
      secondRun.finish();
      await second.done;
      expect(second.error, isNull);
      expect(second.text, 'second;');
    });

    test(
      'waits for a run stopped by a subscription cancel, then starts',
      () async {
        final first = _CollectedGeneration(
          backend.generate(1, 'first', params),
        );
        final firstRun = await fake.started(0);
        await first.firstChunk;
        await firstRun.holding;

        final firstCancelled = first.subscription.cancel();
        expect(firstRun.cancelCalls, 1);
        final second = _CollectedGeneration(
          backend.generate(1, 'second', params),
        );
        await _settle();
        expect(fake.runs, hasLength(1));
        expect(second.error, isNull);

        firstRun.finish();
        await firstCancelled;
        final secondRun = await fake.started(1);
        secondRun.finish();
        await second.done;
        expect(second.error, isNull);
        expect(second.text, 'second;');
      },
    );

    test('a subscription cancel whose runtime rejects the pending read '
        'neither surfaces that error nor blocks the next generation', () async {
      await backend.dispose();
      await load(rejectOnCancel: true);
      final first = _CollectedGeneration(backend.generate(1, 'first', params));
      final firstRun = await fake.started(0);
      await first.firstChunk;
      await firstRun.holding;

      await first.subscription.cancel();
      expect(firstRun.cancelCalls, 1);
      final second = _CollectedGeneration(
        backend.generate(1, 'second', params),
      );
      final secondRun = await fake.started(1);
      secondRun.finish();
      await second.done;
      expect(second.error, isNull);
      expect(second.text, 'second;');
    });

    test('a subscription cancel drops a later createConversation failure '
        'and frees the slot', () async {
      final gate = Completer<void>();
      fake.failNextConversation = gate.future;
      final first = _CollectedGeneration(backend.generate(1, 'first', params));
      await _settle();

      final firstCancelled = first.subscription.cancel();
      gate.complete();
      await firstCancelled;
      expect(first.error, isNull);

      final second = _CollectedGeneration(
        backend.generate(1, 'second', params),
      );
      final secondRun = await fake.started(0);
      secondRun.finish();
      await second.done;
      expect(second.error, isNull);
      expect(second.text, 'second;');
    });

    test('a cancel before the first token ends the stream without sending '
        'the prompt', () async {
      final first = _CollectedGeneration(backend.generate(1, 'first', params));
      backend.cancelGeneration();
      await first.done;
      expect(first.error, isNull);
      expect(first.text, isEmpty);
      expect(fake.runs, isEmpty);

      final second = _CollectedGeneration(
        backend.generate(1, 'second', params),
      );
      final secondRun = await fake.started(0);
      expect(secondRun.prompt, 'second');
      secondRun.finish();
      await second.done;
      expect(second.error, isNull);
      expect(second.text, 'second;');
    });

    test(
      'a cancel after completion does not affect the next generation',
      () async {
        final first = _CollectedGeneration(
          backend.generate(1, 'first', params),
        );
        (await fake.started(0)).finish();
        await first.done;
        expect(first.text, 'first;');

        backend.cancelGeneration();
        final second = _CollectedGeneration(
          backend.generate(1, 'second', params),
        );
        final secondRun = await fake.started(1);
        await second.firstChunk;
        secondRun.finish();
        await second.done;
        expect(second.error, isNull);
        expect(second.text, 'second;');
        expect(secondRun.cancelCalls, 0);
      },
    );

    test('repeated cancels queue the next generation once', () async {
      final first = _CollectedGeneration(backend.generate(1, 'first', params));
      final firstRun = await fake.started(0);
      await first.firstChunk;
      await firstRun.holding;

      backend
        ..cancelGeneration()
        ..cancelGeneration();
      final firstCancelled = first.subscription.cancel();
      backend.cancelGeneration();
      final second = _CollectedGeneration(
        backend.generate(1, 'second', params),
      );
      await _settle();
      expect(fake.runs, hasLength(1));

      firstRun.finish();
      await firstCancelled;
      final secondRun = await fake.started(1);
      await second.firstChunk;
      secondRun.finish();
      await second.done;
      expect(second.error, isNull);
      expect(second.text, 'second;');
      expect(fake.runs, hasLength(2));
    });

    test('a stop sequence in the cancelled run does not end the generation '
        'queued behind it', () async {
      final first = _CollectedGeneration(
        backend.generate(
          1,
          'first',
          const GenerationParams(maxTokens: 16, stopSequences: ['#']),
        ),
      );
      final firstRun = await fake.started(0);
      await first.firstChunk;
      await firstRun.holding;

      backend.cancelGeneration();
      final second = _CollectedGeneration(
        backend.generate(1, 'second', params),
      );
      await _settle();

      // A one-character stop sequence holds no text back, so the tail's
      // match reaches onStop before the cancelled run's loop breaks.
      firstRun.finish(tail: '#');
      await first.done;
      final secondRun = await fake.started(1);
      secondRun.finish();
      await second.done;
      expect(second.error, isNull);
      expect(second.text, 'second;');
    });

    test('a subscription cancel of the cancelled run does not end the '
        'generation queued behind it', () async {
      final first = _CollectedGeneration(backend.generate(1, 'first', params));
      final firstRun = await fake.started(0);
      await first.firstChunk;
      await firstRun.holding;

      backend.cancelGeneration();
      final second = _CollectedGeneration(
        backend.generate(1, 'second', params),
      );
      await _settle();
      final firstCancelled = first.subscription.cancel();
      await _settle();
      expect(second.isDone, isFalse);

      firstRun.finish();
      await firstCancelled;
      final secondRun = await fake.started(1);
      secondRun.finish();
      await second.done;
      expect(second.error, isNull);
      expect(second.text, 'second;');
    });

    test('ending a queued run keeps the slot while the cancelled run is still '
        'streaming', () async {
      final first = _CollectedGeneration(backend.generate(1, 'first', params));
      final firstRun = await fake.started(0);
      await first.firstChunk;
      await firstRun.holding;

      backend.cancelGeneration();
      final second = _CollectedGeneration(
        backend.generate(1, 'second', params),
      );
      await _settle();
      backend.cancelGeneration();
      await second.done;

      final third = _CollectedGeneration(backend.generate(1, 'third', params));
      await _settle();
      expect(fake.runs, hasLength(1));

      firstRun.finish();
      await first.done;
      final thirdRun = await fake.started(1);
      thirdRun.finish();
      await third.done;
      expect(third.error, isNull);
      expect(third.text, 'third;');
    });

    test(
      'cancelGeneration ends a queued generation without running it',
      () async {
        final first = _CollectedGeneration(
          backend.generate(1, 'first', params),
        );
        final firstRun = await fake.started(0);
        await first.firstChunk;
        await firstRun.holding;

        backend.cancelGeneration();
        final second = _CollectedGeneration(
          backend.generate(1, 'second', params),
        );
        await _settle();
        backend.cancelGeneration();
        await second.done;
        expect(second.error, isNull);
        expect(second.text, isEmpty);

        firstRun.finish();
        await first.done;
        final third = _CollectedGeneration(
          backend.generate(1, 'third', params),
        );
        final thirdRun = await fake.started(1);
        thirdRun.finish();
        await third.done;
        expect(third.error, isNull);
        expect(third.text, 'third;');
        expect(fake.runs.map((run) => run.prompt), ['first', 'third']);
      },
    );

    test(
      'a subscription cancel of a queued generation leaves the queue',
      () async {
        final first = _CollectedGeneration(
          backend.generate(1, 'first', params),
        );
        final firstRun = await fake.started(0);
        await first.firstChunk;
        await firstRun.holding;

        backend.cancelGeneration();
        final second = _CollectedGeneration(
          backend.generate(1, 'second', params),
        );
        await _settle();
        await second.subscription.cancel();
        final third = _CollectedGeneration(
          backend.generate(1, 'third', params),
        );
        await _settle();
        expect(third.error, isNull);

        firstRun.finish();
        final thirdRun = await fake.started(1);
        thirdRun.finish();
        await third.done;
        expect(third.error, isNull);
        expect(third.text, 'third;');
        expect(fake.runs.map((run) => run.prompt), ['first', 'third']);
      },
    );

    test('a queued run ended by cancelGeneration never creates a '
        'conversation', () async {
      final first = _CollectedGeneration(backend.generate(1, 'first', params));
      final firstRun = await fake.started(0);
      await first.firstChunk;
      await firstRun.holding;

      backend.cancelGeneration();
      final second = _CollectedGeneration(
        backend.generate(1, 'second', params),
      );
      await _settle();
      final created = fake.conversationsCreated;
      fake.failNextConversation = Future<void>.value();
      backend.cancelGeneration();
      await second.done;
      await _settle();
      expect(second.error, isNull);
      expect(second.text, isEmpty);
      expect(fake.conversationsCreated, created);
      fake.failNextConversation = null;
    });

    test(
      'a generation started from the previous one\'s onDone starts',
      () async {
        final firstEnded = Completer<_CollectedGeneration>();
        backend
            .generate(1, 'first', params)
            .listen(
              (_) {},
              onDone: () => firstEnded.complete(
                _CollectedGeneration(backend.generate(1, 'second', params)),
              ),
            );
        (await fake.started(0)).finish();
        final second = await firstEnded.future.timeout(
          const Duration(seconds: 2),
        );
        final secondRun = await fake.started(1);
        secondRun.finish();
        await second.done;
        expect(second.error, isNull);
        expect(second.text, 'second;');
      },
    );

    test(
      'a queued run that ends before admission does not hold the slot',
      () async {
        final first = _CollectedGeneration(
          backend.generate(1, 'first', params),
        );
        final firstRun = await fake.started(0);
        await first.firstChunk;
        await firstRun.holding;

        backend.cancelGeneration();
        final second = _CollectedGeneration(
          backend.generate(1, 'second', const GenerationParams(maxTokens: 0)),
        );
        await second.done;
        expect(second.error, isNull);

        firstRun.finish();
        await first.done;
        await _settle();
        final third = _CollectedGeneration(
          backend.generate(1, 'third', params),
        );
        final thirdRun = await fake.started(1);
        thirdRun.finish();
        await third.done;
        expect(third.error, isNull);
        expect(third.text, 'third;');
      },
    );

    test('a generation requested right after cancelGeneration ends the '
        'queued one takes its place', () async {
      final first = _CollectedGeneration(backend.generate(1, 'first', params));
      final firstRun = await fake.started(0);
      await first.firstChunk;
      await firstRun.holding;

      backend.cancelGeneration();
      final second = _CollectedGeneration(
        backend.generate(1, 'second', params),
      );
      await _settle();
      backend.cancelGeneration();
      final third = _CollectedGeneration(backend.generate(1, 'third', params));
      await _settle();
      expect(third.error, isNull);

      firstRun.finish();
      final thirdRun = await fake.started(1);
      thirdRun.finish();
      await third.done;
      expect(second.text, isEmpty);
      expect(third.error, isNull);
      expect(third.text, 'third;');
    });

    test('an admitted queued run leaves the queue', () async {
      final first = _CollectedGeneration(backend.generate(1, 'first', params));
      final firstRun = await fake.started(0);
      await first.firstChunk;
      await firstRun.holding;

      backend.cancelGeneration();
      final second = _CollectedGeneration(
        backend.generate(1, 'second', params),
      );
      await _settle();
      firstRun.finish();
      final secondRun = await fake.started(1);
      await second.firstChunk;
      await secondRun.holding;

      backend.cancelGeneration();
      final third = _CollectedGeneration(backend.generate(1, 'third', params));
      await _settle();
      expect(third.error, isNull);

      secondRun.finish();
      final thirdRun = await fake.started(2);
      thirdRun.finish();
      await third.done;
      expect(third.error, isNull);
      expect(third.text, 'third;');
    });

    test('a subscription cancel completes after its run releases the '
        'conversation', () async {
      await backend.dispose();
      await load(rejectOnCancel: true);
      final first = _CollectedGeneration(backend.generate(1, 'first', params));
      final firstRun = await fake.started(0);
      await first.firstChunk;
      await firstRun.holding;

      await first.subscription.cancel();
      expect(fake.conversationsDeleted, 1);
    });

    test('pausing the stream pauses the run', () async {
      final first = _CollectedGeneration(backend.generate(1, 'first', params));
      final firstRun = await fake.started(0);
      await first.firstChunk;
      await firstRun.holding;

      first.subscription.pause();
      firstRun.finish(tail: 'more;');
      await _settle();
      expect(first.text, 'first;');
      expect(fake.conversationsDeleted, 0, reason: 'the paused run waits');

      first.subscription.resume();
      await first.done;
      expect(first.error, isNull);
      expect(first.text, 'first;more;');
      expect(fake.conversationsDeleted, 1);
    });

    test('dispose ends a queued generation without running it', () async {
      final first = _CollectedGeneration(backend.generate(1, 'first', params));
      final firstRun = await fake.started(0);
      await first.firstChunk;
      await firstRun.holding;

      backend.cancelGeneration();
      final second = _CollectedGeneration(
        backend.generate(1, 'second', params),
      );
      await _settle();

      await backend.dispose();
      firstRun.finish();
      await first.done;
      await second.done;
      expect(second.error, isNull);
      expect(second.text, isEmpty);
      expect(fake.runs, hasLength(1));
    });

    test(
      'contextFree while conversation creation waits sends no stale prompt',
      () async {
        final gate = Completer<void>();
        fake.delayNextConversation = gate.future;
        final generation = _CollectedGeneration(
          backend.generate(1, 'stale', params),
        );
        await _settle();
        final deleted = fake.allConversationsDeleted;
        await backend.contextFree(1);
        gate.complete();
        await generation.done;
        expect(generation.error, isNull);
        expect(fake.runs, isEmpty);
        expect(fake.allConversationsDeleted, deleted + 1);
      },
    );

    test('contextFree and stream cleanup delete a conversation once', () async {
      final generation = _CollectedGeneration(
        backend.generate(1, 'active', params),
      );
      final run = await fake.started(0);
      await run.holding;
      final deleted = fake.allConversationsDeleted;
      await backend.contextFree(1);
      run.finish();
      await generation.done;
      expect(run.cancelCalls, 1);
      expect(fake.allConversationsDeleted, deleted + 1);
    });

    test('contextFree ends a queued generation without running it', () async {
      final first = _CollectedGeneration(backend.generate(1, 'first', params));
      final firstRun = await fake.started(0);
      await first.firstChunk;
      await firstRun.holding;

      backend.cancelGeneration();
      final second = _CollectedGeneration(
        backend.generate(1, 'second', params),
      );
      await _settle();

      await backend.contextFree(1);
      await second.done;
      expect(second.error, isNull);
      expect(second.text, isEmpty);

      firstRun.finish();
      await first.done;
      await _settle();
      expect(fake.runs, hasLength(1));
    });

    test('overlapping a generation that was not cancelled throws '
        'LlamaStateException', () async {
      final first = _CollectedGeneration(backend.generate(1, 'first', params));
      final firstRun = await fake.started(0);
      await first.firstChunk;
      await firstRun.holding;

      final second = _CollectedGeneration(
        backend.generate(1, 'second', params),
      );
      await second.done;
      expect(
        second.error,
        isA<LlamaStateException>().having(
          (error) => error.message,
          'message',
          contains('already in progress'),
        ),
      );

      firstRun.finish();
      await first.done;
      expect(first.error, isNull);
      expect(first.text, 'first;');
      expect(fake.runs, hasLength(1));
    });

    test('a second generation queued behind a cancel throws '
        'LlamaStateException', () async {
      final first = _CollectedGeneration(backend.generate(1, 'first', params));
      final firstRun = await fake.started(0);
      await first.firstChunk;
      await firstRun.holding;

      backend.cancelGeneration();
      final second = _CollectedGeneration(
        backend.generate(1, 'second', params),
      );
      final third = _CollectedGeneration(backend.generate(1, 'third', params));
      await third.done;
      expect(third.error, isA<LlamaStateException>());

      firstRun.finish();
      final secondRun = await fake.started(1);
      secondRun.finish();
      await second.done;
      expect(second.error, isNull);
      expect(second.text, 'second;');
      expect(fake.runs.map((run) => run.prompt), ['first', 'second']);
    });
  });

  test('LlamaEngine starts a Web generation requested right after '
      'cancelGeneration', () async {
    final fake = _installQueueFakeEngine();
    final engine = LlamaEngine(LiteRtLmBackend());
    try {
      await engine.loadModel('https://example.com/model.litertlm');
      final firstDone = Completer<void>();
      final first = engine
          .generate('first')
          .listen(
            (_) {},
            onError: firstDone.completeError,
            onDone: firstDone.complete,
          );
      final firstRun = await fake.started(0);
      await firstRun.holding;

      engine.cancelGeneration();
      final second = engine.generate('second').join();
      await _settle();
      expect(fake.runs, hasLength(1));

      firstRun.finish();
      await firstDone.future;
      await first.cancel();
      (await fake.started(1)).finish();
      expect(await second, 'second;');
    } finally {
      fake.finishAll();
      await engine.dispose();
    }
  });

  group('ModelParams.device', () {
    const url = 'https://example.com/gemma-4-E2B-it-web.litertlm';
    late List<int> createdBackends;

    setUp(() {
      createdBackends = <int>[];
      _installFakeEngine(
        onCreate: (settings) => createdBackends.add(
          (settings.getProperty('backend'.toJS) as JSNumber).toDartInt,
        ),
        chunks: const <JSAny?>[],
      );
    });

    test('gpu probes WebGPU and runs on the GPU', () async {
      addTearDown(fakeNavigatorGpu(FakeWebGpu.adapter));

      await LiteRtLmBackend().modelLoadFromUrl(
        url,
        const ModelParams(device: ComputeDevice.gpu),
      );

      expect(createdBackends, [2]);
    });

    for (final gpu in [FakeWebGpu.missing, FakeWebGpu.noAdapter]) {
      test('gpu without a WebGPU adapter (${gpu.name}) throws before the '
          'engine starts', () async {
        addTearDown(fakeNavigatorGpu(gpu));

        await expectLater(
          LiteRtLmBackend().modelLoadFromUrl(
            url,
            const ModelParams(device: ComputeDevice.gpu),
          ),
          throwsA(
            isA<LlamaUnsupportedException>().having(
              (e) => e.message,
              'message',
              allOf(contains('ComputeDevice.gpu'), contains('WebGPU')),
            ),
          ),
        );
        expect(createdBackends, isEmpty);
      });
    }

    test('auto keeps the GPU default without a probe', () async {
      addTearDown(fakeNavigatorGpu(FakeWebGpu.missing));

      await LiteRtLmBackend().modelLoadFromUrl(url, const ModelParams());

      expect(createdBackends, [2]);
    });

    for (final (gpuLayers, backend) in const [
      (-1, 2),
      (-2, 2),
      (ModelParams.maxGpuLayers, 2),
      (0, 3),
    ]) {
      test('auto with gpuLayers $gpuLayers creates backend $backend', () async {
        addTearDown(fakeNavigatorGpu(FakeWebGpu.missing));

        await LiteRtLmBackend().modelLoadFromUrl(
          url,
          ModelParams(gpuLayers: gpuLayers),
        );

        expect(createdBackends, [backend]);
      });
    }

    test('a context with negative gpuLayers keeps a GPU model', () async {
      addTearDown(fakeNavigatorGpu(FakeWebGpu.missing));
      final backend = LiteRtLmBackend();
      final modelHandle = await backend.modelLoadFromUrl(
        url,
        const ModelParams(),
      );

      await backend.contextCreate(
        modelHandle,
        const ModelParams(gpuLayers: -1),
      );
      await expectLater(
        () =>
            backend.contextCreate(modelHandle, const ModelParams(gpuLayers: 0)),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message.toString(),
            'message',
            contains('from gpu to cpu'),
          ),
        ),
      );
    });

    test('cpu runs on the CPU', () async {
      await LiteRtLmBackend().modelLoadFromUrl(
        url,
        const ModelParams(device: ComputeDevice.cpu),
      );

      expect(createdBackends, [3]);
    });

    test('npu throws LlamaUnsupportedException', () async {
      await expectLater(
        LiteRtLmBackend().modelLoadFromUrl(
          url,
          const ModelParams(device: ComputeDevice.npu),
        ),
        throwsA(
          isA<LlamaUnsupportedException>().having(
            (e) => e.message,
            'message',
            contains('ComputeDevice.npu'),
          ),
        ),
      );
      expect(createdBackends, isEmpty);
    });

    test(
      'an explicit device rejects the deprecated preferredBackend',
      () async {
        await expectLater(
          LiteRtLmBackend(
            preferredBackend: 'cpu',
          ).modelLoadFromUrl(url, const ModelParams(device: ComputeDevice.cpu)),
          throwsA(
            isA<LlamaUnsupportedException>().having(
              (e) => e.message,
              'message',
              contains('Set only ModelParams.device'),
            ),
          ),
        );
        expect(createdBackends, isEmpty);
      },
    );
  });

  test('rejects non-LiteRT model sources before loading runtime', () async {
    final backend = LiteRtLmBackend(readyTimeout: Duration.zero);

    await expectLater(
      () => backend.modelLoadFromUrl(
        'https://example.com/model.gguf',
        const ModelParams(),
      ),
      throwsA(isA<ArgumentError>()),
    );
  });
}

typedef _CreateHook = void Function(JSObject settings);
typedef _ConversationHook = void Function(JSObject config);
typedef _PromptHook = void Function(String prompt);

void _installFakeEngine({
  _CreateHook? onCreate,
  _ConversationHook? onCreateConversation,
  _PromptHook? onPrompt,
  void Function()? onCancel,
  void Function()? onReaderCancel,
  required List<JSAny?> chunks,
  bool textHistory = false,
  bool historyApi = true,
}) {
  final engineClass = JSObject();
  engineClass.setProperty(
    'create'.toJS,
    ((JSObject settings) {
      onCreate?.call(settings);
      final engine = JSObject();
      engine.setProperty(
        'createConversation'.toJS,
        ((JSObject config) {
          final preface = textHistory
              ? config.getProperty<JSAny?>('preface'.toJS)
              : null;
          if (preface == null) onCreateConversation?.call(config);
          final conversation = _fakeConversation(
            chunks: chunks,
            onPrompt: onPrompt,
            onCancel: onCancel,
            onReaderCancel: onReaderCancel,
          );
          if (historyApi) {
            conversation.setProperty(
              'getHistory'.toJS,
              (() => Future<JSAny?>.value(<JSAny?>[].toJS).toJS).toJS,
            );
          }
          if (preface != null &&
              (preface as JSObject)
                  .getProperty<JSArray>('messages'.toJS)
                  .toDart
                  .isNotEmpty) {
            onCreateConversation?.call(config);
          }
          return Future<JSObject>.value(conversation).toJS;
        }).toJS,
      );
      engine.setProperty(
        'delete'.toJS,
        (() => Future<JSAny?>.value(null).toJS).toJS,
      );
      return Future<JSObject>.value(engine).toJS;
    }).toJS,
  );
  globalContext.setProperty('LiteRtLmEngine'.toJS, engineClass);
}

JSObject _fakeConversation({
  required List<JSAny?> chunks,
  _PromptHook? onPrompt,
  void Function()? onCancel,
  void Function()? onReaderCancel,
}) {
  final conversation = JSObject();
  conversation.setProperty(
    'sendMessageStreaming'.toJS,
    ((String prompt) {
      onPrompt?.call(prompt);
      return _fakeReadableStream(chunks, onReaderCancel: onReaderCancel);
    }).toJS,
  );
  conversation.setProperty(
    'cancel'.toJS,
    (() {
      onCancel?.call();
    }).toJS,
  );
  conversation.setProperty(
    'delete'.toJS,
    (() => Future<JSAny?>.value(null).toJS).toJS,
  );
  return conversation;
}

JSObject _fakeReadableStream(
  List<JSAny?> chunks, {
  void Function()? onReaderCancel,
}) {
  final stream = JSObject();
  stream.setProperty(
    'getReader'.toJS,
    (() {
      var index = 0;
      final reader = JSObject();
      reader.setProperty(
        'read'.toJS,
        (() {
          final result = JSObject();
          if (index >= chunks.length) {
            result.setProperty('done'.toJS, true.toJS);
            return Future<JSObject>.value(result).toJS;
          }
          result.setProperty('done'.toJS, false.toJS);
          final value = chunks[index];
          index += 1;
          if (value != null) {
            result.setProperty('value'.toJS, value);
          }
          return Future<JSObject>.value(result).toJS;
        }).toJS,
      );
      reader.setProperty(
        'cancel'.toJS,
        (() {
          onReaderCancel?.call();
          return Future<JSAny?>.value(null).toJS;
        }).toJS,
      );
      reader.setProperty('releaseLock'.toJS, (() {}).toJS);
      return reader;
    }).toJS,
  );
  return stream;
}

JSObject _messageChunk(String text) {
  final chunk = JSObject();
  final content = JSArray();
  final item = JSObject();
  item.setProperty('type'.toJS, 'text'.toJS);
  item.setProperty('text'.toJS, text.toJS);
  content.setProperty(0.toJS, item);
  chunk.setProperty('content'.toJS, content);
  return chunk;
}

void _clearGlobals() {
  globalContext.delete('LiteRtLmEngine'.toJS);
  globalContext.delete('LiteRtLmBackendEnum'.toJS);
  globalContext.delete('__llamadartLiteRtLmModule'.toJS);
  globalContext.delete('__llamadartLiteRtLmModuleUrl'.toJS);
  globalContext.delete('__llamadartLiteRtLmModuleSettings'.toJS);
  globalContext.delete('__llamadartLiteRtLmModuleConversationConfig'.toJS);
  globalContext.delete('__llamadartLiteRtLmModulePrompt'.toJS);
  globalContext.delete('__llamadartLiteRtLmLogLevel'.toJS);
  globalContext.delete('__llamadartInstallLiteRtLmConsoleGuard'.toJS);
  globalContext.delete('__llamadartLiteRtLmReadPending'.toJS);
}

final class _ResultRecorder extends LlamaEngineObserver {
  final List<api.LlamaOperationResult> results = <api.LlamaOperationResult>[];

  @override
  LlamaOperationObserver? onStart(api.LlamaOperation operation) =>
      operation is api.LlamaModelLoadOperation
      ? null
      : _ResultObserver(results);
}

final class _ResultObserver extends LlamaOperationObserver {
  _ResultObserver(this.results);

  final List<api.LlamaOperationResult> results;

  @override
  void onEnd(api.LlamaOperationResult result) => results.add(result);
}

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 20));

final class _CollectedGeneration {
  _CollectedGeneration(Stream<List<int>> stream) {
    subscription = stream.listen(
      (bytes) {
        _bytes.addAll(bytes);
        if (!_firstChunk.isCompleted) _firstChunk.complete();
      },
      onError: (Object error) => this.error = error,
      onDone: _done.complete,
    );
  }

  late final StreamSubscription<List<int>> subscription;
  final List<int> _bytes = <int>[];
  final Completer<void> _firstChunk = Completer<void>();
  final Completer<void> _done = Completer<void>();
  Object? error;

  String get text => utf8.decode(_bytes);
  bool get isDone => _done.isCompleted;
  Future<void> get firstChunk =>
      _firstChunk.future.timeout(const Duration(seconds: 2));
  Future<void> get done => _done.future.timeout(const Duration(seconds: 2));
}

/// One `sendMessageStreaming` run: it streams `'$prompt;'`, then holds its
/// next read until [finish], like a runtime that takes time to stop after a
/// cancel.
final class _QueueFakeRun {
  _QueueFakeRun(this.prompt);

  final String prompt;
  final Completer<String?> _tail = Completer<String?>();
  final Completer<void> _holding = Completer<void>();
  int cancelCalls = 0;

  /// Completes once the reader waits on the read that [finish] ends.
  Future<void> get holding =>
      _holding.future.timeout(const Duration(seconds: 2));

  /// Ends the run, first emitting [tail] when given.
  void finish({String? tail}) {
    if (!_tail.isCompleted) _tail.complete(tail);
  }
}

final class _QueueFakeEngine {
  _QueueFakeEngine({required this.rejectOnCancel, this.textHistory = false});

  final bool textHistory;
  final List<Object?> prefaces = [];
  Future<void>? delayNextConversation;
  int allConversationsDeleted = 0;

  /// Whether `cancel()` rejects the held read, as `@litert-lm/core` 0.18.0
  /// does with its cancelled status.
  final bool rejectOnCancel;
  final List<_QueueFakeRun> runs = <_QueueFakeRun>[];

  /// When set, the next `createConversation` waits for it, then rejects.
  Future<void>? failNextConversation;

  /// How many times `createConversation` was called.
  int conversationsCreated = 0;

  /// How many conversations were deleted.
  int conversationsDeleted = 0;
  final List<Completer<_QueueFakeRun>> _started = List.generate(
    8,
    (_) => Completer<_QueueFakeRun>(),
  );

  Future<_QueueFakeRun> started(int index) =>
      _started[index].future.timeout(const Duration(seconds: 2));

  void finishAll() {
    for (final run in runs) {
      run.finish();
    }
  }

  Future<JSObject> _createConversation(JSObject config) async {
    conversationsCreated += 1;
    final delay = delayNextConversation;
    delayNextConversation = null;
    await delay;
    final preface = textHistory
        ? config.getProperty<JSAny?>('preface'.toJS)?.dartify()
        : null;
    final gate = failNextConversation;
    failNextConversation = null;
    if (gate != null) {
      await gate;
      throw StateError('createConversation failed');
    }
    return _conversation(preface);
  }

  JSObject _conversation(Object? preface) {
    _QueueFakeRun? run;
    final conversation = JSObject();
    if (textHistory) {
      conversation.setProperty(
        'getHistory'.toJS,
        (() => Future<JSAny?>.value(<JSAny?>[].toJS).toJS).toJS,
      );
    }
    conversation.setProperty(
      'sendMessageStreaming'.toJS,
      ((String prompt) {
        final current = run = _QueueFakeRun(prompt);
        prefaces.add(preface);
        runs.add(current);
        _started[runs.length - 1].complete(current);
        return _streamOf(current);
      }).toJS,
    );
    conversation.setProperty(
      'cancel'.toJS,
      (() {
        final current = run;
        if (current == null) return;
        current.cancelCalls += 1;
        if (rejectOnCancel && !current._tail.isCompleted) {
          current._tail.completeError(StateError('Task cancelled'));
        }
      }).toJS,
    );
    conversation.setProperty(
      'delete'.toJS,
      (() {
        allConversationsDeleted += 1;
        if (run != null) conversationsDeleted += 1;
        return Future<JSAny?>.value(null).toJS;
      }).toJS,
    );
    return conversation;
  }

  JSObject _streamOf(_QueueFakeRun run) {
    final stream = JSObject();
    stream.setProperty(
      'getReader'.toJS,
      (() {
        var reads = 0;
        var tailSent = false;
        final reader = JSObject();
        JSObject result({String? text}) {
          final result = JSObject();
          result.setProperty('done'.toJS, (text == null).toJS);
          if (text != null) {
            result.setProperty('value'.toJS, _messageChunk(text));
          }
          return result;
        }

        reader.setProperty(
          'read'.toJS,
          (() {
            if (reads++ == 0) {
              return Future<JSObject>.value(
                result(text: '${run.prompt};'),
              ).toJS;
            }
            if (!run._holding.isCompleted) run._holding.complete();
            return run._tail.future.then((tail) {
              if (tail == null || tailSent) return result();
              tailSent = true;
              return result(text: tail);
            }).toJS;
          }).toJS,
        );
        reader.setProperty(
          'cancel'.toJS,
          (() => Future<JSAny?>.value(null).toJS).toJS,
        );
        reader.setProperty('releaseLock'.toJS, (() {}).toJS);
        return reader;
      }).toJS,
    );
    return stream;
  }
}

_QueueFakeEngine _installQueueFakeEngine({
  bool rejectOnCancel = false,
  bool textHistory = false,
}) {
  final fake = _QueueFakeEngine(
    rejectOnCancel: rejectOnCancel,
    textHistory: textHistory,
  );
  final engineClass = JSObject();
  engineClass.setProperty(
    'create'.toJS,
    ((JSObject settings) {
      final engine = JSObject();
      engine.setProperty(
        'createConversation'.toJS,
        ((JSObject config) => fake._createConversation(config).toJS).toJS,
      );
      engine.setProperty(
        'delete'.toJS,
        (() => Future<JSAny?>.value(null).toJS).toJS,
      );
      return Future<JSObject>.value(engine).toJS;
    }).toJS,
  );
  globalContext.setProperty('LiteRtLmEngine'.toJS, engineClass);
  return fake;
}
