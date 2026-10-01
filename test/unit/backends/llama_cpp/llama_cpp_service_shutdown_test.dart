@TestOn('vm')
library;

import 'dart:io';
import 'dart:isolate';

import 'package:test/test.dart';

import 'package:llamadart/src/backends/isolate_shutdown_releases.dart';
import 'package:llamadart/src/backends/llama_cpp/llama_cpp_service.dart';
import 'package:llamadart/src/core/models/inference/model_params.dart';

import '../../../support/synthetic_embedding_gguf.dart';

// Runs the real llama.cpp runtime on the CPU in a spawned isolate. What it
// leaves loaded is freed when the isolate shuts down; freeing an object twice,
// or a model before its context, would crash the test process.
void main() {
  late String modelPath;

  setUp(() {
    final directory = Directory.systemTemp.createTempSync('llama_shutdown_');
    addTearDown(() => directory.deleteSync(recursive: true));
    modelPath = '${directory.path}/model.gguf';
    writeSyntheticLlamaGguf(modelPath);
  });

  test('holds the model and contexts it loads, which the isolate exit '
      'frees', () async {
    final path = modelPath;
    final held = await Isolate.run(() {
      _load(LlamaCppService()..initializeBackend(), path);
      return IsolateShutdownReleases.current.debugHeldCountForTesting;
    });

    expect(held, 3);
  });

  test('releases each hold when its object is freed', () async {
    final path = modelPath;
    final counts = await Isolate.run(() {
      final releases = IsolateShutdownReleases.current;
      final service = LlamaCppService()..initializeBackend();
      final (:model, :context) = _load(service, path);
      service.freeContext(context);
      final afterFreeContext = releases.debugHeldCountForTesting;
      service.freeModel(model);
      return [afterFreeContext, releases.debugHeldCountForTesting];
    });

    expect(counts, [2, 0]);
  });

  test('releases every hold when the service is disposed', () async {
    final path = modelPath;
    final held = await Isolate.run(() {
      final service = LlamaCppService()..initializeBackend();
      _load(service, path);
      service.dispose();
      return IsolateShutdownReleases.current.debugHeldCountForTesting;
    });

    expect(held, 0);
  });
}

({int model, int context}) _load(LlamaCppService service, String path) {
  const params = ModelParams(gpuLayers: 0, contextSize: 64);
  final model = service.loadModel(path, params);
  final context = service.createContext(model, params);
  service.createContext(model, params);
  return (model: model, context: context);
}
