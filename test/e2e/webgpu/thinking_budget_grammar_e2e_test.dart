/// Real pinned-asset check that a response-format grammar stays applied
/// through a budgeted forced-open thought on Qwen3.5 (#1954).
///
/// Uses build/web_lazy_grammar/config.json, adding "reasoningModel" (a
/// Qwen3.5 GGUF) and, for the version-skew control, "legacyAssets" (bridge
/// assets without `thinkingBudgetPauseGrammar`, such as `v0.1.83`). Run the
/// web-lazy-grammar scenario.
@TestOn('browser')
@Tags(['local-only', 'e2e'])
@Timeout(Duration(minutes: 30))
library;

import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/backends/webgpu/interop.dart';
import 'package:llamadart/src/backends/webgpu/webgpu_backend.dart';
import 'package:test/test.dart';
import 'package:web/web.dart' show window;

const _messages = [
  LlamaChatMessage.fromText(
    role: LlamaChatRole.user,
    text: 'Give the capital of France as JSON {"city": ...}.',
  ),
];

const _responseFormat = {
  'type': 'json_schema',
  'json_schema': {
    'schema': {
      'type': 'object',
      'properties': {
        'city': {'type': 'string'},
      },
      'required': ['city'],
      'additionalProperties': false,
    },
  },
};

const _model = ModelParams(
  contextSize: 4096,
  gpuLayers: 0,
  preferredBackend: GpuBackend.cpu,
  numberOfThreads: 2,
  numberOfThreadsBatch: 2,
);

void main() {
  final configUrl = Uri.base.resolve(
    '../../../build/web_lazy_grammar/config.json',
  );
  late Map<String, dynamic> config;
  Uri fixture(String key) => configUrl.resolve(config[key] as String);

  Future<JSFunction> bridgeConstructor(String assets) async {
    final module = await importModule(
      fixture(assets).resolve('llama_webgpu_bridge.js').toString().toJS,
    ).toDart;
    return module['LlamaWebGpuBridge']! as JSFunction;
  }

  LlamaEngine newEngine(String assets, JSFunction constructor, bool worker) {
    String asset(String name) => fixture(assets).resolve(name).toString();
    return LlamaEngine(
      WebGpuLlamaBackend(
        bridgeFactory: ([_]) =>
            constructor.callAsConstructor<LlamaWebGpuBridge>(
              JSObject()
                ..['disableWorker'] = (!worker).toJS
                ..['workerUrl'] = asset('llama_webgpu_bridge_worker.js').toJS
                ..['coreModuleUrl'] = asset('llama_webgpu_core.js').toJS
                ..['wasmUrl'] = asset('llama_webgpu_core.wasm').toJS,
            ),
      ),
    );
  }

  Future<List<LlamaCompletionChunk>> run(
    LlamaEngine engine,
    ThinkingBudget? budget,
  ) => engine
      .create(
        _messages,
        params: GenerationParams(
          maxTokens: 1536,
          temp: 0,
          seed: 42,
          thinkingBudget: budget,
        ),
        enableThinking: true,
        responseFormat: _responseFormat,
      )
      .toList();

  String content(List<LlamaCompletionChunk> chunks) =>
      chunks.map((chunk) => chunk.choices.first.delta.content ?? '').join();

  setUpAll(() async {
    final response = await window.fetch(configUrl.toString().toJS).toDart;
    expect(response.ok, isTrue, reason: 'Missing $configUrl');
    config =
        jsonDecode((await response.text().toDart).toDart)
            as Map<String, dynamic>;
    expect(
      config['reasoningModel'],
      isNotNull,
      reason: 'Stage "reasoningModel" in the config',
    );
  });

  for (final worker in [false, true]) {
    test('${worker ? 'worker' : 'direct'}: constrained JSON survives a '
        'budgeted thought', () async {
      final engine = newEngine(
        'assets',
        await bridgeConstructor('assets'),
        worker,
      );
      addTearDown(engine.dispose);
      await engine.loadModelFromUrl(
        fixture('reasoningModel').toString(),
        modelParams: _model,
      );
      expect((await engine.capabilities).supportsThinkingBudget, isTrue);
      for (final tokens in [0, 1, 16]) {
        final text = content(
          await run(engine, ThinkingBudget(maxTokens: tokens)),
        );
        expect(jsonDecode(text), {
          'city': isA<String>(),
        }, reason: 'budget=$tokens content=${jsonEncode(text)}');
      }
    });
  }

  test('assets without thinkingBudgetPauseGrammar reject the budget instead '
      'of leaving the reply unconstrained', () async {
    if (config['legacyAssets'] == null) {
      markTestSkipped('Stage "legacyAssets" for the version-skew control');
      return;
    }
    final engine = newEngine(
      'legacyAssets',
      await bridgeConstructor('legacyAssets'),
      false,
    );
    addTearDown(engine.dispose);
    await engine.loadModelFromUrl(
      fixture('reasoningModel').toString(),
      modelParams: _model,
    );
    expect(jsonDecode(content(await run(engine, null))), {
      'city': isA<String>(),
    });
    await expectLater(
      run(engine, const ThinkingBudget(maxTokens: 4)),
      throwsA(
        isA<LlamaUnsupportedException>().having(
          (error) => error.message,
          'message',
          allOf(contains('thinkingBudgetPauseGrammar'), contains('v0.1.84+')),
        ),
      ),
    );
  });
}
