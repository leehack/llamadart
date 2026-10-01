@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

import 'package:llamadart/src/core/image/image_generation_driver.dart';
import 'package:llamadart/src/core/image/image_generation_driver_io.dart';

void main() {
  test('sizes regular files only', () async {
    final directory = await Directory.systemTemp.createTemp('llamadart-img-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/model.gguf')
      ..writeAsBytesSync(List.filled(1234, 0));
    final driver = createImageGenerationDriver();

    expect(driver.fileSize(file.path), 1234);
    expect(driver.fileSize(directory.path), isNull);
    expect(driver.fileSize('${directory.path}/missing.gguf'), isNull);
  });

  test('probes the host runtime, which the root package does not bundle', () {
    final status = createImageGenerationDriver().probe();

    expect(status.isAvailable, isFalse);
    expect(status.unavailableReason?.message, contains('stable_diffusion'));
  });

  test('probes in a background isolate with the same result', () async {
    final driver = createImageGenerationDriver();

    final status = await driver.probeInBackground();

    expect(status.isAvailable, isFalse);
    expect(
      status.unavailableReason?.message,
      driver.probe().unavailableReason?.message,
    );
  });

  test('reports a CPU and Metal memory budget on macOS and Linux hosts, and '
      'none for other GPUs', () {
    final driver = createImageGenerationDriver();

    for (final device in [
      ImageGenerationComputeDevice.cpu,
      ImageGenerationComputeDevice.metal,
    ]) {
      final budget = driver.memoryBudget(device);
      if (Platform.isMacOS || Platform.isLinux) {
        expect(budget, isNotNull);
        expect(budget!.bytes, greaterThan(0));
      } else if (Platform.isWindows) {
        expect(budget, isNull);
      }
    }
    expect(driver.memoryBudget(ImageGenerationComputeDevice.otherGpu), isNull);
  });
}
