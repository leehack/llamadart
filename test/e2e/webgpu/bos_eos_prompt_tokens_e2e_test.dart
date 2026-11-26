/// Pinned-asset BOS/EOS metadata and prompt tokenization against the ids an
/// unmodified llama-server returns, in direct and worker runtimes (#1989).
/// Each staged file must be a fixture model of the same name; verify its
/// `model_sha256` with `shasum -a 256` before the run.
///
/// Stage build/web_bos_eos_prompt_tokens/config.json with {"assets":"bridge/",
/// "models":["models/LFM2-VL-450M-Q4_0.gguf",
/// "models/gemma-3-1b-it-Q4_K_M.gguf"]} beside the pinned bridge files and the
/// models, then run the web-bos-eos-prompt-tokens scenario. Every model must
/// be one of test/fixtures/bos_eos_prompt_tokens_upstream.json.
@TestOn('browser')
@Tags(['local-only', 'e2e'])
@Timeout(Duration(minutes: 20))
library;

import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/backends/webgpu/interop.dart';
import 'package:llamadart/src/backends/webgpu/webgpu_backend.dart';
import 'package:test/test.dart';
import 'package:web/web.dart' show window;

void main() {
  final configUrl = Uri.base.resolve(
    '../../../build/web_bos_eos_prompt_tokens/config.json',
  );
  final fixtureUrl = Uri.base.resolve(
    '../../fixtures/bos_eos_prompt_tokens_upstream.json',
  );
  late Map<String, dynamic> config;
  late Map<String, dynamic> fixture;
  late JSFunction constructor;
  String asset(String name) =>
      configUrl.resolve(config['assets'] as String).resolve(name).toString();

  Future<String> fetchText(Uri url) async {
    final response = await window.fetch(url.toString().toJS).toDart;
    expect(response.ok, isTrue, reason: 'Missing $url');
    return (await response.text().toDart).toDart;
  }

  LlamaEngine newEngine(bool worker) => LlamaEngine(
    WebGpuLlamaBackend(
      bridgeFactory: ([_]) => constructor.callAsConstructor<LlamaWebGpuBridge>(
        JSObject()
          ..['disableWorker'] = (!worker).toJS
          ..['workerUrl'] = asset('llama_webgpu_bridge_worker.js').toJS
          ..['coreModuleUrl'] = asset('llama_webgpu_core.js').toJS
          ..['wasmUrl'] = asset('llama_webgpu_core.wasm').toJS,
      ),
    ),
  );

  setUpAll(() async {
    config = jsonDecode(await fetchText(configUrl)) as Map<String, dynamic>;
    fixture = jsonDecode(await fetchText(fixtureUrl)) as Map<String, dynamic>;
    final module = await importModule(
      asset('llama_webgpu_bridge.js').toJS,
    ).toDart;
    constructor = module['LlamaWebGpuBridge']! as JSFunction;
  });

  test('stages at least one fixture model', () {
    expect(config['models'], isNotEmpty);
  });

  for (final worker in [false, true]) {
    test('${worker ? 'worker' : 'direct'} runtime reports BOS and EOS and '
        'renders and tokenizes prompts as llama-server does', () async {
      final fixtureModels = {
        for (final model
            in (fixture['models'] as List).cast<Map<String, dynamic>>())
          model['model'] as String: model,
      };
      final scenarios = fixture['scenarios'] as Map<String, dynamic>;

      for (final staged in (config['models'] as List).cast<String>()) {
        final modelUrl = configUrl.resolve(staged);
        final name = staged.split('/').last;
        final model = fixtureModels[name];
        if (model == null) fail('$name is not in the fixture');

        final engine = newEngine(worker);
        try {
          await engine.loadModelFromUrl(
            modelUrl.toString(),
            modelParams: const ModelParams(
              contextSize: 512,
              gpuLayers: 0,
              device: ComputeDevice.cpu,
              numberOfThreads: 2,
              numberOfThreadsBatch: 2,
            ),
          );

          final metadata = await engine.getMetadata();
          expect(
            metadata['tokenizer.ggml.bos_token'],
            model['bos_token'],
            reason: name,
          );
          expect(
            metadata['tokenizer.ggml.eos_token'],
            model['eos_token'],
            reason: name,
          );

          final cases = model['cases'] as Map<String, dynamic>;
          for (final MapEntry(key: scenario, value: upstream)
              in cases.entries) {
            final rendered = await engine.chatTemplate([
              for (final message
                  in (scenarios[scenario] as List).cast<Map<String, dynamic>>())
                LlamaChatMessage.fromText(
                  role: LlamaChatRole.values.byName(message['role'] as String),
                  text: message['content'] as String,
                ),
            ]);
            // llama-server drops the leading BOS text of a vocabulary that
            // adds BOS itself; the engine keeps it for the bridge to strip.
            final bos = model['bos_token'] as String;
            expect(
              rendered.prompt.startsWith(bos)
                  ? rendered.prompt.substring(bos.length)
                  : rendered.prompt,
              (upstream as Map<String, dynamic>)['prompt'],
              reason: '$name $scenario prompt',
            );
            expect(
              await engine.tokenize(rendered.prompt),
              upstream['tokens'],
              reason: '$name $scenario',
            );
          }
        } finally {
          await engine.dispose();
        }
      }
    });
  }
}
