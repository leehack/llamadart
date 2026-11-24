@TestOn('browser')
@Tags(<String>['local-only', 'e2e'])
@Timeout(Duration(minutes: 30))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:llamadart/llamadart.dart';
import 'package:test/test.dart';
import 'package:web/web.dart';

const _moduleUrl = 'https://cdn.jsdelivr.net/npm/@litert-lm/core@0.20.0/+esm';
const _legacyModuleUrl =
    'https://cdn.jsdelivr.net/npm/@litert-lm/core@0.19.0/+esm';
const _contextSize = 1024;
const _prompt =
    'Write a Python function that returns the first n Fibonacci numbers. '
    'Include a docstring and comments, then show three example calls.';
const _greedy = GenerationParams(
  maxTokens: 160,
  temp: 0,
  topK: 1,
  topP: 1,
  seed: 1,
);

void main() {
  test(
    'LiteRT-LM WebGPU MTP through the public API and pinned JS runtime',
    () async {
      final response = await window
          .fetch('http://127.0.0.1:5198/manifest.json'.toJS)
          .toDart;
      final manifest =
          jsonDecode((await response.text().toDart).toDart)
              as Map<String, dynamic>;
      final model = manifest['model'] as String;
      final gpu = window.navigator.getProperty<JSObject>('gpu'.toJS);
      final adapter = await gpu
          .callMethod<JSPromise<JSObject?>>('requestAdapter'.toJS)
          .toDart;
      expect(adapter, isNotNull);
      final info = adapter!.getProperty<JSObject>('info'.toJS);
      _log('IDENTITY', {
        ...manifest,
        'module': _moduleUrl,
        'browser': window.navigator.userAgent,
        'vendor': info.getProperty<JSString>('vendor'.toJS).toDart,
        'architecture': info.getProperty<JSString>('architecture'.toJS).toDart,
        'crossOriginIsolated': window.crossOriginIsolated,
      });

      globalContext.setProperty(
        '__llamadartLiteRtLmModuleUrl'.toJS,
        _moduleUrl.toJS,
      );
      final engine = LlamaEngine(LlamaBackend.withTextHistory());
      addTearDown(engine.dispose);
      addTearDown(
        () => globalContext.delete('__llamadartLiteRtLmModuleUrl'.toJS),
      );
      const plain = LiteRtLmModelParams(
        device: ComputeDevice.gpu,
        contextSize: _contextSize,
      );
      final mtp = plain.copyWith(loadMtp: true);
      final source = LlamaModel(ModelSource.parse(model));

      if (manifest['expectUnsupported'] case final String reason) {
        await _expectRefusal(engine, source, mtp, reason);
        await engine.setModel(source, params: plain);
        final reply = await ChatSession(engine).send(
          'Say hello.\n/no_think',
          params: _greedy.copyWith(maxTokens: 512),
        );
        expect(reply.text.trim(), isNotEmpty);
        expect(
          (await engine.capabilities).speculativeDecodingStrategies,
          isEmpty,
        );
        _log('REFUSAL', {'reason': reason, 'plainReload': 'PASS'});
        return;
      }

      // The module URL path loads the actual namespace used by the backend.
      await _measureLoad(engine, source, plain, 'plain');
      expect(
        (await engine.capabilities).speculativeDecodingStrategies,
        isEmpty,
      );
      await _measureLoad(engine, source, mtp, 'drafter');
      expect((await engine.capabilities).speculativeDecodingStrategies, {
        SpeculativeDecodingStrategy.backendDefault,
        SpeculativeDecodingStrategy.mtp,
      });

      final on = _greedy.copyWith(
        speculativeDecodingConfig: const SpeculativeDecodingConfig.mtp(),
      );
      final replies = <bool, List<String>>{false: [], true: []};
      for (var repeat = 0; repeat < 3; repeat++) {
        // Run plain after MTP to catch session mode leaking from either level.
        for (final speculative in [true, false]) {
          final timer = Stopwatch()..start();
          final reply = await ChatSession(
            engine,
          ).send(_prompt, params: speculative ? on : _greedy);
          expect(reply.text.toLowerCase(), contains('fib'));
          replies[speculative]!.add(reply.text);
          _log('ADAPTER_TURN', {
            'speculative': speculative,
            'repeat': repeat,
            'wallMs': timer.elapsedMilliseconds,
            'finishReason': reply.finishReason?.name,
            'text': reply.text,
          });
        }
      }
      for (final texts in replies.values) {
        expect(texts.toSet(), hasLength(1));
      }

      var chunks = 0;
      final session = ChatSession(engine);
      final cancelled = session.create(const [
        LlamaTextContent(_prompt),
      ], params: on);
      await for (final chunk in cancelled) {
        if (chunk.text.isNotEmpty && chunks++ == 0) engine.cancelGeneration();
      }
      expect(chunks, greaterThan(0));
      session.reset();
      final reused = await session.send(_prompt, params: on);
      expect(reused.text, replies[true]!.first);

      final truncated = await ChatSession(
        engine,
      ).send(_prompt, params: on.copyWith(maxTokens: 3));
      expect(truncated.finishReason, LlamaFinishReason.length);

      var toolRuns = 0;
      final weather = ToolDefinition(
        name: 'get_weather',
        description: 'Returns the current weather for a city.',
        parameters: [
          ToolParam.string('city', description: 'City name', required: true),
        ],
        handler: (args) async {
          expect('${args['city']}'.toLowerCase(), contains('paris'));
          toolRuns++;
          return {'city': 'Paris', 'condition': 'violet hail', 'temp_c': -7};
        },
      );
      final weatherSession = ChatSession(
        engine,
        maxContextTokens: 0,
        systemPrompt:
            'You are a weather assistant. Call get_weather for every '
            'weather question, then answer from its result.',
      );
      final weatherReply = await weatherSession.sendWithTools(
        'What is the weather in Paris right now?',
        tools: [weather],
        params: on.copyWith(maxTokens: 512),
      );
      _log('ADAPTER_LIFECYCLE', {
        'cancellationChunks': chunks,
        'reuse': 'PASS',
        'truncatedFinishReason': truncated.finishReason?.name,
        'toolRuns': toolRuns,
        'toolStopReason': weatherReply.stopReason.name,
        'answer': weatherReply.completion.text,
      });
      expect(weatherReply.stopReason, LlamaToolLoopStopReason.completed);
      expect(toolRuns, greaterThan(0));
      expect(
        weatherReply.completion.text.toLowerCase(),
        anyOf(contains('violet'), contains('-7')),
      );
      await engine.unloadModel();

      final module = globalContext.getProperty<JSObject>(
        '__llamadartLiteRtLmModule'.toJS,
      );
      await _runReference(module, model);

      final legacy = await _importModule(_legacyModuleUrl);
      globalContext
        ..setProperty('LiteRtLmEngine'.toJS, legacy.getProperty('Engine'.toJS))
        ..setProperty(
          'LiteRtLmBackendEnum'.toJS,
          legacy.getProperty('Backend'.toJS),
        );
      try {
        await _expectRefusal(engine, source, mtp, '@litert-lm/core 0.20.0');
        _log('REFUSAL', {
          'module': _legacyModuleUrl,
          'reason': 'missing mode export',
        });
      } finally {
        globalContext
          ..setProperty(
            'LiteRtLmEngine'.toJS,
            module.getProperty('Engine'.toJS),
          )
          ..delete('LiteRtLmBackendEnum'.toJS);
      }
      await engine.setModel(source, params: plain);
      expect(
        (await ChatSession(engine).send('Say hello.', params: _greedy)).text,
        isNotEmpty,
      );
      _log('RESULT', {'status': 'PASS'});
    },
  );
}

