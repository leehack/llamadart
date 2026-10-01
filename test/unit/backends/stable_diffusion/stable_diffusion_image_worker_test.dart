@TestOn('vm')
library;

import 'package:test/test.dart';

import 'package:llamadart/src/backends/stable_diffusion/stable_diffusion_image_worker.dart';
import 'package:llamadart/src/backends/stable_diffusion/stable_diffusion_runtime_io.dart';
import 'package:llamadart/src/core/exceptions.dart';
import 'package:llamadart/src/core/image/image_generation_driver.dart';

// Real generation needs the opt-in runtime, which the root package does not
// bundle; example/basic_app/test/image_generation_e2e_test.dart covers it.
void main() {
  test(
    'a worker whose runtime is missing fails its start and exits',
    () async {
      await expectLater(
        StableDiffusionImageWorker.start(
          const ImageGenerationSessionConfig(
            files: {'model': '/models/sdxs.gguf'},
            backend: null,
            threads: 0,
          ),
        ),
        throwsA(
          isA<LlamaStateException>().having(
            (error) => '${error.details}',
            'details',
            contains('stable_diffusion'),
          ),
        ),
      );
    },
    skip: probeStableDiffusionRuntime().isAvailable
        ? 'the stable_diffusion runtime is bundled here'
        : false,
  );

  group('describeStableDiffusionLoadFailure', () {
    test('names a missing VAE when a diffusionModel has none', () {
      final message = describeStableDiffusionLoadFailure({
        'diffusionModel': '/m/sd3.5_medium-Q8_0.gguf',
        'clipL': '/m/clip_l.gguf',
        'clipG': '/m/clip_g.gguf',
        't5xxl': '/m/t5xxl.gguf',
      });

      expect(message, contains('needs a vae or taesd file'));
      expect(message, contains('goes in model instead'));
      expect(message, isNot(contains('text encoders')));
      expect(message, isNot(contains('/m/')));
    });

    test('names missing text encoders when a diffusionModel has none', () {
      final message = describeStableDiffusionLoadFailure({
        'diffusionModel': '/m/z_image_turbo-Q4_K.gguf',
        'vae': '/m/ae.safetensors',
      });

      expect(message, contains('llm for Z-Image and Qwen-Image'));
      expect(message, isNot(contains('vae or taesd')));
    });

    test('a taesd file stands in for the VAE', () {
      final message = describeStableDiffusionLoadFailure({
        'diffusionModel': '/m/flux1-schnell-Q4_0.gguf',
        'taesd': '/m/taef1.safetensors',
        'clipL': '/m/clip_l.gguf',
        't5xxl': '/m/t5xxl.gguf',
      });

      expect(message, isNot(contains('vae or taesd')));
      expect(message, contains('enough memory'));
    });

    test('a single-file checkpoint gets the general advice', () {
      final message = describeStableDiffusionLoadFailure({
        'model': '/m/sd_turbo.gguf',
      });

      expect(message, contains('a single-file checkpoint goes in model'));
      expect(message, contains('enough memory'));
      expect(message, contains('does not report its reason'));
    });
  });
}
