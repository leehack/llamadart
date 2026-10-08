@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

import 'package:llamadart/src/backends/stable_diffusion/stable_diffusion_memory.dart';
import 'package:llamadart/src/backends/stable_diffusion/stable_diffusion_runtime_status.dart';
import 'package:llamadart/src/core/exceptions.dart';
import 'package:llamadart/src/core/image/image_generation_driver.dart';
import 'package:llamadart/src/core/image/image_generation_driver_io.dart';
import 'package:llamadart/src/core/llama_logging.dart';
import 'package:llamadart/src/core/models/config/log_level.dart';

/// Set in the test isolate only: an isolate the driver spawns starts with the
/// initial value.
String _isolate = 'spawned';

StableDiffusionRuntimeStatus _probeNamingItsIsolate({
  LlamaLogLevel logLevel = LlamaLogLevel.none,
}) => StableDiffusionRuntimeStatus.unavailable(
  LlamaUnsupportedException('$_isolate isolate, log level ${logLevel.name}'),
);

StableDiffusionGpuMemory? _gpuMemoryNamingItsIsolate({
  LlamaLogLevel logLevel = LlamaLogLevel.none,
}) => (
  name: '$_isolate isolate, log level ${logLevel.name}',
  totalBytes: 8 << 30,
  freeBytes: 6 << 30,
  integrated: false,
);

StableDiffusionGpuMemory? _noGpuMemory({
  LlamaLogLevel logLevel = LlamaLogLevel.none,
}) => null;

void main() {
  setUp(() => _isolate = 'calling');

  tearDown(
    () => applyLogLevels(dart: LlamaLogLevel.none, native: LlamaLogLevel.none),
  );

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

  test('the background probe runs in another isolate, and probe on the '
      'calling one', () async {
    final driver = createImageGenerationDriver(probe: _probeNamingItsIsolate);

    expect(
      (await driver.probeInBackground()).unavailableReason?.message,
      startsWith('spawned isolate'),
    );
    expect(
      driver.probe().unavailableReason?.message,
      startsWith('calling isolate'),
    );
  });

  test('the runtime records its log at the stricter of the two configured '
      'levels, and not at all when either is none', () async {
    final driver = createImageGenerationDriver(
      probe: _probeNamingItsIsolate,
      readGpuMemory: _gpuMemoryNamingItsIsolate,
    );

    for (final (dart, native, expected) in [
      (LlamaLogLevel.none, LlamaLogLevel.none, LlamaLogLevel.none),
      (LlamaLogLevel.debug, LlamaLogLevel.none, LlamaLogLevel.none),
      (LlamaLogLevel.none, LlamaLogLevel.debug, LlamaLogLevel.none),
      (LlamaLogLevel.debug, LlamaLogLevel.warn, LlamaLogLevel.warn),
      (LlamaLogLevel.error, LlamaLogLevel.info, LlamaLogLevel.error),
      (LlamaLogLevel.info, LlamaLogLevel.info, LlamaLogLevel.info),
    ]) {
      await applyLogLevels(dart: dart, native: native);
      final reason = '${dart.name}/${native.name}';

      expect(imageRuntimeLogLevel(), expected, reason: reason);
      expect(
        (await driver.probeInBackground()).unavailableReason?.message,
        endsWith('log level ${expected.name}'),
        reason: reason,
      );
      expect(
        driver.probe().unavailableReason?.message,
        endsWith('log level ${expected.name}'),
        reason: reason,
      );
      expect(
        (await driver.memoryBudget(
          ImageGenerationComputeDevice.otherGpu,
        ))?.source,
        contains('log level ${expected.name}'),
        reason: reason,
      );
    }
  });

  test('reports a CPU and Metal memory budget on macOS and Linux hosts, and '
      'none for other GPUs on a host without the runtime', () async {
    final driver = createImageGenerationDriver();

    for (final device in [
      ImageGenerationComputeDevice.cpu,
      ImageGenerationComputeDevice.metal,
    ]) {
      final budget = await driver.memoryBudget(device);
      if (Platform.isMacOS || Platform.isLinux) {
        expect(budget, isNotNull);
        expect(budget!.bytes, greaterThan(0));
      } else if (Platform.isWindows) {
        expect(budget, isNull);
      }
    }
    expect(
      await driver.memoryBudget(ImageGenerationComputeDevice.otherGpu),
      isNull,
    );
  });

  test('asks another GPU for its memory in another isolate, and budgets its '
      'free memory', () async {
    final driver = createImageGenerationDriver(
      readGpuMemory: _gpuMemoryNamingItsIsolate,
    );

    final budget = await driver.memoryBudget(
      ImageGenerationComputeDevice.otherGpu,
    );

    expect(budget?.bytes, 6 << 30);
    expect(budget?.source, contains('free GPU memory of spawned isolate'));
  });

  test('a GPU whose memory is not known has no budget, and the CPU and '
      'Metal budgets do not ask it', () async {
    final driver = createImageGenerationDriver(readGpuMemory: _noGpuMemory);

    expect(
      await driver.memoryBudget(ImageGenerationComputeDevice.otherGpu),
      isNull,
    );

    final unasked = createImageGenerationDriver(
      readGpuMemory: _gpuMemoryNamingItsIsolate,
    );
    for (final device in [
      ImageGenerationComputeDevice.cpu,
      ImageGenerationComputeDevice.metal,
    ]) {
      expect(
        (await unasked.memoryBudget(device))?.source,
        isNot(contains('isolate')),
      );
    }
  });
}