Future<void> _measureLoad(
  LlamaEngine engine,
  LlamaModel source,
  LiteRtLmModelParams params,
  String mode,
) async {
  _log('LOAD_START', {'mode': mode});
  final timer = Stopwatch()..start();
  await engine.setModel(source, params: params);
  final memory = window.performance.getProperty<JSObject?>('memory'.toJS);
  _log('LOAD', {
    'mode': mode,
    'wallMs': timer.elapsedMilliseconds,
    'jsHeapBytes': memory
        ?.getProperty<JSNumber?>('usedJSHeapSize'.toJS)
        ?.toDartInt,
  });
}

Future<void> _expectRefusal(
  LlamaEngine engine,
  LlamaModel source,
  ModelParams params,
  String reason,
) async {
  await expectLater(
    engine.setModel(source, params: params),
    throwsA(
      isA<LlamaUnsupportedException>().having(
        (e) => e.message,
        'condition',
        contains(reason),
      ),
    ),
  );
  expect(engine.isReady, isFalse);
}

Future<JSObject> _importModule(String url) async {
  const callback = '__llamadartSpeculativeTestModule';
  final loaded = Completer<JSObject>();
  globalContext.setProperty(
    callback.toJS,
    ((JSObject? module, JSAny? error) {
      if (module != null) {
        loaded.complete(module);
      } else {
        loaded.completeError(StateError('Module import failed: $error'));
      }
    }).toJS,
  );
  final script = HTMLScriptElement()
    ..type = 'module'
    ..text =
        'import(${jsonEncode(url)}).then(m => window.$callback(m, null), '
        'e => window.$callback(null, String(e)));';
  document.head!.append(script);
  try {
    return await loaded.future.timeout(const Duration(seconds: 60));
  } finally {
    script.remove();
    globalContext.delete(callback.toJS);
  }
}

