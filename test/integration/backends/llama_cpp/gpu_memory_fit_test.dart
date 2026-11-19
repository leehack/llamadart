@TestOn('vm')
@Tags(['local-only'])
@Timeout(Duration(minutes: 10))
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:llamadart/llamadart.dart';
import 'package:test/test.dart';

Future<GpuDeviceInfo?> _selectGpu(LlamaEngine engine) async {
  final gpus = await engine.listGpuDevices(
    probeBackends: const [
      GpuBackend.vulkan,
      GpuBackend.cuda,
      GpuBackend.hip,
      GpuBackend.opencl,
    ],
  );
  if (gpus.isEmpty) {
    markTestSkipped('No GPU device on this host.');
    return null;
  }
  return gpus.first;
}

LlamaCppModelParams _params(
  GpuDeviceInfo gpu, {
  GpuMemoryFit? fit,
  ComputeDevice device = ComputeDevice.auto,
}) => LlamaCppModelParams(
  contextSize: 2048,
  numberOfThreads: 2,
  numberOfThreadsBatch: 2,
  device: device,
  preferredBackend: gpu.backend,
  gpuDevices: [gpu.mainGpu],
  gpuMemoryFit: fit,
);

Future<GpuMemoryFitDevice?> _measureGpuBaseline(
  LlamaEngine engine,
  String model,
  GpuDeviceInfo gpu,
) async {
  try {
    await engine.loadModel(
      model,
      modelParams: _params(gpu, fit: const GpuMemoryFit(marginBytes: 0)),
    );
  } on LlamaUnsupportedException catch (error) {
    if (error.message.contains('llama_dart_fit_params')) {
      markTestSkipped('This runtime does not export the GPU memory fit.');
      return null;
    }
    rethrow;
  }

  final baseline = await engine.getGpuMemoryFitReport();
  expect(baseline, isNotNull);
  expect(baseline!.devices.map((device) => device.name), [gpu.name]);
  final device = baseline.devices.single;
  expect(device.totalBytes, greaterThan(0));
  await engine.unloadModel();
  return device;
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
    final gpu = await _selectGpu(engine);
    if (gpu == null) return;
    final baseline = await _measureGpuBaseline(engine, model!, gpu);
    if (baseline == null) return;

    expect(baseline.modelBytes, greaterThan(0));
    // Size the budget from the fitted load so the overhead scales even for
    // small models, and keep room for the measured compute buffers.
    final budget =
        baseline.computeBytes +
        (baseline.modelBytes + baseline.contextBytes) ~/ 2;
    await engine.loadModel(
      model,
      modelParams: _params(
        gpu,
        fit: GpuMemoryFit(
          marginBytes: math.max(baseline.freeBytes - budget, 0),
        ),
      ),
    );

    final report = (await engine.getGpuMemoryFitReport())!;
    print(report);
    expect(report.devices.map((device) => device.name), [gpu.name]);
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
      final gpu = await _selectGpu(engine);
      if (gpu == null) return;
      final baseline = await _measureGpuBaseline(engine, model!, gpu);
      if (baseline == null) return;

      LlamaGpuMemoryFitException? caught;
      try {
        await engine.loadModel(
          model,
          modelParams: _params(
            gpu,
            device: ComputeDevice.gpu,
            fit: GpuMemoryFit(marginBytes: baseline.totalBytes),
          ),
        );
        fail('Expected LlamaGpuMemoryFitException when reserving the GPU.');
      } on LlamaGpuMemoryFitException catch (error) {
        caught = error;
      }

      final report = caught.report;
      print(report);
      expect(report, isNotNull);
      expect(report!.outcome, GpuMemoryFitOutcome.cpu);
      expect(report.gpuLayers, 0);
      expect(report.devices.map((device) => device.name), [gpu.name]);
      expect(report.devices.single.modelBytes, 0);

      await engine.loadModel(model, modelParams: _params(gpu));
      expect(await engine.getResolvedGpuLayers(), greaterThan(0));
    },
  );
}
