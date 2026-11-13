/// Real pinned-asset `ToolChoice` checks on LFM2.5 through the direct, worker
/// and default `LlamaBackend()` Web routes (#1673).
///
/// Stage build/web_tool_choice_grammar/config.json with {"assets":"bridge/",
/// "legacyAssets":"bridge_legacy/","model":"models/LFM2.5-1.2B-Instruct-Q4_K_M.gguf"}
/// then run the web-tool-choice-grammar
/// scenario. Anything that stops a case from proving its claim fails the case
/// with a `NOT_RUN:` message, so a missing fixture never reads as a pass.
///
/// Assertions use parsed tool calls and the loose raw shape (the tool-call
/// markers and the tool name), never grammar text: the LFM2 grammar text
/// changes with the template contract.
@TestOn('browser')
@Tags(['local-only', 'e2e'])
@Timeout(Duration(minutes: 40))
library;

import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/backends/webgpu/interop.dart';
import 'package:llamadart/src/backends/webgpu/webgpu_backend.dart';
import 'package:test/test.dart';
import 'package:web/web.dart' show window;

const _pinnedModelSha256 =
    'b1b3de114215d9507409a662a501a631095a479a419584e8a2ded6304b19b4f5';
const _legacyAssetsTag = 'v0.1.81';
const _callStart = '<|tool_call_start|>';
const _callEnd = '<|tool_call_end|>';
const _tool = 'get_weather';

const _params = GenerationParams(maxTokens: 96, temp: 0, topK: 1, seed: 7);

const _modelParams = ModelParams(
  contextSize: 2048,
  gpuLayers: 0,
  preferredBackend: GpuBackend.cpu,
  numberOfThreads: 2,
  numberOfThreadsBatch: 2,
);

final _weather = ToolDefinition(
  name: _tool,
  description: 'Get the current weather for a city.',
  parameters: [
    ToolParam.string('city', description: 'City name', required: true),
  ],
);

const _toolPrompt = [
  LlamaChatMessage.fromText(
    role: LlamaChatRole.user,
    text: 'What is the weather in Paris right now?',
  ),
];

const _textPrompt = [
  LlamaChatMessage.fromText(
    role: LlamaChatRole.user,
    text: 'Reply with exactly one word: hello',
  ),
];

const _toolResultPrompt = [
  ..._toolPrompt,
  LlamaChatMessage.withContent(
    role: LlamaChatRole.assistant,
    content: [
      LlamaToolCallContent(
        id: 'call_0',
        name: _tool,
        arguments: {'city': 'Paris'},
        rawJson: '{"city":"Paris"}',
      ),
    ],
  ),
  LlamaChatMessage.withContent(
    role: LlamaChatRole.tool,
    content: [
      LlamaToolResultContent(
        id: 'call_0',
        name: _tool,
        result: {'city': 'Paris', 'temperature_c': 17, 'condition': 'drizzle'},
      ),
    ],
  ),
];

const _malformedCall =
    '$_callStart[{"name": "$_tool", "arguments": {"city": ]$_callEnd';

class _BridgeCall {
  _BridgeCall({
    required this.hasGrammar,
    required this.grammarLazy,
    required this.penalty,
    required this.stripped,
  });

  final bool hasGrammar;
  final Object? grammarLazy;
  final Object? penalty;
  final bool stripped;
  String? raw;
  String? error;
}

/// Records every bridge `createCompletion` call and can rewrite its grammar
/// in transit: `stripGrammar` is the causal negative control, `swapGrammar`
/// forces a fixed output.
class _Recorder {
  final calls = <_BridgeCall>[];
  final _pending = <Future<void>>[];
  bool stripGrammar = false;
  String? swapGrammar;

  LlamaWebGpuBridge wrap(LlamaWebGpuBridge bridge) {
    final original = bridge['createCompletion']! as JSFunction;
    bridge['createCompletion'] =
        ((JSAny? prompt, JSObject options) => intercept(
          original,
          bridge,
          prompt,
          options,
        )).toJS;
    return bridge;
  }

  JSAny? intercept(
    JSFunction original,
    JSObject self,
    JSAny? prompt,
    JSObject options,
  ) {
    final grammar = options['grammar'];
    final call = _BridgeCall(
      hasGrammar:
          grammar.isA<JSString>() && (grammar! as JSString).toDart != '',
      grammarLazy: options['grammarLazy'].dartify(),
      penalty: options['penalty'].dartify(),
      stripped: stripGrammar,
    );
    calls.add(call);
    if (stripGrammar) {
      options['grammar'] = null;
      options['grammarLazy'] = null;
      options['grammarTriggers'] = null;
    }
    final swap = swapGrammar;
    if (swap != null) options['grammar'] = swap.toJS;
    final result = original.callAsFunction(self, prompt, options);
    _pending.add(
      (result! as JSPromise<JSAny?>).toDart.then(
        (value) => call.raw = value.dartify()?.toString(),
        onError: (Object error) => call.error = '$error',
      ),
    );
    return result;
  }

