@TestOn('browser')
library;

import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:llamadart/src/backends/litert_lm/litert_lm_backend_web.dart';
import 'package:llamadart/src/core/models/config/gpu_backend.dart';
import 'package:llamadart/src/core/models/inference/generation_params.dart';
import 'package:llamadart/src/core/models/inference/model_params.dart';
import 'package:test/test.dart';

void main() {
  setUp(_clearGlobals);
  tearDown(_clearGlobals);

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
    expect((settings.getProperty('backend'.toJS) as JSNumber).toDartInt, 4);
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
      4,
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

  test('reports missing web runtime with actionable setup error', () async {
    final backend = LiteRtLmBackend(readyTimeout: Duration.zero);

    await expectLater(
      () => backend.modelLoadFromUrl(
        'https://example.com/model.litertlm',
        const ModelParams(),
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('__llamadartLiteRtLmModuleUrl'),
        ),
      ),
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
          onCreateConversation?.call(config);
          return Future<JSObject>.value(
            _fakeConversation(
              chunks: chunks,
              onPrompt: onPrompt,
              onCancel: onCancel,
              onReaderCancel: onReaderCancel,
            ),
          ).toJS;
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
}
