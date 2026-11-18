@TestOn('vm')
@Tags(['local-only'])
@Timeout(Duration(minutes: 10))
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:llamadart/llamadart.dart';
import 'package:test/test.dart';

const _gib = 1 << 30;

Future<({GpuBackend backend, int freeBytes})?> _measureGpuBaseline(
  LlamaEngine engine,
  String model,
) async {
  try {
    await engine.loadModel(
      model,
      modelParams: const LlamaCppModelParams(
        contextSize: 2048,
        gpuMemoryFit: GpuMemoryFit(marginBytes: 0),
      ),
    );
  } on LlamaUnsupportedException catch (error) {
    if (error.message.contains('llama_dart_fit_params')) {
      markTestSkipped('This runtime does not export the GPU memory fit.');
      return null;
    }
    rethrow;
  }

  final gpus = await engine.listGpuDevices();
  if (gpus.isEmpty) {
    markTestSkipped('No GPU device on this host.');
    return null;
  }
  final baseline = await engine.getGpuMemoryFitReport();
  if (baseline == null || baseline.devices.isEmpty) {
    markTestSkipped('GPU memory fit did not report any device.');
    return null;
  }
  final maxFreeBytes = baseline.devices
      .map((device) => device.freeBytes)
      .reduce(math.max);
  await engine.unloadModel();
  return (backend: gpus.first.backend, freeBytes: maxFreeBytes);
}

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
    final baseline = await _measureGpuBaseline(engine, model!);
    if (baseline == null) return;

    final modelBytes = File(model).lengthSync();
    final budget = modelBytes ~/ 2 + _gib ~/ 4;
    await engine.loadModel(
      model,
      modelParams: LlamaCppModelParams(
        contextSize: 2048,
        preferredBackend: baseline.backend,
        gpuMemoryFit: GpuMemoryFit(
          marginBytes: math.max(baseline.freeBytes - budget, 0),
        ),
      ),
    );

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

  test(
    'ComputeDevice.gpu throws LlamaGpuMemoryFitException when nothing fits',
    skip: skip,
    () async {
      final engine = LlamaEngine(LlamaBackend());
      addTearDown(engine.dispose);
      final baseline = await _measureGpuBaseline(engine, model!);
      if (baseline == null) return;

      LlamaGpuMemoryFitException? caught;
      try {
        await engine.loadModel(
          model,
          modelParams: LlamaCppModelParams(
            contextSize: 2048,
            device: ComputeDevice.gpu,
            preferredBackend: baseline.backend,
            gpuMemoryFit: GpuMemoryFit(marginBytes: baseline.freeBytes + _gib),
          ),
        );
        fail('Expected LlamaGpuMemoryFitException when margin exceeds free.');
      } on LlamaGpuMemoryFitException catch (error) {
        caught = error;
      }

      final report = caught.report;
      print(report);
      expect(report, isNotNull);
      expect(report!.outcome, GpuMemoryFitOutcome.cpu);
      expect(report.gpuLayers, 0);

      await engine.loadModel(
        model,
        modelParams: LlamaCppModelParams(
          contextSize: 2048,
          preferredBackend: baseline.backend,
        ),
      );
      expect(await engine.getResolvedGpuLayers(), greaterThan(0));
    },
  );
}
