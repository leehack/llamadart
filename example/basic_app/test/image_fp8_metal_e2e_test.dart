// ignore_for_file: implementation_imports
@TestOn('mac-os')
@Tags(['local-only'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/backends/stable_diffusion/stable_diffusion_runtime_io.dart';
import 'package:test/test.dart';

const _request = ImageGenerationRequest(
  prompt: 'a red fox in a green forest, watercolor painting',
  width: 128,
  height: 128,
  steps: 1,
  guidanceScale: 1,
  seed: 42,
  sampler: ImageGenerationSampler.euler,
  scheduler: ImageGenerationScheduler.discrete,
);

// LLAMADART_IMAGE_FP8_MODEL names an FP8 SD-Turbo checkpoint and, when set,
// LLAMADART_IMAGE_F16_MODEL the F16 checkpoint it was re-encoded from, whose
// Metal pixels are recorded for comparison with an earlier runtime.
void main() {
  final fp8 = Platform.environment['LLAMADART_IMAGE_FP8_MODEL'];
  final f16 = Platform.environment['LLAMADART_IMAGE_F16_MODEL'];
  final output = Platform.environment['LLAMADART_IMAGE_OUTPUT_DIR'];

  Future<Map<String, Object?>> generateOnMetal(
    String label,
    String path,
  ) async {
    final modelHash = (await sha256.bind(File(path).openRead()).first)
        .toString();
    final engine = await ImageGenerationEngine.load(
      ImageGenerationModel(ModelSource.path(path)),
      params: const ImageModelParams(
        device: ComputeDevice.gpu,
        flashAttention: false,
        vaeDirectConvolution: false,
      ),
    );
    try {
      final capabilities = await engine.capabilities;
      expect(capabilities.backendName, startsWith('MTL'));
      expect(capabilities.modelVersion, 'SD 2.x');
      final image = (await engine.generateImage(_request)).images.single;
      expect((image.width, image.height, image.channels), (128, 128, 3));
      expect(image.pixels.toSet().length, greaterThan(64));
      final record = {
        'modelSha256': modelHash,
        'backend': capabilities.backendName,
        'rgbSha256': sha256.convert(image.pixels).toString(),
      };
      print('${label}_METAL ${jsonEncode(record)}');
      if (output != null) {
        Directory(output).createSync(recursive: true);
        final name = label.toLowerCase();
        File('$output/$name-metal.rgb').writeAsBytesSync(image.pixels);
        File('$output/$name-metal.png').writeAsBytesSync(image.toPng());
      }
      return record;
    } finally {
      await engine.dispose();
    }
  }

  test(
    'FP8 checkpoint generates on Metal on the pinned runtime',
    () async {
      final runtime = probeStableDiffusionRuntime();
      runtime.throwIfUnavailable();
      expect(runtime.loadsFp8AsF16OnMetal, isTrue);
      expect(
        runtime.commit,
        anyOf('be48649', 'be486498eadc29dc3cd234d944c2180ed42b1415'),
      );
      await generateOnMetal('FP8', fp8!);
      if (f16 != null) await generateOnMetal('F16', f16);
    },
    skip: fp8 == null
        ? 'Set LLAMADART_IMAGE_FP8_MODEL to an existing FP8 checkpoint.'
        : false,
  );
}
