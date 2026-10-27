// ignore_for_file: implementation_imports
@TestOn('vm')
@Tags(['local-only'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/backends/stable_diffusion/stable_diffusion_runtime_io.dart';
import 'package:llamadart/src/backends/stable_diffusion/stable_diffusion_memory.dart';
import 'package:llamadart/src/core/image/image_model_classifier.dart';
import 'package:test/test.dart';

void main() {
  final path = Platform.environment['LLAMADART_IMAGE_FP8_MODEL'];
  test(
    'FP8 checkpoint generates on the pinned CPU runtime and disposes',
    () async {
      final file = File(path!);
      final modelHash = (await sha256.bind(file.openRead()).first).toString();
      final header = await readImageModelFileHeader(
        (offset, length) => readStableDiffusionFileRange(path, offset, length),
        stopAtLanguageModelArchitecture: false,
      );
      expect(
        header.tensors.any(
          (tensor) =>
              tensor.dtype == 'F8_E4M3' ||
              tensor.dtype == 'F8_E5M2' ||
              tensor.ggufType == 43 ||
              tensor.ggufType == 44,
        ),
        isTrue,
      );

      final runtime = probeStableDiffusionRuntime();
      runtime.throwIfUnavailable();
      expect(
        runtime.commit,
        anyOf('be48649', 'be486498eadc29dc3cd234d944c2180ed42b1415'),
      );
      final clock = Stopwatch()..start();
      final engine = await ImageGenerationEngine.load(
        ImageGenerationModel(ModelSource.path(path)),
        params: const ImageModelParams(
          device: ComputeDevice.cpu,
          threads: 8,
          flashAttention: false,
          vaeDirectConvolution: false,
        ),
      );
      try {
        expect((await engine.capabilities).backendName, 'CPU');
        expect((await engine.capabilities).modelVersion, 'SD 2.x');
        final image = (await engine.generateImage(
          const ImageGenerationRequest(
            prompt: 'a red fox in a green forest, watercolor painting',
            width: 128,
            height: 128,
            steps: 1,
            guidanceScale: 1,
            seed: 42,
            sampler: ImageGenerationSampler.euler,
            scheduler: ImageGenerationScheduler.discrete,
          ),
        )).images.single;
        expect((image.width, image.height, image.channels), (128, 128, 3));
        expect(image.pixels.toSet().length, greaterThan(64));
        final record = {
          'modelSha256': modelHash,
          'runtimeVersion': runtime.version,
          'runtimeCommit': runtime.commit,
          'backend': 'CPU',
          'threads': 8,
          'width': 128,
          'height': 128,
          'steps': 1,
          'seed': 42,
          'guidanceScale': 1,
          'sampler': 'euler',
          'scheduler': 'discrete',
          'flashAttention': false,
          'vaeDirectConvolution': false,
          'batchedCfg': false,
          'prompt': 'a red fox in a green forest, watercolor painting',
          'rgbSha256': sha256.convert(image.pixels).toString(),
          'elapsedMs': clock.elapsedMilliseconds,
        };
        print('FP8_CPU ${jsonEncode(record)}');
        final output = Platform.environment['LLAMADART_IMAGE_OUTPUT_DIR'];
        if (output != null) {
          Directory(output).createSync(recursive: true);
          File('$output/fp8-cpu.rgb').writeAsBytesSync(image.pixels);
          File('$output/fp8-cpu.png').writeAsBytesSync(image.toPng());
          File('$output/fp8-cpu.json').writeAsStringSync(jsonEncode(record));
        }
      } finally {
        await engine.dispose();
      }
      expect((await engine.capabilities).isSupported, isFalse);
    },
    skip: path == null || !Platform.isMacOS
        ? 'Set LLAMADART_IMAGE_FP8_MODEL to an existing FP8 checkpoint on macOS.'
        : false,
  );
}
