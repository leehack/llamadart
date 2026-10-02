import 'package:llamadart/llamadart.dart';
import 'package:test/test.dart';

void main() {
  group('encoderModelParams', () {
    test('uses a 512-token context on the best device by default', () {
      final params = const DecisionModelParams().encoderModelParams;

      expect(params.contextSize, 512);
      expect(params.preferredBackend, GpuBackend.auto);
      expect(params.gpuLayers, ModelParams.maxGpuLayers);
      expect(params.numberOfThreads, 0);
      expect(params.numberOfThreadsBatch, 0);
    });

    test('offloads every layer for ComputeDevice.gpu', () {
      final params = const DecisionModelParams(
        device: ComputeDevice.gpu,
      ).encoderModelParams;

      expect(params.preferredBackend, GpuBackend.auto);
      expect(params.gpuLayers, ModelParams.maxGpuLayers);
    });

    test('keeps ComputeDevice.cpu off the GPU and applies threads', () {
      final params = const DecisionModelParams(
        device: ComputeDevice.cpu,
        threads: 6,
      ).encoderModelParams;

      expect(params.contextSize, 512);
      expect(params.preferredBackend, GpuBackend.cpu);
      expect(params.gpuLayers, 0);
      expect(params.numberOfThreads, 6);
      expect(params.numberOfThreadsBatch, 6);
    });
  });
}
