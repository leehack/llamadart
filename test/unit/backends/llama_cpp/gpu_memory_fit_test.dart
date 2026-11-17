@TestOn('vm')
library;

import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/backends/llama_cpp/gpu_memory_fit.dart';
import 'package:test/test.dart';

void main() {
  group('gpuMemoryFitSkipReason', () {
    test('lets a Linux or Windows GPU load through', () {
      for (final os in ['linux', 'windows']) {
        expect(
          gpuMemoryFitSkipReason(
            operatingSystem: os,
            gpuLayers: 999,
            noGpuDevice: false,
          ),
          isNull,
        );
      }
    });

    test('names the operating systems that share memory', () {
      for (final os in ['macos', 'ios', 'android']) {
        expect(
          gpuMemoryFitSkipReason(
            operatingSystem: os,
            gpuLayers: 999,
            noGpuDevice: false,
          ),
          contains(os),
        );
      }
    });

    test('skips a load that offloads nothing or selects no GPU', () {
      expect(
        gpuMemoryFitSkipReason(
          operatingSystem: 'linux',
          gpuLayers: 0,
          noGpuDevice: false,
        ),
        contains('no layer'),
      );
      expect(
        gpuMemoryFitSkipReason(
          operatingSystem: 'windows',
          gpuLayers: 999,
          noGpuDevice: true,
        ),
        contains('no GPU device'),
      );
    });
  });

  group('gpuMemoryFitOutcome', () {
    GpuMemoryFitOutcome outcome(int layers, {bool context = false}) =>
        gpuMemoryFitOutcome(
          fittedLayers: layers,
          offloadableLayers: 29,
          contextReduced: context,
        );

    test('no layer means the CPU', () {
      expect(outcome(0), GpuMemoryFitOutcome.cpu);
      expect(outcome(0, context: true), GpuMemoryFitOutcome.cpu);
    });

    test('the default layer count and a full count are unchanged', () {
      expect(outcome(-1), GpuMemoryFitOutcome.unchanged);
      expect(outcome(29), GpuMemoryFitOutcome.unchanged);
    });

    test('fewer layers or a smaller context are reduced', () {
      expect(outcome(14), GpuMemoryFitOutcome.reduced);
      expect(outcome(-1, context: true), GpuMemoryFitOutcome.reduced);
    });
  });

  group('gpuMemoryFitLogMessage', () {
    const device = GpuMemoryFitDevice(
      name: 'CUDA0',
      freeBytes: 300,
      totalBytes: 800,
      modelBytes: 100,
      contextBytes: 50,
      computeBytes: 10,
    );

    test('names layers, free and projected bytes of a reduced load', () {
      final message = gpuMemoryFitLogMessage(
        const GpuMemoryFitReport(
          outcome: GpuMemoryFitOutcome.reduced,
          modelLayers: 29,
          gpuLayers: 14,
          contextSize: 512,
          marginBytes: 64,
          devices: [device],
        ),
      );
      expect(message, contains('14 of 29'));
      expect(message, contains('CUDA0: 300 bytes free, 160 projected'));
    });

    test('says each outcome differently', () {
      String message(GpuMemoryFitOutcome outcome) => gpuMemoryFitLogMessage(
        GpuMemoryFitReport(outcome: outcome, reason: 'because'),
      );
      expect(message(GpuMemoryFitOutcome.unchanged), contains('fit'));
      expect(message(GpuMemoryFitOutcome.cpu), contains('CPU'));
      expect(message(GpuMemoryFitOutcome.skipped), contains('because'));
    });
  });

  test('a runtime without llama_dart_fit_params resolves no runner', () {
    expect(resolveNativeGpuMemoryFitRunner(), isNull);
  });
}
