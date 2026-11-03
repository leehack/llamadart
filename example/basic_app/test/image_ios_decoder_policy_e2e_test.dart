// ignore_for_file: implementation_imports
@Tags(['local-only'])
@Timeout(Duration(minutes: 3))
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/backends/stable_diffusion/stable_diffusion_runtime_status.dart';
import 'package:llamadart/src/core/image/image_generation_driver.dart';
import 'package:llamadart/src/core/image/image_generation_driver_io.dart';
import 'package:test/test.dart';

// Exercises the real native runtime on the host, overriding only the driver
// OS label to select the iOS admission path. This is not iPhone qualification.
// Set LLAMADART_SDXS_MODEL and LLAMADART_SD_TURBO_MODEL to existing GGUFs.
void main() {
  final tiny = Platform.environment['LLAMADART_SDXS_MODEL'];
  final full = Platform.environment['LLAMADART_SD_TURBO_MODEL'];
  final missingModels = tiny == null || full == null;
  late _IosDriver driver;
  final recorded = <String>[];

  setUp(() async {
    driver = _IosDriver();
    debugImageGenerationDriverOverride = driver;
    await LlamaLogging.configure(
      level: LlamaLogLevel.info,
      handler: (record) => recorded.add(record.message),
    );
    recorded.clear();
  });
  tearDown(() async {
    debugImageGenerationDriverOverride = null;
    await LlamaLogging.configure(level: LlamaLogLevel.none);
  });

  test('old runtime refuses intrinsic SDXS before native creation', () async {
    final status = await driver.probeInBackground();
    if (status.supportsIntrinsicTinyDecoderV1) {
      markTestSkipped('The runtime provides the versioned decoder policy');
      return;
    }
    await expectLater(
      ImageGenerationEngine.load(
        ImageGenerationModel(ModelSource.path(tiny!)),
        params: const ImageModelParams(device: ComputeDevice.gpu),
      ),
      throwsA(isA<LlamaUnsupportedException>()),
    );
    expect(driver.starts, 0);
  }, skip: missingModels ? 'Set existing SDXS and SD-Turbo GGUF paths' : false);

  for (final replacement in ['unchanged', 'tiny', 'full']) {
    test(
      'native policy preserves the decoder after $replacement source',
      () async {
        final status = await driver.probeInBackground();
        if (!status.supportsIntrinsicTinyDecoderV1) {
          markTestSkipped(
            'Requires a runtime with the intrinsic tiny-decoder v1 export',
          );
          return;
        }
        final directory = Directory.systemTemp.createTempSync(
          'ios-decoder-policy-',
        );
        addTearDown(() => directory.deleteSync(recursive: true));
        final live = File('${directory.path}/live.gguf');
        await _clone(tiny!, live.path);
        final engine = await ImageGenerationEngine.load(
          ImageGenerationModel(ModelSource.path(live.path)),
          params: const ImageModelParams(device: ComputeDevice.gpu, threads: 2),
        );
        addTearDown(engine.dispose);
        expect(driver.config!.requiresIntrinsicTinyDecoderV1, isTrue);
        expect((await engine.capabilities).modelVersion, startsWith('SDXS'));
        if (replacement != 'unchanged') {
          final next = File('${directory.path}/next.gguf');
          await _clone(replacement == 'tiny' ? tiny : full!, next.path);
          if (replacement == 'tiny') {
            next.setLastModifiedSync(
              live.lastModifiedSync().add(const Duration(seconds: 2)),
            );
          }
          next.renameSync(live.path);
        }
        final generated = engine.generateImage(_request);
        if (replacement == 'full') {
          await expectLater(generated, throwsA(isA<LlamaException>()));
          expect(
            recorded.any(
              (line) =>
                  line.contains('intrinsic tiny decoder policy v1 rejects'),
            ),
            isTrue,
          );
        } else {
          expect((await generated).images, hasLength(1));
        }
        expect(
          recorded.any(
            (line) => line.contains('using VAE for encoding / decoding'),
          ),
          isFalse,
        );
      },
      skip: missingModels ? 'Set existing SDXS and SD-Turbo GGUF paths' : false,
    );
  }

  test(
    'CPU VAE placement preserves Metal diffusion without the policy',
    () async {
      final engine = await ImageGenerationEngine.load(
        ImageGenerationModel(ModelSource.path(full!)),
        params: const ImageModelParams(device: ComputeDevice.gpu, threads: 2),
        placement: const ImageModelPlacement(vaeOnCpu: true),
      );
      addTearDown(engine.dispose);
      expect(driver.config!.requiresIntrinsicTinyDecoderV1, isFalse);
      expect(driver.config!.backend, contains('vae=cpu'));
      expect((await engine.generateImage(_request)).images, hasLength(1));
    },
    skip: missingModels ? 'Set existing SDXS and SD-Turbo GGUF paths' : false,
  );
}

const _request = ImageGenerationRequest(
  prompt: 'a red fox',
  width: 256,
  height: 256,
  steps: 1,
  guidanceScale: 1,
  seed: 42,
);

Future<void> _clone(String source, String target) async {
  if (Platform.isMacOS) {
    final result = await Process.run('cp', ['-c', source, target]);
    if (result.exitCode != 0) throw StateError('Scratch model clone failed');
  } else {
    await File(source).copy(target);
  }
}

final class _IosDriver implements ImageGenerationDriver {
  final ImageGenerationDriver real = createImageGenerationDriver();
  int starts = 0;
  ImageGenerationSessionConfig? config;
  @override
  String get operatingSystem => 'ios';
  @override
  Future<StableDiffusionRuntimeStatus> probeInBackground() =>
      real.probeInBackground();
  @override
  int? fileSize(String path) => real.fileSize(path);
  @override
  Future<Uint8List> readFileRange(String path, int offset, int length) =>
      real.readFileRange(path, offset, length);
  @override
  Future<ImageGenerationMemoryLimits> memoryLimits(
    ImageGenerationComputeDevice device, {
    required bool runtimePicksGpu,
    List<StableDiffusionGpuMemory>? gpus,
  }) => real.memoryLimits(device, runtimePicksGpu: runtimePicksGpu, gpus: gpus);
  @override
  Future<List<StableDiffusionGpuMemory>?> readGpuMemory() =>
      real.readGpuMemory();
  @override
  Future<ImageGenerationSession> start(ImageGenerationSessionConfig value) {
    starts++;
    config = value;
    return real.start(value);
  }
}
