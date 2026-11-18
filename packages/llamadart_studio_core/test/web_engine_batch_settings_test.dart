import 'package:llamadart/llamadart.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:test/test.dart';

void main() {
  test('GGUF NPU requests remain explicit for runtime validation', () {
    for (final isWeb in [false, true]) {
      final params = const StudioSettings(
        computeDevice: ComputeDevice.npu,
      ).toModelParams(format: ModelFormat.gguf, isWeb: isWeb);
      expect(params.device, ComputeDevice.npu);
    }
  });
  test('Web automatic batching remains owned by the runtime', () {
    final params = const StudioSettings().toModelParams(
      format: ModelFormat.gguf,
      isWeb: true,
    );
    expect(params.batchSize, 0);
    expect(params.microBatchSize, 0);
  });

  test('Web forwards explicit Inspector batching to the runtime', () {
    final params = const StudioSettings(
      batchSize: 512,
      microBatchSize: 128,
    ).toModelParams(format: ModelFormat.gguf, isWeb: true);
    expect(params.batchSize, 512);
    expect(params.microBatchSize, 128);
  });

  test(
    'Web batch edits require engine reload and normalized Auto stays equal',
    () {
      const base = StudioSettings();
      final signature = base.engineLoadSignature(isWeb: true);
      expect(
        base.copyWith(batchSize: 512).engineLoadSignature(isWeb: true),
        isNot(signature),
      );
      expect(
        base.copyWith(microBatchSize: 128).engineLoadSignature(isWeb: true),
        isNot(signature),
      );
      expect(
        base
            .copyWith(batchSize: -1, microBatchSize: -1)
            .engineLoadSignature(isWeb: true),
        signature,
      );
    },
  );
}
