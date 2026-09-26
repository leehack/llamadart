/// Real-asset check of the capability-gated WebGPU bridge options: Min-P,
/// presence penalty, thinking budget and runtime LoRA adapters.
///
/// The test runner serves the package root, so the bridge, its workers and
/// the models are same-origin when they sit under `build/webgpu_features_e2e/`
/// (gitignored) with this `config.json`, whose paths are relative to it:
///
/// ```json
/// {
///   "expectFeatures": true,
///   "bridge": "bridge/llama_webgpu_bridge.js",
///   "storiesModel": "models/stories15M_MOE-Q8_0.gguf",
///   "loraAdapter": "models/moe_shakespeare15M.gguf",
///   "aloraAdapter": "models/moe_shakespeare15M-alora.gguf",
///   "mismatchModel": "models/llama-2-tiny-random.gguf",
///   "reasoningModel": "models/Qwen3.5-0.8B-Q4_K_M.gguf"
/// }
/// ```
///
/// `bridge` holds the bridge assets, such as a llama-web-bridge
/// `scripts/build_bridge.sh` `OUT_DIR`. The models are `ggml-org/stories15M_MOE`
/// with its `moe_shakespeare15M` adapter, the same adapter with an
/// `adapter.alora.invocation_tokens` array (llama-web-bridge
/// `scripts/lora_adapter_browser_smoke.mjs`, `withAloraInvocationTokens`),
/// `aladar/llama-2-tiny-random-GGUF` and `unsloth/Qwen3.5-0.8B-GGUF`. Set
/// `expectFeatures` to false for bridge assets without the capabilities:
/// every option must then be rejected, and default generation still works.
/// The test page is not cross-origin isolated, so point `CHROME_EXECUTABLE`
/// at a wrapper that starts Chrome with
/// `--enable-features=SharedArrayBuffer,SharedArrayBufferUnrestrictedAccessAllowed`,
/// which the bridge core's threads need, then run `dart test -p chrome
/// --run-skipped -t local-only
/// test/e2e/webgpu/generation_features_e2e_test.dart`.
@TestOn('browser')
@Tags(['local-only', 'e2e'])
library;

import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/backends/webgpu/webgpu_backend.dart';
import 'package:test/test.dart';
import 'package:web/web.dart' show window;

const String _configPath = '../../../build/webgpu_features_e2e/config.json';

const String _storiesPrompt = 'Once upon a time';

const String _reasoningPrompt =
    '<|im_start|>user\nWhat is 8 + 9? Answer with a number.<|im_end|>\n'
    '<|im_start|>assistant\n<think>\n';

const GenerationParams _greedy = GenerationParams(
  maxTokens: 32,
  temp: 0,
  topK: 1,
  seed: 7,
);

const GenerationParams _seeded = GenerationParams(maxTokens: 32, seed: 7);

const ModelParams _cpu = ModelParams(
  contextSize: 1024,
  gpuLayers: 0,
  preferredBackend: GpuBackend.cpu,
);

