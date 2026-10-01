import 'package:test/test.dart';

import 'package:llamadart/src/core/image/image_generation_model.dart';

void main() {
  test('sdxs samples one step at guidance 1', () {
    final model = ImageGenerationModel.sdxs('/m/sdxs.gguf');

    expect(model.family, ImageGenerationModelFamily.sdxs);
    expect(model.files.paths, {'model': '/m/sdxs.gguf'});
    expect(model.defaults.steps, 1);
    expect(model.defaults.guidanceScale, 1);
  });

  test('sdTurbo samples one step at guidance 1 and adds TAESD', () {
    final withTaesd = ImageGenerationModel.sdTurbo(
      '/m/turbo.gguf',
      taesdPath: '/m/taesd.safetensors',
    );
    final withoutTaesd = ImageGenerationModel.sdTurbo('/m/turbo.gguf');

    expect(withTaesd.family, ImageGenerationModelFamily.sdTurbo);
    expect(withTaesd.files.paths, {
      'model': '/m/turbo.gguf',
      'taesd': '/m/taesd.safetensors',
    });
    expect(withoutTaesd.files.paths, {'model': '/m/turbo.gguf'});
    expect(withTaesd.defaults.steps, 1);
    expect(withTaesd.defaults.guidanceScale, 1);
  });

  test('sdxlLightning samples 4 Euler steps on the sgm_uniform schedule', () {
    final model = ImageGenerationModel.sdxlLightning(
      '/m/lightning.safetensors',
      taesdPath: '/m/taesdxl.safetensors',
    );

    expect(model.family, ImageGenerationModelFamily.sdxlLightning);
    expect(model.files.paths, {
      'model': '/m/lightning.safetensors',
      'taesd': '/m/taesdxl.safetensors',
    });
    expect(model.defaults.steps, 4);
    expect(model.defaults.guidanceScale, 1);
    expect(model.defaults.sampler, ImageGenerationSampler.euler);
    expect(model.defaults.scheduler, ImageGenerationScheduler.sgmUniform);
    expect(
      ImageGenerationModel.sdxlLightning(
        '/m/lightning.safetensors',
        vaePath: '/m/vae.safetensors',
      ).files.paths.keys,
      ['model', 'vae'],
    );
  });

  test('flux1Schnell takes split files and 4 steps at guidance 1', () {
    final model = ImageGenerationModel.flux1Schnell(
      diffusionModelPath: '/m/flux.gguf',
      clipLPath: '/m/clip_l.gguf',
      t5xxlPath: '/m/t5.gguf',
      vaePath: '/m/ae.safetensors',
    );

    expect(model.family, ImageGenerationModelFamily.flux1Schnell);
    expect(model.files.paths, {
      'diffusionModel': '/m/flux.gguf',
      'vae': '/m/ae.safetensors',
      'clipL': '/m/clip_l.gguf',
      't5xxl': '/m/t5.gguf',
    });
    expect((model.defaults.steps, model.defaults.guidanceScale), (4, 1.0));
    expect(model.defaults.sampler, isNull);
  });

  test('flux1Schnell decodes with TAESD alone when no VAE is given', () {
    final model = ImageGenerationModel.flux1Schnell(
      diffusionModelPath: '/m/flux.gguf',
      clipLPath: '/m/clip_l.gguf',
      t5xxlPath: '/m/t5.gguf',
      taesdPath: '/m/taef1.safetensors',
    );

    expect(model.files.paths, {
      'diffusionModel': '/m/flux.gguf',
      'taesd': '/m/taef1.safetensors',
      'clipL': '/m/clip_l.gguf',
      't5xxl': '/m/t5.gguf',
    });
  });

  test('sd35LargeTurbo takes three text encoders and 4 steps', () {
    final model = ImageGenerationModel.sd35LargeTurbo(
      diffusionModelPath: '/m/sd35lt.gguf',
      clipLPath: '/m/clip_l.gguf',
      clipGPath: '/m/clip_g.gguf',
      t5xxlPath: '/m/t5.gguf',
      taesdPath: '/m/taesd3.safetensors',
    );

    expect(model.family, ImageGenerationModelFamily.sd35LargeTurbo);
    expect(model.files.paths, {
      'diffusionModel': '/m/sd35lt.gguf',
      'taesd': '/m/taesd3.safetensors',
      'clipL': '/m/clip_l.gguf',
      'clipG': '/m/clip_g.gguf',
      't5xxl': '/m/t5.gguf',
    });
    expect((model.defaults.steps, model.defaults.guidanceScale), (4, 1.0));
  });

  test('zImageTurbo takes an llm text encoder and 8 steps', () {
    final model = ImageGenerationModel.zImageTurbo(
      diffusionModelPath: '/m/z.gguf',
      llmPath: '/m/qwen3.gguf',
      vaePath: '/m/ae.safetensors',
    );

    expect(model.family, ImageGenerationModelFamily.zImageTurbo);
    expect(model.files.paths, {
      'diffusionModel': '/m/z.gguf',
      'vae': '/m/ae.safetensors',
      'llm': '/m/qwen3.gguf',
    });
    expect((model.defaults.steps, model.defaults.guidanceScale), (8, 1.0));
  });

  test('split presets need a VAE or TAESD decoder', () {
    for (final (name, build) in <(String, ImageGenerationModel Function())>[
      (
        'flux1Schnell',
        () => ImageGenerationModel.flux1Schnell(
          diffusionModelPath: '/m/flux.gguf',
          clipLPath: '/m/clip_l.gguf',
          t5xxlPath: '/m/t5.gguf',
        ),
      ),
      (
        'sd35LargeTurbo',
        () => ImageGenerationModel.sd35LargeTurbo(
          diffusionModelPath: '/m/sd35lt.gguf',
          clipLPath: '/m/clip_l.gguf',
          clipGPath: '/m/clip_g.gguf',
          t5xxlPath: '/m/t5.gguf',
        ),
      ),
    ]) {
      expect(
        build,
        throwsA(
          isA<ArgumentError>().having(
            (error) => '${error.message}',
            'message',
            contains('$name needs vaePath or taesdPath'),
          ),
        ),
      );
    }
  });

  test('custom keeps its files and defaults to 20 steps at guidance 7', () {
    final model = ImageGenerationModel.custom(
      const ImageGenerationModelFiles(
        diffusionModel: '/m/unet.gguf',
        vae: '/m/vae.safetensors',
        clipL: '/m/clip_l.safetensors',
        clipG: '/m/clip_g.safetensors',
        t5xxl: '/m/t5.gguf',
        llm: '/m/qwen3.gguf',
      ),
    );

    expect(model.family, ImageGenerationModelFamily.custom);
    expect(model.files.paths.keys, [
      'diffusionModel',
      'vae',
      'clipL',
      'clipG',
      't5xxl',
      'llm',
    ]);
    expect(model.defaults.steps, 20);
    expect(model.defaults.guidanceScale, 7);
    expect(model.defaults.sampler, isNull);
    expect(model.defaults.scheduler, isNull);
    expect(model.defaults.flowShift, isNull);

    final tuned = ImageGenerationModel.custom(
      const ImageGenerationModelFiles(model: '/m/sd15.safetensors'),
      defaults: const ImageGenerationDefaults(steps: 8, guidanceScale: 2),
    );
    expect(tuned.defaults.steps, 8);
    expect(tuned.defaults.guidanceScale, 2);
  });

  test('options default to auto, physical cores and a memory check', () {
    const options = ImageGenerationOptions();

    expect(options.device, ImageGenerationDevice.auto);
    expect(options.threads, 0);
    expect(options.checkMemory, isTrue);
    expect(options.flashAttention, isNull);
    expect(options.vaeDirectConvolution, isNull);
  });
}
