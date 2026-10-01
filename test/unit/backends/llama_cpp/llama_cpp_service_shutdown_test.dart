@TestOn('vm')
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:test/test.dart';

import 'package:llamadart/src/backends/isolate_shutdown_releases.dart';
import 'package:llamadart/src/backends/llama_cpp/bindings.dart';
import 'package:llamadart/src/backends/llama_cpp/ggml_graph_api.dart';
import 'package:llamadart/src/backends/llama_cpp/llama_cpp_service.dart';
import 'package:llamadart/src/core/models/inference/model_params.dart';

import '../../../support/synthetic_decision_head.dart';
import '../../../support/synthetic_embedding_gguf.dart';

// Runs the real llama.cpp runtime on the CPU in spawned isolates, which free
// what they leave loaded when they exit.
void main() {
  late _Paths paths;

  setUp(() {
    final directory = Directory.systemTemp.createTempSync('llama_shutdown_');
    addTearDown(() => directory.deleteSync(recursive: true));
    paths = _Paths(directory.path);
  });

  test('holds each object it creates with its free function and stage, '
      'which the isolate exit frees', () async {
    final p = paths;
    final held = await Isolate.run(() {
      _load(LlamaCppService()..initializeBackend(), p);
      return _describeHeld();
    });

    expect(held, [
      'llama_model_free model',
      'llama_free context',
      'llama_free context',
      'llama_model_free model',
      // The decision head: its encoder context, then its runtime.
      'llama_free context',
      'ggml_backend_free backend',
      'ggml_backend_buffer_free modelUser',
      'ggml_backend_sched_free scheduler',
    ]);
  });

  test('releases each hold when its object is freed', () async {
    final p = paths;
    final counts = await Isolate.run(() {
      final releases = IsolateShutdownReleases.current;
      int held() => releases.debugHeldForTesting.length;
      final service = LlamaCppService()..initializeBackend();
      final loaded = _load(service, p);
      final counts = <int>[];
      service.freeDecisionHead(loaded.head);
      counts.add(held());
      service.freeContext(loaded.context);
      counts.add(held());
      service.freeModel(loaded.model);
      counts.add(held());
      service.freeModel(loaded.encoder);
      counts.add(held());
      return counts;
    });

    expect(counts, [4, 3, 1, 0]);
  });

  test('releases every hold when the service is disposed', () async {
    final p = paths;
    final held = await Isolate.run(() {
      final service = LlamaCppService()..initializeBackend();
      _load(service, p);
      service.dispose();
      return IsolateShutdownReleases.current.debugHeldForTesting.length;
    });

    expect(held, 0);
  });
}

final class _Paths {
  _Paths(String directory)
    : model = '$directory/model.gguf',
      encoder = '$directory/encoder.gguf',
      head = '$directory/head.safetensors',
      config = '$directory/config.json' {
    writeSyntheticLlamaGguf(model);
    writeSyntheticModernBertGguf(encoder, decisionTokens: true);
    SyntheticDecisionHead(d: 16, layers: 1, seed: 1).write(head);
    File(config).writeAsStringSync('{"max_len": 64, "head_layers": 1}');
  }

  final String model;
  final String encoder;
  final String head;
  final String config;
}

({int model, int context, int encoder, int head}) _load(
  LlamaCppService service,
  _Paths paths,
) {
  const params = ModelParams(gpuLayers: 0, contextSize: 64);
  final model = service.loadModel(paths.model, params);
  final context = service.createContext(model, params);
  service.createContext(model, params);
  final encoder = service.loadModel(paths.encoder, params);
  final head = service
      .loadDecisionHead(encoder, paths.head, paths.config)
      .handle;
  return (model: model, context: context, encoder: encoder, head: head);
}

List<String> _describeHeld() {
  final names = {
    Native.addressOf<NativeFunction<Void Function(Pointer<llama_model>)>>(
      llama_model_free,
    ).address: 'llama_model_free',
    Native.addressOf<NativeFunction<Void Function(Pointer<llama_context>)>>(
      llama_free,
    ).address: 'llama_free',
    ggmlFreeAddresses.backendFree.address: 'ggml_backend_free',
    ggmlFreeAddresses.bufferFree.address: 'ggml_backend_buffer_free',
    ggmlFreeAddresses.schedFree.address: 'ggml_backend_sched_free',
  };
  return [
    for (final (:free, :stage)
        in IsolateShutdownReleases.current.debugHeldForTesting)
      '${names[free.address] ?? free.address} ${stage.name}',
  ];
}
