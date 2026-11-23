/// Real pinned-asset text generation at full WebGPU offload, compared with the
/// CPU Wasm runtime, in direct and worker runtimes (#1025).
///
/// Stage build/webgpu_generation_e2e/config.json with {"assets":"bridge/",
/// "model":"models/stories15M.gguf"} beside the pinned bridge files and the
/// model, then run the web-webgpu-generation scenario. The model must not be
/// one llamadart caps on WebGPU (Qwen3.5-0.8B).
@TestOn('browser')
@Tags(['local-only', 'e2e'])
@Timeout(Duration(minutes: 10))
library;

import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/backends/webgpu/interop.dart';
import 'package:llamadart/src/backends/webgpu/webgpu_backend.dart';
import 'package:test/test.dart';
import 'package:web/web.dart' show window;

const _greedy = GenerationParams(
  maxTokens: 32,
  temp: 0,
  topK: 1,
  topP: 1,
  penalty: 1,
  seed: 7,
);
const _prompt = 'Once upon a time';

void main() {
  final configUrl = Uri.base.resolve(
    '../../../build/webgpu_generation_e2e/config.json',
  );
  late Map<String, dynamic> config;
  late JSFunction constructor;
  String asset(String name) =>
      configUrl.resolve(config['assets'] as String).resolve(name).toString();

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

  Future<String> generate(bool worker, ModelParams params, int tokens) async {
    final engine = newEngine(worker);
    try {
      await engine.loadModelFromUrl(
        configUrl.resolve(config['model'] as String).toString(),
        modelParams: params,
      );
      final metadata = await engine.getMetadata();
      expect(
        metadata['llamadart.webgpu.execution'],
        worker ? 'worker' : 'main-thread',
      );
      if (params.device == ComputeDevice.gpu) {
        expect(await engine.getBackendName(), contains('WebGPU'));
        expect(metadata['llamadart.webgpu.n_gpu_layers'], '99');
      }
      final watch = Stopwatch()..start();
      final text = await engine
          .generate(_prompt, params: _greedy.copyWith(maxTokens: tokens))
          .join();
      print(
        'WEBGPU_GENERATION ${jsonEncode({'runtime': worker ? 'worker' : 'direct', 'device': params.device.name, 'backend': await engine.getBackendName(), 'tokens': tokens, 'ms': watch.elapsedMilliseconds, 'text': text})}',
      );
      return text;
    } finally {
      await engine.dispose();
    }
  }

  setUpAll(() async {
    final response = await window.fetch(configUrl.toString().toJS).toDart;
    expect(response.ok, isTrue, reason: 'Missing $configUrl');
    config =
        jsonDecode((await response.text().toDart).toDart)
            as Map<String, dynamic>;
    final module = await importModule(
      asset('llama_webgpu_bridge.js').toJS,
    ).toDart;
    constructor = module['LlamaWebGpuBridge']! as JSFunction;
    final adapter = await _adapterInfo();
    print('WEBGPU_ADAPTER ${jsonEncode(adapter)}');
    expect(
      adapter['error'],
      isNull,
      reason: 'This test needs a WebGPU adapter.',
    );
  });

  for (final worker in [false, true]) {
    test('${worker ? 'worker' : 'direct'} full WebGPU offload generates the '
        'CPU runtime text', () async {
      const cpu = ModelParams(
        contextSize: 512,
        gpuLayers: 0,
        device: ComputeDevice.cpu,
        numberOfThreads: 2,
        numberOfThreadsBatch: 2,
      );
      const gpu = ModelParams(
        contextSize: 512,
        gpuLayers: 99,
        device: ComputeDevice.gpu,
        numberOfThreads: 2,
        numberOfThreadsBatch: 2,
      );
      // Greedy text can diverge late across GPU drivers, so the gate is the
      // first tokens; the full runs are recorded for the qualification table.
      final cpuHead = await generate(worker, cpu, 8);
      final gpuHead = await generate(worker, gpu, 8);
      expect(gpuHead, isNotEmpty);
      expect(gpuHead, isNot(contains('�')));
      expect(gpuHead, cpuHead);
      final cpuText = await generate(worker, cpu, 32);
      final gpuText = await generate(worker, gpu, 32);
      expect(gpuText, isNot(contains('�')));
      print(
        'WEBGPU_GENERATION_MATCH ${jsonEncode({'runtime': worker ? 'worker' : 'direct', 'fullTextEqual': gpuText == cpuText})}',
      );
    });
  }
}

Future<Map<String, Object?>> _adapterInfo() async {
  final gpu = (window as JSObject)
      .getProperty<JSObject?>('navigator'.toJS)
      ?.getProperty<JSAny?>('gpu'.toJS);
  if (gpu == null || !gpu.isA<JSObject>()) return {'error': 'no navigator.gpu'};
  final adapter = await (gpu as JSObject)
      .callMethod<JSPromise<JSAny?>>('requestAdapter'.toJS)
      .toDart;
  if (adapter == null) return {'error': 'no adapter'};
  final info = (adapter as JSObject).getProperty<JSObject?>('info'.toJS);
  String? field(String name) =>
      (info?.getProperty<JSAny?>(name.toJS) as JSString?)?.toDart;
  return {
    'vendor': field('vendor'),
    'architecture': field('architecture'),
    'device': field('device'),
    'description': field('description'),
  };
}
