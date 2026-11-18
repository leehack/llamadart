@TestOn('vm')
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/backends/llama_cpp/bindings.dart';
import 'package:llamadart/src/backends/llama_cpp/gpu_memory_fit.dart';
import 'package:llamadart/src/backends/llama_cpp/llama_cpp_backend.dart';
import 'package:llamadart/src/backends/llama_cpp/llama_cpp_service.dart';
import 'package:llamadart/src/backends/llama_cpp/load_device_selection.dart';
import 'package:llamadart/src/backends/llama_cpp/vulkan_device_probe.dart';
import 'package:llamadart/src/backends/llama_cpp/worker.dart';
import 'package:test/test.dart';

import '../../../support/synthetic_embedding_gguf.dart';

final int _gpu = ggml_backend_dev_type.GGML_BACKEND_DEVICE_TYPE_GPU.value;

void _workerWith(
  SendPort port,
  GpuMemoryFitNativeResult Function(GpuMemoryFitRequest) runner,
) {
  final cuda = GgmlDeviceEntry(
    name: 'CUDA0',
    registry: 'CUDA',
    description: 'CUDA0',
    type: _gpu,
    device: Pointer.fromAddress(0x1000),
  );
  runLlamaWorkerForTesting(
    port,
    LlamaCppService(
      isMacosX64: false,
      operatingSystem: 'linux',
      gpuMemoryFitRunner: () => runner,
      registeredDevices: () => [cuda],
      vulkanDeviceProbe: () => const VulkanDeviceProbe.unavailable('test'),
      linuxVulkanProbe: () => null,
      backendDevices: (_) => [cuda.device!],
      deviceTypes: (_) => [_gpu],
    ),
  );
}

void _failingFitWorker(SendPort port) => _workerWith(
  port,
  (_) => const GpuMemoryFitNativeResult(
    status: GpuMemoryFitStatus.failure,
    error: 'native says no',
  ),
);

void _nothingFitsWorker(SendPort port) => _workerWith(port, (request) {
  request.modelParams.ref.n_gpu_layers = 0;
  return const GpuMemoryFitNativeResult(
    status: GpuMemoryFitStatus.success,
    offloadableLayers: 28,
    devices: [
      GpuMemoryFitDevice(
        name: 'CUDA0',
        freeBytes: 1 << 20,
        totalBytes: 1 << 30,
        modelBytes: 1 << 30,
        contextBytes: 1 << 20,
        computeBytes: 1 << 20,
      ),
    ],
  );
});

const _params = ModelParams(
  contextSize: 512,
  device: ComputeDevice.gpu,
  preferredBackend: GpuBackend.cuda,
  gpuMemoryFit: GpuMemoryFit(),
);

void main() {
  late Directory dir;
  late String model;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('llamadart_fit_boundary_');
    model = writeSyntheticLlamaGguf('${dir.path}/m.gguf').path;
  });

  tearDown(() => dir.deleteSync(recursive: true));

  test('a failed fit reaches the backend caller with its status', () async {
    final backend = NativeLlamaBackend(workerEntrypoint: _failingFitWorker);
    addTearDown(backend.dispose);

    await expectLater(
      backend.modelLoad(model, _params),
      throwsA(
        isA<LlamaGpuMemoryFitException>()
            .having((e) => e.message, 'message', contains('native says no'))
            .having((e) => e.details, 'details', 'failure')
            .having((e) => e.report, 'report', isNull),
      ),
    );
  });

  test('nothing fitting under ComputeDevice.gpu carries the report', () async {
    final backend = NativeLlamaBackend(workerEntrypoint: _nothingFitsWorker);
    addTearDown(backend.dispose);

    await expectLater(
      backend.modelLoad(model, _params),
      throwsA(
        isA<LlamaGpuMemoryFitException>().having(
          (e) => e.report,
          'report',
          isA<GpuMemoryFitReport>()
              .having((r) => r.outcome, 'outcome', GpuMemoryFitOutcome.cpu)
              .having((r) => r.modelLayers, 'modelLayers', 29)
              .having(
                (r) => r.marginBytes,
                'marginBytes',
                _params.gpuMemoryFit!.marginBytes,
              )
              .having((r) => r.devices.single.name, 'device', 'CUDA0')
              .having((r) => r.devices.single.freeBytes, 'free', 1 << 20),
        ),
      ),
    );
  });

  test('LlamaEngine.loadModel surfaces the typed fit exception', () async {
    final engine = LlamaEngine(
      NativeLlamaBackend(workerEntrypoint: _nothingFitsWorker),
    );
    addTearDown(engine.dispose);

    await expectLater(
      engine.loadModel(model, modelParams: _params),
      throwsA(
        isA<LlamaGpuMemoryFitException>().having(
          (e) => e.report?.outcome,
          'report.outcome',
          GpuMemoryFitOutcome.cpu,
        ),
      ),
    );
  });
}
