@TestOn('vm')
@Tags(['local-only'])
@Timeout(Duration(minutes: 10))
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:llamadart/llamadart.dart';
import 'package:test/test.dart';

const _gib = 1 << 30;

/// Loads a model on a Linux or Windows GPU with a margin that leaves only a
/// fraction of the free memory to the load, so the fit has to offload fewer
/// layers than the model has, and generates from the partial load.
void main() {
  final model = Platform.environment['LLAMADART_GPU_MODEL'];
  final skip = model == null
      ? 'Set LLAMADART_GPU_MODEL to a GGUF.'
      : Platform.isLinux || Platform.isWindows
      ? null
      : 'GPU memory fit applies to Linux and Windows loads.';

  test('a partial fit loads and generates', skip: skip, () async {
    final engine = LlamaEngine(LlamaBackend());
    addTearDown(engine.dispose);
    await engine.loadModel(model!, modelParams: const LlamaCppModelParams());
    final gpus = await engine.listGpuDevices();
    if (gpus.isEmpty) {
      markTestSkipped('No GPU device on this host.');
      return;
    }
    final free = gpus.first.memoryFreeBytes;
    final modelBytes = File(model).lengthSync();
    await engine.unloadModel();

    final budget = modelBytes ~/ 2 + _gib ~/ 4;
    try {
      await engine.loadModel(
        model,
        modelParams: LlamaCppModelParams(
          contextSize: 2048,
          preferredBackend: gpus.first.backend,
          gpuMemoryFit: GpuMemoryFit(marginBytes: math.max(free - budget, 0)),
        ),
      );
    } on LlamaUnsupportedException catch (error) {
      if (error.message.contains('llama_dart_fit_params')) {
        markTestSkipped('This runtime does not export the GPU memory fit.');
        return;
      }
      rethrow;
    }

    final report = (await engine.getGpuMemoryFitReport())!;
    print(report);
    expect(report.outcome, GpuMemoryFitOutcome.reduced);
    expect(report.gpuLayers, inExclusiveRange(0, report.modelLayers));
    expect(await engine.getResolvedGpuLayers(), report.gpuLayers);
    final output = await engine
        .generate(
          'The capital of France is',
          params: const GenerationParams(maxTokens: 16, temp: 0),
        )
        .join();
    expect(output, isNotEmpty);
  });
}
