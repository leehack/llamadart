import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_chat_example/utils/backend_utils.dart';

void main() {
  group('BackendUtils', () {
    test('parses device list from backend info', () {
      final devices = BackendUtils.parseBackendDevices(
        'metal, cpu, metal, vulkan',
      );

      expect(devices, containsAll(<String>['metal', 'cpu', 'vulkan']));
      expect(devices.length, 3);
    });

    test('derives active backend label with preference and fallback', () {
      expect(
        BackendUtils.deriveActiveBackendLabel(
          'metal, cpu',
          preferredBackend: GpuBackend.metal,
          gpuLayers: 12,
        ),
        'METAL',
      );

      expect(
        BackendUtils.deriveActiveBackendLabel(
          'metal, cpu',
          preferredBackend: GpuBackend.cuda,
          gpuLayers: 12,
        ),
        'CPU',
      );

      expect(
        BackendUtils.deriveActiveBackendLabel(
          'cpu',
          preferredBackend: GpuBackend.metal,
          gpuLayers: 12,
        ),
        'CPU',
      );

      expect(
        BackendUtils.deriveActiveBackendLabel(
          'webgpu',
          preferredBackend: GpuBackend.auto,
          gpuLayers: 99,
        ),
        'WEBGPU',
      );

      expect(
        BackendUtils.deriveActiveBackendLabel(
          'LiteRT-LM web gpu',
          preferredBackend: GpuBackend.vulkan,
          gpuLayers: 999,
        ),
        'WEBGPU',
      );

      expect(
        BackendUtils.deriveActiveBackendLabel(
          'LiteRT-LM gpu',
          preferredBackend: GpuBackend.vulkan,
          gpuLayers: 999,
        ),
        'GPU',
      );

      expect(
        BackendUtils.deriveActiveBackendLabel(
          'LiteRT-LM gpu',
          preferredBackend: GpuBackend.auto,
          gpuLayers: 0,
        ),
        'GPU',
      );

      expect(
        BackendUtils.deriveActiveBackendLabel(
          'LiteRT-LM cpu',
          preferredBackend: GpuBackend.auto,
          gpuLayers: 999,
        ),
        'CPU',
      );
    });

    test('selects highest-priority backend from runtime text', () {
      expect(
        BackendUtils.selectBestBackendFromInfo('cpu, vulkan, cuda'),
        GpuBackend.cuda,
      );
      expect(
        BackendUtils.selectBestBackendFromInfo('cpu, metal'),
        GpuBackend.metal,
      );
      expect(
        BackendUtils.selectBestBackendFromInfo('cpu only'),
        GpuBackend.cpu,
      );
    });

    test('builds available backend options for selector UI', () {
      final available = BackendUtils.availableBackends(
        devices: const <String>['metal', 'cpu'],
        activeBackend: 'cuda',
        includeAutoOnWeb: true,
      );

      expect(
        available,
        containsAll(<GpuBackend>[
          GpuBackend.auto,
          GpuBackend.cpu,
          GpuBackend.metal,
          GpuBackend.cuda,
        ]),
      );
    });
  });
}
