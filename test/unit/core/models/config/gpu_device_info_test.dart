import 'package:llamadart/src/core/models/config/gpu_backend.dart';
import 'package:llamadart/src/core/models/config/gpu_device_info.dart';
import 'package:test/test.dart';

void main() {
  test('GpuDeviceInfo exposes its fields', () {
    const device = GpuDeviceInfo(
      backend: GpuBackend.vulkan,
      mainGpu: 1,
      name: 'Vulkan1',
      description: 'NVIDIA GeForce RTX 5050 Laptop GPU',
      deviceId: '0000:64:00.0',
      type: GpuDeviceType.discreteGpu,
      memoryFreeBytes: 7910,
      memoryTotalBytes: 8192,
    );

    expect(device.backend, GpuBackend.vulkan);
    expect(device.mainGpu, 1);
    expect(device.name, 'Vulkan1');
    expect(device.description, 'NVIDIA GeForce RTX 5050 Laptop GPU');
    expect(device.deviceId, '0000:64:00.0');
    expect(device.type, GpuDeviceType.discreteGpu);
    expect(device.memoryFreeBytes, 7910);
    expect(device.memoryTotalBytes, 8192);
  });

  test('isDiscreteGpu is true only for a discrete GPU', () {
    const discrete = GpuDeviceInfo(
      backend: GpuBackend.vulkan,
      mainGpu: 1,
      name: 'Vulkan1',
      description: 'NVIDIA GeForce RTX 5050 Laptop GPU',
      deviceId: '',
      type: GpuDeviceType.discreteGpu,
      memoryFreeBytes: 0,
      memoryTotalBytes: 0,
    );
    const integrated = GpuDeviceInfo(
      backend: GpuBackend.vulkan,
      mainGpu: 0,
      name: 'Vulkan0',
      description: 'AMD Radeon 860M Graphics',
      deviceId: '',
      type: GpuDeviceType.integratedGpu,
      memoryFreeBytes: 0,
      memoryTotalBytes: 0,
    );

    expect(discrete.isDiscreteGpu, isTrue);
    expect(integrated.isDiscreteGpu, isFalse);
  });

  test('toString includes backend, description, and type', () {
    const device = GpuDeviceInfo(
      backend: GpuBackend.cuda,
      mainGpu: 0,
      name: 'CUDA0',
      description: 'NVIDIA RTX',
      deviceId: '',
      type: GpuDeviceType.discreteGpu,
      memoryFreeBytes: 1,
      memoryTotalBytes: 2,
    );

    final text = device.toString();
    expect(text, contains('cuda'));
    expect(text, contains('NVIDIA RTX'));
    expect(text, contains('discreteGpu'));
  });

  group('GpuMemoryFitReport', () {
    const device = GpuMemoryFitDevice(
      name: 'CUDA0',
      freeBytes: 300,
      totalBytes: 800,
      modelBytes: 100,
      contextBytes: 50,
      computeBytes: 10,
    );

    test('a device projects the sum of what it holds', () {
      expect(device.projectedBytes, 160);
    });

    test('prints layers, free and projected bytes', () {
      const report = GpuMemoryFitReport(
        outcome: GpuMemoryFitOutcome.reduced,
        modelLayers: 29,
        gpuLayers: 14,
        contextSize: 512,
        marginBytes: 64,
        devices: [device],
      );
      expect(
        report.toString(),
        'GpuMemoryFitReport(reduced, gpuLayers: 14 of 29, contextSize: 512, '
        'marginBytes: 64, CUDA0: free 300, projected 160)',
      );
    });

    test('prints why a load was skipped', () {
      expect(
        const GpuMemoryFitReport(
          outcome: GpuMemoryFitOutcome.skipped,
          reason: 'shared memory',
        ).toString(),
        contains('reason: shared memory'),
      );
      expect(device.toString(), contains('projected: 160'));
    });
  });
}
