import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/backends/webgpu/interop.dart';
import 'package:llamadart/src/backends/webgpu/webgpu_backend.dart';
import 'package:web/web.dart' show DedicatedWorkerGlobalScope;

Future<void> main() async {
  final worker = globalContext as DedicatedWorkerGlobalScope;
  try {
    final script = Uri.parse(worker.location.href);
    final response = await worker
        .fetch(script.resolve('config.json').toString().toJS)
        .toDart;
    if (!response.ok) throw StateError('Could not read worker test config');
    final config =
        jsonDecode((await response.text().toDart).toDart)
            as Map<String, dynamic>;
    final mode = script.queryParameters['modelUrl'];
    final configuredModel = Uri.parse(config['model'] as String);
    if (configuredModel.hasScheme || configuredModel.hasAuthority) {
      throw StateError('Stage a worker-relative model URL in config.json');
    }
    final relativeModel = configuredModel.replace(
      queryParameters: {
        ...configuredModel.queryParameters,
        'worker-cache-test': mode,
      },
    );
    final model = script.resolveUri(relativeModel);
    final reference = mode == 'relative' ? relativeModel : model;
    final assets = script.resolve(config['assets'] as String);
    String asset(String file) => assets.resolve(file).toString();
    final module = await importModule(
      asset('llama_webgpu_bridge.js').toJS,
    ).toDart;
    final constructor = module['LlamaWebGpuBridge']! as JSFunction;
    final cache = await worker.caches
        .open('llamadart-webgpu-model-cache-v1')
        .toDart;
    final cacheKey = model.toString().toJS;
    await cache.delete(cacheKey).toDart;

    final loads = <Map<String, Object?>>[];
    try {
      for (var i = 0; i < 2; i++) {
        final engine = LlamaEngine(
          WebGpuLlamaBackend(
            bridgeFactory: ([_]) {
              return constructor.callAsConstructor<LlamaWebGpuBridge>(
                JSObject()
                  ..['disableWorker'] = true.toJS
                  ..['coreModuleUrl'] = asset('llama_webgpu_core.js').toJS
                  ..['wasmUrl'] = asset('llama_webgpu_core.wasm').toJS,
              );
            },
          ),
        );
        try {
          await engine.loadModelFromUrl(
            reference.toString(),
            modelParams: const ModelParams(
              contextSize: 512,
              gpuLayers: 0,
              preferredBackend: GpuBackend.cpu,
              numberOfThreads: 2,
              numberOfThreadsBatch: 2,
            ),
          );
          final metadata = await engine.getMetadata();
          loads.add({
            'notes': metadata['llamadart.webgpu.runtime_notes'],
            'tokens': await engine.tokenize('Hello'),
          });
        } finally {
          await engine.dispose();
        }
      }
    } finally {
      await cache.delete(cacheKey).toDart;
    }
    worker.postMessage(jsonEncode({'loads': loads}).toJS);
  } catch (error, stack) {
    worker.postMessage(jsonEncode({'error': '$error\n$stack'}).toJS);
  }
}
