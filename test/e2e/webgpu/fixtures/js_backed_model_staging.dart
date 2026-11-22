import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:llamadart/llamadart.dart';

void main() {
  globalContext['runJsBackedModelStaging'] = ((JSObject options) => _run(
    options,
  ).toJS).toJS;
}

Future<JSString> _run(JSObject options) async {
  final modelUrl = (options['modelUrl'] as JSString).toDart;
  final mmprojUrl = (options['mmprojUrl'] as JSString?)?.toDart;
  final staging = (options['jsBackedModelStaging'] as JSBoolean?)?.toDart;
  final preferMemory64 = (options['preferMemory64'] as JSBoolean).toDart;
  final gpu = (options['gpu'] as JSBoolean).toDart;
  final cancelDuringLoad = (options['cancelDuringLoad'] as JSBoolean).toDart;
  final reuse = (options['reuse'] as JSBoolean).toDart;
  final model = LlamaModel(ModelSource.parse(modelUrl));
  final params = LlamaCppModelParams(
    contextSize: 512,
    device: gpu ? ComputeDevice.gpu : ComputeDevice.cpu,
    gpuLayers: gpu ? ModelParams.maxGpuLayers : 0,
    numberOfThreads: 2,
    numberOfThreadsBatch: 2,
    preferMemory64: preferMemory64,
    jsBackedModelStaging: staging,
  );

  final engine = LlamaEngine(LlamaBackend());
  var cancelled = false;
  try {
    Future<Map<String, String?>> loadAndGenerate({bool cancel = false}) async {
      await engine.setModel(
        model,
        params: params,
        onProgress: cancel
            ? (progress) {
                final fraction = progress.fraction;
                if (!cancelled &&
                    fraction != null &&
                    fraction > 0 &&
                    fraction < 1) {
                  cancelled = true;
                  engine.cancelGeneration();
                }
              }
            : null,
      );
      if (mmprojUrl != null) {
        await engine.loadMultimodalProjectorSource(
          ModelSource.parse(mmprojUrl),
        );
      }
      final output = await engine
          .generate(
            'Once upon a time',
            params: const GenerationParams(maxTokens: 8, temp: 0, seed: 7),
          )
          .join();
      final metadata = await engine.getMetadata();
      return {
        'output': output,
        for (final key in [
          'core_variant',
          'execution',
          'worker_fallback_reason',
          'runtime_notes',
          'model_bytes',
          'model_source',
          'mmproj_loaded',
          'backends',
        ])
          key: metadata['llamadart.webgpu.$key'],
      };
    }

    final Map<String, String?> first;
    try {
      first = await loadAndGenerate(cancel: cancelDuringLoad);
    } on LlamaModelException catch (error) {
      if (!cancelled || !cancelDuringLoad) rethrow;
      if (!error.toString().toLowerCase().contains('cancel')) rethrow;
      return jsonEncode({
        'cancelled': true,
        'reloaded': await loadAndGenerate(),
      }).toJS;
    }

    if (!reuse) return jsonEncode(first).toJS;
    await engine.unloadModel();
    return jsonEncode({...first, 'reloaded': await loadAndGenerate()}).toJS;
  } on LlamaUnsupportedException catch (error) {
    return jsonEncode({'unsupported': error.message}).toJS;
  } on LlamaModelException catch (error) {
    return jsonEncode({'model_error': error.toString()}).toJS;
  } catch (error) {
    return jsonEncode({'error': error.toString()}).toJS;
  } finally {
    await engine.dispose();
  }
}