  Future<void> settle() async {
    await Future.wait(_pending);
    _pending.clear();
  }
}

class _Outcome {
  _Outcome(this.completion, this.error, this.calls);

  final LlamaCompletion? completion;
  final Object? error;
  final List<_BridgeCall> calls;

  List<LlamaToolCallContent> get toolCalls =>
      completion?.toolCalls ?? const <LlamaToolCallContent>[];
  String get text => completion?.text ?? '';
  String get raw => calls.isEmpty ? '' : calls.last.raw ?? '';
}

class _Route {
  const _Route(this.name, {required this.includeAuto});

  final String name;
  final bool includeAuto;
}

void main() {
  final configUrl = Uri.base.resolve(
    '../../../build/web_tool_choice_grammar/config.json',
  );
  Map<String, dynamic>? config;
  String? notRunReason;
  final modelFacts = <String, Object?>{};
  final assetFacts = <String, Map<String, Object?>>{};
  final assetNotRun = <String, String>{};
  late JSFunction constructor;
  late JSObject prototype;
  late JSFunction originalCreateCompletion;

  Uri fixture(String key) => configUrl.resolve(config![key] as String);
  String asset(String key, String name) =>
      fixture(key).resolve(name).toString();

  void failIfNotRun([String? routeReason]) {
    final reason = notRunReason ?? routeReason;
    if (reason == null) return;
    fail('NOT_RUN: $reason');
  }

  Future<String> sha256(JSArrayBuffer bytes) async {
    final digest =
        (await window.crypto.subtle.digest('SHA-256'.toJS, bytes).toDart)
            as JSArrayBuffer;
    return digest.toDart
        .asUint8List()
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  Future<JSArrayBuffer?> fetchBytes(String url) async {
    final response = await window.fetch(url.toJS).toDart;
    return response.ok ? await response.arrayBuffer().toDart : null;
  }

  Future<void> verifyAssets(String key) async {
    if (config![key] == null) {
      assetNotRun[key] = 'config has no "$key"';
      return;
    }
    final manifestBytes = await fetchBytes(asset(key, 'manifest.json'));
    if (manifestBytes == null) {
      assetNotRun[key] = '$key has no manifest.json';
      return;
    }
    final manifest =
        jsonDecode(utf8.decode(manifestBytes.toDart.asUint8List()))
            as Map<String, dynamic>;
    final artifacts = manifest['artifacts'] as Map<String, dynamic>;
    final shas = <String, String>{};
    for (final name in const [
      'llama_webgpu_bridge.js',
      'llama_webgpu_bridge_worker.js',
      'llama_webgpu_core.js',
      'llama_webgpu_core.wasm',
      'llama_webgpu_core_mem64.js',
      'llama_webgpu_core_mem64.wasm',
    ]) {
      final expected = (artifacts[name] as Map?)?['sha256'];
      final bytes = await fetchBytes(asset(key, name));
      if (expected == null || bytes == null) {
        assetNotRun[key] = '$key $name is missing from the manifest or disk';
        return;
      }
      final actual = await sha256(bytes);
      if (actual != expected) {
        assetNotRun[key] =
            'hash mismatch: $key $name is $actual, manifest says $expected';
        return;
      }
      shas[name] = actual;
    }
    assetFacts[key] = {
      'assetsTag': manifest['bridge_assets_tag'],
      'bridgeCommit': manifest['bridge_commit'],
      'bridgeJsSha256': shas['llama_webgpu_bridge.js'],
      'coreWasm32Sha256': shas['llama_webgpu_core.wasm'],
      'coreWasm64Sha256': shas['llama_webgpu_core_mem64.wasm'],
    };
  }

  setUpAll(() async {
    final response = await window.fetch(configUrl.toString().toJS).toDart;
    if (!response.ok) {
      notRunReason = 'missing config $configUrl';
      return;
    }
    config =
        jsonDecode((await response.text().toDart).toDart)
            as Map<String, dynamic>;
    if (config!['assets'] == null || config!['model'] == null) {
      notRunReason = 'config needs "assets" and "model"';
      return;
    }
    final modelBytes = await fetchBytes(fixture('model').toString());
    if (modelBytes == null) {
      notRunReason = 'missing model ${fixture('model')}';
      return;
    }
    final actualSha = await sha256(modelBytes);
    if (actualSha != _pinnedModelSha256) {
      notRunReason =
          'model sha mismatch: $actualSha, expected $_pinnedModelSha256';
      return;
    }
    modelFacts['modelSha256'] = actualSha;
    modelFacts['modelBytes'] = modelBytes.toDart.lengthInBytes;
    await verifyAssets('assets');
    await verifyAssets('legacyAssets');
    if (assetNotRun['assets'] != null) {
      notRunReason = assetNotRun['assets'];
      return;
    }
    final module = await importModule(
      asset('assets', 'llama_webgpu_bridge.js').toJS,
    ).toDart;
    constructor = module['LlamaWebGpuBridge']! as JSFunction;
    prototype = constructor['prototype']! as JSObject;
    originalCreateCompletion = prototype['createCompletion']! as JSFunction;
  });

  LlamaEngine bridgeEngine(
    String assets,
    JSFunction bridgeConstructor,
    _Recorder recorder, {
    required bool worker,
  }) => LlamaEngine(
    WebGpuLlamaBackend(
      bridgeFactory: ([_]) => recorder.wrap(
        bridgeConstructor.callAsConstructor<LlamaWebGpuBridge>(
          JSObject()
            ..['disableWorker'] = (!worker).toJS
            ..['workerUrl'] = asset(
              assets,
              'llama_webgpu_bridge_worker.js',
            ).toJS
            ..['coreModuleUrl'] = asset(assets, 'llama_webgpu_core.js').toJS
            ..['wasmUrl'] = asset(assets, 'llama_webgpu_core.wasm').toJS,
        ),
      ),
    ),
  );

  Future<_Outcome> run(
    LlamaEngine engine,
    _Recorder recorder,
    List<LlamaChatMessage> messages, {
    ToolChoice? toolChoice,
    List<ToolDefinition>? tools,
    GenerationParams params = _params,
    bool strip = false,
    String? swap,
  }) async {
    final before = recorder.calls.length;
    recorder.stripGrammar = strip;
    recorder.swapGrammar = swap;
    Object? error;
    LlamaCompletion? completion;
    try {
      completion = await engine.complete(
        messages,
        tools: tools ?? [_weather],
        toolChoice: toolChoice,
        enableThinking: false,
        params: params,
      );
    } catch (e) {
      error = e;
    } finally {
      recorder.stripGrammar = false;
      recorder.swapGrammar = null;
    }
    await recorder.settle();
    return _Outcome(completion, error, recorder.calls.sublist(before));
  }

  void expectCall(_Outcome outcome, {String? city}) {
    expect(outcome.error, isNull);
    expect(outcome.toolCalls, hasLength(1), reason: outcome.raw);
    expect(outcome.toolCalls.single.name, _tool);
    if (city != null) {
      expect(outcome.toolCalls.single.arguments['city'], city);
    }
    expect(outcome.completion?.finishReason, LlamaFinishReason.toolCalls);
    expect(outcome.raw, contains(_callStart));
    expect(outcome.raw, contains(_tool));
  }

  void expectNoCall(_Outcome outcome) {
    expect(outcome.error, isNull);
    expect(outcome.toolCalls, isEmpty, reason: outcome.raw);
    expect(outcome.raw, isNot(contains(_callStart)), reason: outcome.raw);
  }

  /// Defines the `ToolChoice` cases for one engine. [open] loads the model
  /// and returns the engine and recorder, or a route NOT_RUN reason.
  void defineRoute(
    _Route route,
    String assets, {
    required Future<(LlamaEngine, _Recorder, String?)> Function() open,
    Future<void> Function()? close,
    bool legacy = false,
  }) {
    group(route.name, () {
      LlamaEngine? engine;
      late _Recorder recorder;
      String? routeNotRun;
      final results = <String, Object?>{};
      var binding = <String, Object?>{};

      setUpAll(() async {
        if (notRunReason != null) return;
        routeNotRun = assetNotRun[assets];
        if (routeNotRun != null) return;
        final opened = await open();
        engine = opened.$1;
        recorder = opened.$2;
        routeNotRun = opened.$3;
        if (routeNotRun != null) return;
        final metadata = await engine!.getMetadata();
        binding = {
          'execution': metadata['llamadart.webgpu.execution'],
          'coreVariant': metadata['llamadart.webgpu.core_variant'],
          'workerFallback': metadata['llamadart.webgpu.worker_fallback_reason'],
          'supportsLazyGrammar':
              (await engine!.capabilities).supportsLazyGrammar,
        };
        if (legacy && assetFacts[assets]?['assetsTag'] != _legacyAssetsTag) {
          routeNotRun =
              'legacy assets are ${assetFacts[assets]?['assetsTag']}, '
              'not $_legacyAssetsTag';
        }
      });

      tearDownAll(() async {
        if (engine != null) {
          await engine!.dispose();
          await close?.call();
        }
        if (notRunReason != null || routeNotRun != null) return;
        final facts = assetFacts[assets];
        final coreKey = binding['coreVariant'] == 'wasm64'
            ? 'coreWasm64Sha256'
            : 'coreWasm32Sha256';
        final receipt = {
          'route': route.name,
          'results': results,
          'binding': binding,
          ...?facts,
          'coreWasmSha256': facts?[coreKey],
          ...modelFacts,
          'penalty': recorder.calls.isEmpty
              ? null
              : recorder.calls.first.penalty,
          'userAgent': window.navigator.userAgent,
        };
        print('WEB_TOOL_CHOICE_RECEIPT ${jsonEncode(receipt)}');
      });

      void caseTest(String name, Future<Object?> Function() body) {
        test(name, () async {
          failIfNotRun(routeNotRun);
          results[name] = 'FAIL';
          results[name] = await body() ?? 'PASS';
        });
      }

      Future<Object?> requiredWithControl() async {
        final forced = await run(
          engine!,
          recorder,
          _textPrompt,
          toolChoice: ToolChoice.required,
        );
        expectCall(forced);
        expect(forced.calls.single.hasGrammar, isTrue);
        expect(forced.calls.single.grammarLazy, isNot(true));
        final control = await run(
          engine!,
          recorder,
          _textPrompt,
          toolChoice: ToolChoice.required,
          strip: true,
        );
        expect(control.calls.single.stripped, isTrue);
        final controlCall = control.calls.single;
        if (controlCall.error != null || (controlCall.raw ?? '').isEmpty) {
          fail(
            'NOT_RUN: control on ${route.name} did not generate: '
            '${controlCall.error ?? 'empty output'}',
          );
        }
        if (control.toolCalls.isNotEmpty || control.raw.contains(_callStart)) {
          fail(
            'NOT_RUN: indecisive control on ${route.name}: the model called '
            'the tool without the grammar',
          );
        }
        return null;
      }

      if (!legacy) {
        caseTest('text without tools', () async {
          final outcome = await run(
            engine!,
            recorder,
            _textPrompt,
            tools: const [],
          );
          expect(outcome.error, isNull);
          expect(outcome.text.toLowerCase(), contains('hello'));
          expect(outcome.toolCalls, isEmpty);
          expect(outcome.calls.single.hasGrammar, isFalse);
          return null;
        });
        caseTest('none with a tool prompt', () async {
          final outcome = await run(
            engine!,
            recorder,
            _toolPrompt,
            toolChoice: ToolChoice.none,
          );
          expectNoCall(outcome);
          expect(outcome.calls.single.hasGrammar, isFalse);
          return null;
        });
        caseTest(
          'required with a no-call prompt and causal control',
          requiredWithControl,
        );
        caseTest('required with the Paris prompt', () async {
          final outcome = await run(
            engine!,
            recorder,
            _toolPrompt,
            toolChoice: ToolChoice.required,
          );
          expectCall(outcome, city: 'Paris');
          return null;
        });
        caseTest('required cut off before the call completes', () async {
          final outcome = await run(
            engine!,
            recorder,
            _toolPrompt,
            toolChoice: ToolChoice.required,
            params: _params.copyWith(maxTokens: 6),
          );
          expect(outcome.error, isNull);
          expect(outcome.toolCalls, isEmpty);
          expect(outcome.completion?.finishReason, LlamaFinishReason.length);
          expect(outcome.raw, startsWith(_callStart));
          expect(outcome.raw, isNot(contains(_callEnd)));
          return null;
        });
        caseTest('required with a malformed forced call', () async {
          final outcome = await run(
            engine!,
            recorder,
            _toolPrompt,
            toolChoice: ToolChoice.required,
            swap: 'root ::= ${jsonEncode(_malformedCall)}',
          );
          expect(outcome.error, isNull);
          expect(outcome.raw, startsWith(_callStart));
          expect(outcome.toolCalls, isEmpty);
          return null;
        });
        if (route.includeAuto) {
          caseTest('auto with the Paris prompt', () async {
            final outcome = await run(
              engine!,
              recorder,
              _toolPrompt,
              toolChoice: ToolChoice.auto,
            );
            expectCall(outcome, city: 'Paris');
            expect(outcome.calls.single.hasGrammar, isTrue);
            expect(outcome.calls.single.grammarLazy, isTrue);
            return null;
          });
          caseTest('auto with a text prompt', () async {
            final outcome = await run(
              engine!,
              recorder,
              _textPrompt,
              toolChoice: ToolChoice.auto,
            );
            expectNoCall(outcome);
            expect(outcome.text.toLowerCase(), contains('hello'));
            return null;
          });
          caseTest('auto after a tool result', () async {
            final outcome = await run(
              engine!,
              recorder,
              _toolResultPrompt,
              toolChoice: ToolChoice.auto,
            );
            expectNoCall(outcome);
            expect(outcome.text, contains('17'));
            return null;
          });
        }
      } else {
        caseTest('auto refuses before any bridge call', () async {
          final outcome = await run(
            engine!,
            recorder,
            _toolPrompt,
            toolChoice: ToolChoice.auto,
          );
          expect(outcome.error, isA<LlamaUnsupportedException>());
          expect(outcome.calls, isEmpty);
          return null;
        });
        caseTest(
          'required with a no-call prompt and causal control',
          requiredWithControl,
        );
      }
    });
  }

  for (final worker in [false, true]) {
    defineRoute(
      _Route(worker ? 'worker' : 'direct', includeAuto: true),
      'assets',
      open: () async {
        final recorder = _Recorder();
        final engine = bridgeEngine(
          'assets',
          constructor,
          recorder,
          worker: worker,
        );
        await engine.loadModelFromUrl(
          fixture('model').toString(),
          modelParams: _modelParams,
        );
        final metadata = await engine.getMetadata();
        final fallback = metadata['llamadart.webgpu.worker_fallback_reason'];
        final fellBack =
            worker &&
            (metadata['llamadart.webgpu.execution'] != 'worker' ||
                fallback != null);
        return (
          engine,
          recorder,
          fellBack
              ? 'worker route fell back to '
                    '${metadata['llamadart.webgpu.execution']}: $fallback'
              : null,
        );
      },
    );
  }

  defineRoute(
    const _Route('default', includeAuto: true),
    'assets',
    open: () async {
      final recorder = _Recorder();
      prototype['createCompletion'] =
          ((JSObject self, JSAny? prompt, JSObject options) => recorder
                  .intercept(originalCreateCompletion, self, prompt, options))
              .toJSCaptureThis;
      globalContext['LlamaWebGpuBridge'] = constructor;
      for (final (name, file) in const [
        ('CoreModuleUrl', 'llama_webgpu_core.js'),
        ('WasmUrl', 'llama_webgpu_core.wasm'),
        ('CoreModuleUrlMem64', 'llama_webgpu_core_mem64.js'),
        ('WasmUrlMem64', 'llama_webgpu_core_mem64.wasm'),
        ('WorkerUrl', 'llama_webgpu_bridge_worker.js'),
      ]) {
        globalContext['__llamadartBridge$name'] = asset('assets', file).toJS;
      }
      final engine = LlamaEngine(LlamaBackend());
      await engine.loadModelFromUrl(
        fixture('model').toString(),
        modelParams: _modelParams,
      );
      return (engine, recorder, null);
    },
    close: () async {
      prototype['createCompletion'] = originalCreateCompletion;
      for (final name in const [
        'CoreModuleUrl',
        'WasmUrl',
        'CoreModuleUrlMem64',
        'WasmUrlMem64',
        'WorkerUrl',
      ]) {
        globalContext.delete('__llamadartBridge$name'.toJS);
      }
      globalContext.delete('LlamaWebGpuBridge'.toJS);
    },
  );

  defineRoute(
    const _Route('legacy direct', includeAuto: false),
    'legacyAssets',
    legacy: true,
    open: () async {
      final recorder = _Recorder();
      final module = await importModule(
        asset('legacyAssets', 'llama_webgpu_bridge.js').toJS,
      ).toDart;
      final engine = bridgeEngine(
        'legacyAssets',
        module['LlamaWebGpuBridge']! as JSFunction,
        recorder,
        worker: false,
      );
      await engine.loadModelFromUrl(
        fixture('model').toString(),
        modelParams: _modelParams,
      );
      return (engine, recorder, null);
    },
  );
}
