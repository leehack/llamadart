@TestOn('vm')
library;

import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/backends/llama_cpp/bindings.dart';
import 'package:llamadart/src/backends/llama_cpp/gpu_device_placement.dart';
import 'package:llamadart/src/backends/llama_cpp/llama_cpp_service.dart';
import 'package:llamadart/src/backends/llama_cpp/load_device_selection.dart';
import 'package:test/test.dart';

final int _gpu = ggml_backend_dev_type.GGML_BACKEND_DEVICE_TYPE_GPU.value;
final int _igpu = ggml_backend_dev_type.GGML_BACKEND_DEVICE_TYPE_IGPU.value;
final int _cpu = ggml_backend_dev_type.GGML_BACKEND_DEVICE_TYPE_CPU.value;

GgmlDeviceEntry _device(String name, String registry, {int? type}) =>
    GgmlDeviceEntry(name: name, registry: registry, type: type ?? _gpu);

final _cuda0 = _device('CUDA0', 'CUDA');
final _cuda1 = _device('CUDA1', 'CUDA');
final _cuda2 = _device('CUDA2', 'CUDA');
final _vulkan0 = _device('Vulkan0', 'Vulkan');
final _vulkan1 = _device('Vulkan1', 'Vulkan');
final _host = _device('CPU', 'CPU', type: _cpu);

void main() {
  GpuDevicePlacement? resolve(
    ModelParams params, {
    GpuBackend backend = GpuBackend.cuda,
    List<GgmlDeviceEntry>? registered,
    int maxDevices = 16,
  }) => resolveGpuDevicePlacement(
    params,
    backend: backend,
    registered: registered ?? [_host, _cuda0, _vulkan0, _cuda1, _cuda2],
    backendOf: LlamaCppService.gpuBackendFromRegName,
    maxDevices: maxDevices,
    platform: 'linux',
  );

  Matcher unsupported(Object message) => throwsA(
    isA<LlamaUnsupportedException>().having(
      (e) => e.message,
      'message',
      allOf(
        contains('llama.cpp multi-GPU placement'),
        contains('linux'),
        message,
      ),
    ),
  );

  test('offload devices are numbered per backend as listGpuDevices does', () {
    expect(
      offloadDevicesOf(
        [_host, _cuda0, _vulkan0, _cuda1, _vulkan1],
        GpuBackend.cuda,
        LlamaCppService.gpuBackendFromRegName,
      ),
      [_cuda0, _cuda1],
    );
    expect(
      offloadDevicesOf(
        [_host, _cuda0, _vulkan0, _cuda1, _vulkan1],
        GpuBackend.vulkan,
        LlamaCppService.gpuBackendFromRegName,
      ),
      [_vulkan0, _vulkan1],
    );
  });

  test('a CPU-type device of a GPU registry is not an offload device', () {
    expect(
      offloadDevicesOf(
        [_device('CUDA-host', 'CUDA', type: _cpu), _cuda0],
        GpuBackend.cuda,
        LlamaCppService.gpuBackendFromRegName,
      ),
      [_cuda0],
    );
  });

  test('neither field leaves the placement to llama.cpp', () {
    expect(resolve(const ModelParams()), isNull);
  });

  test('gpuDevices picks the listed devices in the listed order', () {
    final placement = resolve(const ModelParams(gpuDevices: [2, 0]))!;
    expect(placement.devices, [_cuda2, _cuda0]);
    expect(placement.tensorSplit, isNull);
    expect(placement.deviceNames, 'CUDA2, CUDA0');
  });

  test('tensorSplit follows gpuDevices', () {
    final placement = resolve(
      const ModelParams(gpuDevices: [0, 2], tensorSplit: [3, 1]),
    )!;
    expect(placement.devices, [_cuda0, _cuda2]);
    expect(placement.tensorSplit, [3, 1]);
  });

  test('tensorSplit alone covers every device of the backend', () {
    final placement = resolve(const ModelParams(tensorSplit: [1, 1, 2]))!;
    expect(placement.devices, [_cuda0, _cuda1, _cuda2]);
    expect(placement.tensorSplit, [1, 1, 2]);
  });

  test('a device index the host does not have is refused', () {
    expect(
      () => resolve(
        const ModelParams(gpuDevices: [0, 1]),
        registered: [_host, _cuda0],
      ),
      unsupported(
        allOf(
          contains('gpuDevices names cuda device 1'),
          contains('this host has 1 (CUDA0)'),
        ),
      ),
    );
  });

  test('a split whose length differs from the device count is refused', () {
    expect(
      () => resolve(const ModelParams(tensorSplit: [1, 1])),
      unsupported(
        allOf(
          contains('tensorSplit holds 2 proportions'),
          contains('3 cuda devices (CUDA0, CUDA1, CUDA2)'),
        ),
      ),
    );
    expect(
      () =>
          resolve(const ModelParams(tensorSplit: [1, 1]), registered: [_cuda0]),
      unsupported(contains('1 cuda device (CUDA0)')),
    );
  });

  test('a backend without devices is refused', () {
    expect(
      () => resolve(
        const ModelParams(gpuDevices: [0]),
        backend: GpuBackend.metal,
      ),
      unsupported(contains('lists no metal device')),
    );
  });

  test('more devices than llama.cpp supports are refused', () {
    expect(
      () => resolve(const ModelParams(gpuDevices: [0, 1]), maxDevices: 1),
      unsupported(contains('at most 1')),
    );
  });

  group('preferredBackend auto', () {
    test('uses the only GPU backend with devices', () {
      final placement = resolve(
        const ModelParams(gpuDevices: [1]),
        backend: GpuBackend.auto,
        registered: [_host, _cuda0, _cuda1],
      )!;
      expect(placement.devices, [_cuda1]);
      final metal = _device('MTL0', 'MTL', type: _igpu);
      expect(
        resolve(
          const ModelParams(gpuDevices: [0]),
          backend: GpuBackend.auto,
          registered: [_host, metal],
        )!.devices,
        [metal],
      );
    });

    test('is refused when several GPU backends have devices', () {
      expect(
        () => resolve(
          const ModelParams(gpuDevices: [0]),
          backend: GpuBackend.auto,
        ),
        unsupported(
          allOf(
            contains('more than one GPU backend'),
            contains('cuda, vulkan'),
            contains('Set preferredBackend'),
          ),
        ),
      );
    });

    test('is refused without a GPU', () {
      expect(
        () => resolve(
          const ModelParams(tensorSplit: [1]),
          backend: GpuBackend.auto,
          registered: [_host],
        ),
        unsupported(contains('lists no GPU device')),
      );
    });
  });
}
