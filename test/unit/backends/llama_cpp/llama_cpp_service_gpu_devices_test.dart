@TestOn('vm')
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/backends/llama_cpp/bindings.dart';
import 'package:llamadart/src/backends/llama_cpp/exit_teardown_api.dart';
import 'package:llamadart/src/backends/llama_cpp/llama_cpp_service.dart';
import 'package:llamadart/src/backends/llama_cpp/load_device_selection.dart';
import 'package:llamadart/src/backends/llama_cpp/vulkan_device_probe.dart';
import 'package:test/test.dart';

import '../../../support/recording_exit_teardown.dart';
import '../../../support/synthetic_embedding_gguf.dart';

const _load = 'llama_dart_model_load_from_file';
final int _gpu = ggml_backend_dev_type.GGML_BACKEND_DEVICE_TYPE_GPU.value;

GgmlDeviceEntry _fake(String name, String registry, int address) =>
    GgmlDeviceEntry(
      name: name,
      registry: registry,
      description: name,
      type: _gpu,
      device: Pointer.fromAddress(address),
    );

// Fake devices must never reach llama.cpp: each such test is refused before
// the load. The real-device test loads the synthetic model on this host's
// first GPU.
void main() {
  late Directory dir;
  late String model;
  late RecordingExitTeardown recorder;
  late LlamaCppService service;

  void start({
    List<GgmlDeviceEntry> Function()? registeredDevices,
    VulkanDeviceProbe probe = const VulkanDeviceProbe.unavailable('test'),
  }) {
    recorder = RecordingExitTeardown(
      ExitTeardownApi.tryResolve(isWindows: Platform.isWindows)!,
    );
    service = LlamaCppService(
      objectCalls: LlamaCppObjectCalls.tracked(
        recorder.api,
        isWindows: Platform.isWindows,
      ),
      registeredDevices: registeredDevices,
      vulkanDeviceProbe: () => probe,
    )..initializeBackend();
  }

  Matcher refused(Object message) => throwsA(
    isA<LlamaUnsupportedException>().having(
      (e) => e.message,
      'message',
      allOf(contains('llama.cpp multi-GPU placement'), message),
    ),
  );

  setUp(() {
    dir = Directory.systemTemp.createTempSync('llamadart_gpu_devices_');
    model = writeSyntheticLlamaGguf('${dir.path}/model.gguf').path;
  });

  tearDown(() {
    service.dispose();
    dir.deleteSync(recursive: true);
  });

  test('a device index the host does not have is refused before the '
      'load', () {
    start(registeredDevices: () => [_fake('CUDA0', 'CUDA', 0x1000)]);
    expect(
      () => service.loadModel(model, const ModelParams(gpuDevices: [0, 1])),
      refused(contains('this host has 1 (CUDA0)')),
    );
    expect(recorder.calls, isNot(contains(_load)));
  });

  test('a split for another device count is refused before the load', () {
    start(
      registeredDevices: () => [
        _fake('CUDA0', 'CUDA', 0x1000),
        _fake('CUDA1', 'CUDA', 0x2000),
      ],
    );
    expect(
      () => service.loadModel(model, const ModelParams(tensorSplit: [1])),
      refused(contains('tensorSplit holds 1 proportions')),
    );
    expect(recorder.calls, isNot(contains(_load)));
  });

  test('several GPU backends under auto are refused before the load', () {
    start(
      registeredDevices: () => [
        _fake('CUDA0', 'CUDA', 0x1000),
        _fake('Vulkan0', 'Vulkan', 0x2000),
      ],
    );
    expect(
      () => service.loadModel(model, const ModelParams(gpuDevices: [0])),
      refused(contains('more than one GPU backend')),
    );
    expect(recorder.calls, isNot(contains(_load)));
  });

  test('a listed Vulkan device ggml-vulkan cannot drive is refused instead '
      'of left out', () {
    const vulkan11 = 1 << 22 | 1 << 12;
    start(
      registeredDevices: () => [
        _fake('Vulkan0', 'Vulkan', 0x1000),
        _fake('Vulkan1', 'Vulkan', 0x2000),
      ],
      probe: const VulkanDeviceProbe.devices([
        VulkanDeviceFacts(
          name: 'Vulkan0',
          deviceType: 2,
          instanceApiVersion: VulkanDeviceFacts.vulkan12,
          apiVersion: vulkan11,
          subgroupSize: 32,
        ),
        VulkanDeviceFacts(
          name: 'Vulkan1',
          deviceType: 2,
          instanceApiVersion: VulkanDeviceFacts.vulkan12,
          apiVersion: VulkanDeviceFacts.vulkan12,
          subgroupSize: 32,
        ),
      ]),
    );
    expect(
      () => service.loadModel(model, const ModelParams(gpuDevices: [0])),
      refused(contains('Vulkan 1.2')),
    );
    expect(recorder.calls, isNot(contains(_load)));
  });

  test('a load that falls back to the CPU is refused instead', () {
    const vulkan11 = 1 << 22 | 1 << 12;
    start(
      registeredDevices: () => [_fake('Vulkan0', 'Vulkan', 0x1000)],
      probe: const VulkanDeviceProbe.devices([
        VulkanDeviceFacts(
          name: 'Vulkan0',
          deviceType: 2,
          instanceApiVersion: VulkanDeviceFacts.vulkan12,
          apiVersion: vulkan11,
          subgroupSize: 32,
        ),
      ]),
    );
    expect(
      () => service.loadModel(model, const ModelParams(tensorSplit: [1])),
      refused(allOf(contains('no usable GPU'), contains('run on the CPU'))),
    );
    expect(recorder.calls, isNot(contains(_load)));
  });

  test('the listed devices and split reach llama.cpp and the backend '
      'name', () {
    start();
    final gpus = service.listGpuDevices();
    if (gpus.isEmpty) {
      markTestSkipped('No GPU device on this host.');
      return;
    }
    final first = gpus.first;
    final oneBackend = gpus.every(
      (gpu) =>
          gpu.backend == first.backend || gpu.type == GpuDeviceType.accelerator,
    );
    // Under auto without a list llama.cpp picks the devices itself, so the
    // load lists none; the placement must list the chosen one.
    service.loadModel(
      model,
      ModelParams(
        preferredBackend: oneBackend ? GpuBackend.auto : first.backend,
        gpuDevices: const [0],
        tensorSplit: const [2],
      ),
    );
    expect(recorder.loadDevices.single, hasLength(1));
    expect(recorder.loadDevices.single, isNot(contains(0)));
    expect(recorder.loadTensorSplits.single, [2.0]);
    expect(service.getActiveBackendName(), endsWith('(${first.name})'));

    service.loadModel(model, const ModelParams());
    expect(recorder.loadTensorSplits.last, isNull);
  });

  test(
    'a speculative draft model loads on the target devices and split',
    () async {
      start();
      final gpus = service.listGpuDevices();
      if (gpus.isEmpty) {
        markTestSkipped('No GPU device on this host.');
        return;
      }
      final params = ModelParams(
        contextSize: 256,
        preferredBackend: gpus.first.backend,
        gpuDevices: const [0],
        tensorSplit: const [2],
      );
      final target = service.loadModel(model, params);
      final context = service.createContext(target, params);
      final cancel = calloc<Int8>();
      try {
        await service
            .generate(
              context,
              'abababab',
              GenerationParams(
                maxTokens: 4,
                temp: 0,
                penalty: 1,
                speculativeDecodingConfig:
                    SpeculativeDecodingConfig.draftSimple(
                      // ignore: deprecated_member_use_from_same_package
                      draftModelPath: model,
                      draftTokenMax: 2,
                    ),
              ),
              cancel.address,
            )
            .drain<void>();
      } finally {
        calloc.free(cancel);
      }
      expect(recorder.loadDevices, hasLength(2));
      expect(recorder.loadDevices.last, recorder.loadDevices.first);
      expect(recorder.loadTensorSplits, [
        [2.0],
        [2.0],
      ]);
    },
  );
}