Future<void> _runReference(JSObject module, String model) async {
  final engineClass = module.getProperty<JSObject>('Engine'.toJS);
  final gpu = module
      .getProperty<JSObject>('Backend'.toJS)
      .getProperty<JSNumber>('GPU'.toJS)
      .toDartInt;
  final modes = module.getProperty<JSObject>('SpeculativeDecodingMode'.toJS);
  int mode(String name) => modes.getProperty<JSNumber>(name.toJS).toDartInt;
  final direct = await engineClass
      .callMethod<JSPromise<JSObject>>(
        'create'.toJS,
        {
          'model': model,
          'benchmarkEnabled': true,
          'mainExecutorSettings': {'maxNumTokens': _contextSize},
          'speculativeDecodingConfig': {'mode': mode('ON')},
        }.jsify(),
      )
      .toDart;
  try {
    expect(
      direct
          .getProperty<JSObject>('settings'.toJS)
          .getProperty<JSNumber>('backend'.toJS)
          .toDartInt,
      gpu,
    );
    for (var repeat = 0; repeat < 3; repeat++) {
      for (final name in ['ON', 'OFF']) {
        final conversation = await direct
            .callMethod<JSPromise<JSObject>>(
              'createConversation'.toJS,
              {
                'sessionConfig': {
                  'maxOutputTokens': _greedy.maxTokens,
                  'samplerBackend': gpu,
                  'samplerParams': {
                    'k': 1,
                    'p': 1,
                    'temperature': 0,
                    'seed': 1,
                  },
                  'speculativeDecodingConfig': {'mode': mode(name)},
                },
              }.jsify(),
            )
            .toDart;
        try {
          final timer = Stopwatch()..start();
          final stream = conversation.callMethod<ReadableStream>(
            'sendMessageStreaming'.toJS,
            _prompt.toJS,
          );
          final reader = stream.getReader() as ReadableStreamDefaultReader;
          try {
            while (!(await reader.read().toDart).done) {}
          } finally {
            reader.releaseLock();
          }
          final info =
              (await conversation
                          .callMethod<JSPromise<JSObject>>(
                            'getBenchmarkInfo'.toJS,
                          )
                          .toDart)
                      .dartify()
                  as Map<Object?, Object?>;
          _log('REFERENCE_TURN', {
            'mode': name,
            'repeat': repeat,
            'wallMs': timer.elapsedMilliseconds,
            'mtpRounds': info['mtpRounds'],
            'decodeTokens': info['lastDecodeTokenCount'],
            'decodeTokensPerSecond': info['lastDecodeTokensPerSecond'],
          });
          expect(info['mtpRounds'], name == 'ON' ? greaterThan(0) : 0);
        } finally {
          await conversation
              .callMethod<JSPromise<JSAny?>>('delete'.toJS)
              .toDart;
        }
      }
    }
  } finally {
    await direct.callMethod<JSPromise<JSAny?>>('delete'.toJS).toDart;
  }
}

void _log(String event, Map<String, Object?> data) {
  print('LITERT_SPECULATIVE_$event ${jsonEncode(data)}');
}
