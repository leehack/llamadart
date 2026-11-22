import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:llamadart/llamadart.dart';

void main() {
  globalContext['runSingleThreadCore'] =
      ((String modelUrl, bool preferMemory64, bool gpu) => _run(
        modelUrl,
        preferMemory64,
        gpu,
      ).toJS).toJS;
}

Future<JSString> _run(String modelUrl, bool preferMemory64, bool gpu) async {
  final engine = LlamaEngine(LlamaBackend());
  try {
    await engine.loadModelFromUrl(
      modelUrl,
      modelParams: ModelParams(
        contextSize: 512,
        device: gpu ? ComputeDevice.gpu : ComputeDevice.cpu,
        gpuLayers: gpu ? 99 : 0,
        numberOfThreads: 2,
        numberOfThreadsBatch: 2,
        preferMemory64: preferMemory64,
      ),
    );
    final output = await engine
        .generate(
          'Once upon a time',
          params: const GenerationParams(maxTokens: 8, temp: 0, seed: 7),
        )
        .join();
    final metadata = await engine.getMetadata();
    return jsonEncode({
      'output': output,
      for (final key in [
        'core_variant',
        'execution',
        'worker_fallback_reason',
        'runtime_notes',
        'model_bytes',
        'model_source',
        'n_threads',
        'n_threads_batch',
        'backends',
      ])
        key: metadata['llamadart.webgpu.$key'],
    }).toJS;
  } on LlamaUnsupportedException catch (error) {
    return jsonEncode({'unsupported': error.message}).toJS;
  } catch (error) {
    return jsonEncode({'error': error.toString()}).toJS;
  } finally {
    await engine.dispose();
  }
}
