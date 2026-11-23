import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/backends/webgpu/interop.dart';
import 'package:llamadart/src/backends/webgpu/webgpu_backend.dart';
import 'package:web/web.dart' show DedicatedWorkerGlobalScope;

const _modelParams = ModelParams(
  contextSize: 512,
  gpuLayers: 0,
  preferredBackend: GpuBackend.cpu,
  numberOfThreads: 2,
  numberOfThreadsBatch: 2,
);

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
    final mode = script.queryParameters['mode'];
    final configuredModel = Uri.parse(config['model'] as String);
    if (configuredModel.hasScheme || configuredModel.hasAuthority) {
      throw StateError('Stage a worker-relative model URL in config.json');
    }
    final relativeModel = configuredModel.replace(
      queryParameters: {
        ...configuredModel.queryParameters,
        'worker-cache-test': mode,
        if (mode == 'sensitive') 'token': 'synthetic-worker-cache-test',
      },
    );
    final model = script.resolveUri(relativeModel);
    final reference = mode == 'relative' || mode == 'sensitive'
        ? relativeModel
        : model;
    final assets = script.resolve(config['assets'] as String);
    String asset(String file) => assets.resolve(file).toString();
    final module = await importModule(
      asset('llama_webgpu_bridge.js').toJS,
    ).toDart;
    final constructor = module['LlamaWebGpuBridge']! as JSFunction;
    LlamaWebGpuBridge createBridge() =>
        constructor.callAsConstructor<LlamaWebGpuBridge>(
          JSObject()
            ..['disableWorker'] = true.toJS
            ..['coreModuleUrl'] = asset('llama_webgpu_core.js').toJS
            ..['wasmUrl'] = asset('llama_webgpu_core.wasm').toJS,
        );
    if (mode == 'forced-fetch') {
      worker.postMessage(
        jsonEncode({'loads': await _forceFetchLoads(createBridge, model)}).toJS,
      );
      return;
    }

    final cache = await worker.caches
        .open('llamadart-webgpu-model-cache-v1')
        .toDart;
    final cacheKey = model.toString().toJS;
    await cache.delete(cacheKey).toDart;

    final loads = <Map<String, Object?>>[];
    try {
      for (var i = 0; i < 2; i++) {
        final engine = LlamaEngine(
          WebGpuLlamaBackend(bridgeFactory: ([_]) => createBridge()),
        );
        try {
          await engine.loadModelFromUrl(
            reference.toString(),
            modelParams: _modelParams,
          );
          final metadata = await engine.getMetadata();
          loads.add({
            'cached': (await cache.match(cacheKey).toDart) != null,
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

Future<List<Map<String, Object?>>> _forceFetchLoads(
  LlamaWebGpuBridge Function() createBridge,
  Uri model,
) async {
  globalContext['__llamadartBridgeForceRemoteFetchBackend'] = true.toJS;
  late LlamaWebGpuBridge bridge;
  final backend = WebGpuLlamaBackend(
    bridgeFactory: ([_]) => bridge = createBridge(),
  );
  JSAny? originalCore;
  final loads = <Map<String, Object?>>[];
  try {
    // Freeing the backend between loads would also free the core and hide
    // exhaustion of its four-thread pool.
    for (var i = 0; i < 6; i++) {
      final handle = await backend
          .modelLoadFromUrl(model.toString(), _modelParams)
          .timeout(const Duration(seconds: 20));
      final runtime = (bridge as JSObject)['_runtime'] as JSObject;
      final core = runtime['_core'];
      originalCore ??= core;
      if (core == null || !identical(core, originalCore)) {
        throw StateError('Load ${i + 1} did not reuse the original Wasm core');
      }
      final metadata = await backend.modelMetadata(handle);
      final source = metadata['llamadart.webgpu.model_source'];
      if (source != 'network-fetch') {
        throw StateError(
          'Load ${i + 1} used $source. '
          '${metadata['llamadart.webgpu.runtime_notes']}',
        );
      }
      loads.add({
        'source': source,
        'tokens': await backend.tokenize(handle, 'Hello'),
      });
    }
    return loads;
  } finally {
    await backend.dispose();
  }
}
