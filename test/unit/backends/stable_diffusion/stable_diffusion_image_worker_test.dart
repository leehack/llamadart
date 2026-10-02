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

  group('stableDiffusionModelLoadFailure', () {
    test('names a missing VAE when a diffusionModel has none', () {
      final error = stableDiffusionModelLoadFailure({
        'diffusionModel': '/m/sd3.5_medium-Q8_0.gguf',
        'clipL': '/m/clip_l.gguf',
        'clipG': '/m/clip_g.gguf',
        't5xxl': '/m/t5xxl.gguf',
      });

      expect(error.message, contains('need a vae or taesd file'));
      expect(error.message, contains('is an ImageModelRole.checkpoint'));
      expect(error.message, isNot(contains('text encoders')));
      expect(error.details, 'files: diffusionModel, clipL, clipG, t5xxl');
      expect('$error', isNot(contains('/m/')));
    });

    test('names missing text encoders when a diffusionModel has none', () {
      final error = stableDiffusionModelLoadFailure({
        'diffusionModel': '/m/z_image_turbo-Q4_K.gguf',
        'vae': '/m/ae.safetensors',
      });

      expect(error.message, contains('llm for Z-Image and Qwen-Image'));
      expect(error.message, isNot(contains('vae or taesd')));
      expect(error.details, 'files: diffusionModel, vae');
    });

    test('each text encoder, llm included, counts as one', () {
      for (final role in ['clipL', 'clipG', 't5xxl', 'llm']) {
        final error = stableDiffusionModelLoadFailure({
          'diffusionModel': '/m/diffusion.gguf',
          'vae': '/m/vae.safetensors',
          role: '/m/encoder.gguf',
        });

        expect(error.message, isNot(contains('text encoders')), reason: role);
        expect(error.message, contains('enough memory'), reason: role);
      }
    });

    test('a taesd file stands in for the VAE', () {
      final error = stableDiffusionModelLoadFailure({
        'diffusionModel': '/m/flux1-schnell-Q4_0.gguf',
        'taesd': '/m/taef1.safetensors',
        'clipL': '/m/clip_l.gguf',
        't5xxl': '/m/t5xxl.gguf',
      });

      expect(error.message, isNot(contains('vae or taesd')));
      expect(error.message, contains('enough memory'));
    });

    test('a single-file checkpoint gets the general advice', () {
      final error = stableDiffusionModelLoadFailure({
        'model': '/m/sd_turbo.gguf',
      });

      expect(
        error.message,
        contains('ImageModelRole.checkpoint for a single file'),
      );
      expect(error.message, contains('enough memory'));
      expect(error.message, contains('does not report its reason'));
      expect(error.details, 'files: checkpoint');
    });
  });
}
