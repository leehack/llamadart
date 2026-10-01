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