void main() {
  final configUrl = Uri.base.resolve(_configPath);
  late Map<String, Object?> config;
  late LlamaEngine engine;

  bool expectFeatures() => config['expectFeatures'] == true;
  String url(String key) =>
      configUrl.resolve(config[key]! as String).toString();

  Future<String> generate(String prompt, GenerationParams params) =>
      engine.generate(prompt, params: params).join();

  void report(String name, Object? value) {
    print('[webgpu-features] $name: ${jsonEncode(value)}');
  }

  setUpAll(() async {
    final response = await window.fetch(configUrl.toString().toJS).toDart;
    expect(response.ok, isTrue, reason: 'Missing $configUrl');
    config =
        jsonDecode((await response.text().toDart).toDart)
            as Map<String, Object?>;
    final bridgeModule = await importModule(url('bridge').toJS).toDart;
    globalContext['LlamaWebGpuBridge'] = bridgeModule['LlamaWebGpuBridge'];
    engine = LlamaEngine(WebGpuLlamaBackend());
  });

  tearDownAll(() => engine.dispose());

  group('stories15M', () {
    setUpAll(
      () => engine.loadModelFromUrl(url('storiesModel'), modelParams: _cpu),
    );
    tearDownAll(() => engine.unloadModel());

    test('default generation is deterministic', () async {
      final greedy = await generate(_storiesPrompt, _greedy);
      final seeded = await generate(_storiesPrompt, _seeded);
      report('greedy', greedy);
      report('seeded', seeded);
      expect(greedy, isNotEmpty);
      expect(await generate(_storiesPrompt, _greedy), greedy);
      expect(await generate(_storiesPrompt, _seeded), seeded);
      expect(
        await generate(
          _storiesPrompt,
          _seeded.copyWith(minP: 0, presencePenalty: 0),
        ),
        seeded,
      );
    });

    test('Min-P', () async {
      final seeded = await generate(_storiesPrompt, _seeded);
      if (!expectFeatures()) {
        await expectLater(
          generate(_storiesPrompt, _seeded.copyWith(minP: 0.3)),
          throwsA(isA<LlamaUnsupportedException>()),
        );
        return;
      }
      final minP = await generate(_storiesPrompt, _seeded.copyWith(minP: 0.3));
      final minPOne = await generate(_storiesPrompt, _seeded.copyWith(minP: 1));
      report('seeded minP 0.3', minP);
      report('seeded minP 1', minPOne);
      expect(minP, isNot(seeded));
      expect(minPOne, await generate(_storiesPrompt, _greedy));
    });

    test('presence penalty', () async {
      if (!expectFeatures()) {
        await expectLater(
          generate(_storiesPrompt, _greedy.copyWith(presencePenalty: 1.5)),
          throwsA(isA<LlamaUnsupportedException>()),
        );
        return;
      }
      final greedy = await generate(_storiesPrompt, _greedy);
      final penalized = await generate(
        _storiesPrompt,
        _greedy.copyWith(presencePenalty: 1.5),
      );
      report('greedy presencePenalty 1.5', penalized);
      expect(penalized, isNot(greedy));
    });

    test('a stop sequence equal to a preserved token does not stop', () async {
      final greedy = await generate(_storiesPrompt, _greedy);
      expect(greedy, contains('.'));
      final stopped = await generate(
        _storiesPrompt,
        _greedy.copyWith(stopSequences: <String>['.']),
      );
      final preserved = await generate(
        _storiesPrompt,
        _greedy.copyWith(
          stopSequences: <String>['.'],
          preservedTokens: <String>['.'],
        ),
      );
      report('greedy stop "."', stopped);
      report('greedy stop "." preserved "."', preserved);
      expect(stopped, greedy.substring(0, greedy.indexOf('.')));
      expect(preserved, greedy);
    });

    test('LoRA adapters', () async {
      if (!expectFeatures()) {
        for (final call in <Future<void> Function()>[
          () => engine.setLora(url('loraAdapter')),
          () => engine.removeLora(url('loraAdapter')),
          engine.clearLoras,
        ]) {
          await expectLater(call(), throwsA(isA<LlamaUnsupportedException>()));
        }
        return;
      }
      final base = await generate(_storiesPrompt, _greedy);

      await engine.setLora(url('loraAdapter'));
      final adapted = await generate(_storiesPrompt, _greedy);
      report('greedy with adapter', adapted);
      expect(adapted, isNot(base));

      await engine.setLora(url('loraAdapter'), scale: 0);
      expect(await generate(_storiesPrompt, _greedy), base);
      await engine.setLora(url('loraAdapter'), scale: 1);
      expect(await generate(_storiesPrompt, _greedy), adapted);

      await engine.clearLoras();
      expect(await generate(_storiesPrompt, _greedy), base);

      await engine.setLora(url('loraAdapter'));
      await engine.removeLora(url('loraAdapter'));
      expect(await generate(_storiesPrompt, _greedy), base);

      await expectLater(
        engine.setLora(url('aloraAdapter')),
        throwsA(
          isA<LlamaUnsupportedException>().having(
            (error) => error.message,
            'message',
            contains('aLoRA adapter'),
          ),
        ),
      );
      expect(await generate(_storiesPrompt, _greedy), base);
    });

    test('LoRA adapter for another base model', () async {
      if (!expectFeatures()) return;
      await engine.unloadModel();
      await engine.loadModelFromUrl(url('mismatchModel'), modelParams: _cpu);
      await expectLater(
        engine.setLora(url('loraAdapter')),
        throwsA(
          isA<LlamaModelException>().having(
            (error) => error.message,
            'message',
            contains('wrong base model'),
          ),
        ),
      );
      expect(await generate(_storiesPrompt, _greedy), isNotEmpty);
      await engine.unloadModel();
      await engine.loadModelFromUrl(url('storiesModel'), modelParams: _cpu);
    });
  });

  group('Qwen3.5 thinking budget', () {
    setUpAll(
      () => engine.loadModelFromUrl(url('reasoningModel'), modelParams: _cpu),
    );

    const params = GenerationParams(maxTokens: 24, temp: 0, topK: 1, seed: 7);

    test('caps thinking and forces the end tag', () async {
      final unbudgeted = await generate(_reasoningPrompt, params);
      report('unbudgeted', unbudgeted);
      const budget = ThinkingBudget(
        maxTokens: 8,
        startTag: '<think>',
        endTag: '</think>',
      );
      if (!expectFeatures()) {
        await expectLater(
          generate(_reasoningPrompt, params.copyWith(thinkingBudget: budget)),
          throwsA(isA<LlamaUnsupportedException>()),
        );
        return;
      }
      expect(unbudgeted, isNot(contains('</think>')));

      final budgeted = await generate(
        _reasoningPrompt,
        params.copyWith(thinkingBudget: budget),
      );
      final forced = await generate(
        _reasoningPrompt,
        params.copyWith(
          thinkingBudget: const ThinkingBudget(
            maxTokens: 0,
            startTag: '<think>',
            endTag: '</think>',
            forcedMessage: 'Done.',
          ),
        ),
      );
      report('maxTokens 8', budgeted);
      report('maxTokens 0 forcedMessage Done.', forced);

      final end = budgeted.indexOf('</think>');
      expect(end, greaterThan(0));
      expect(unbudgeted, startsWith(budgeted.substring(0, end)));
      expect(forced, startsWith('Done.</think>'));
    });
  });
}
