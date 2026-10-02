import 'package:test/test.dart';

import 'package:llamadart/src/core/image/image_generation_model.dart';
import 'package:llamadart/src/core/models/model_source.dart';

void main() {
  test('a model keeps its files and defaults to 512x512, 20 steps at '
      'guidance 7 and the runtime sampling choices', () {
    final file = ModelSource.path('/m/sd15.safetensors');
    final model = ImageGenerationModel(
      files: ImageGenerationModelFiles(model: file),
    );

    expect(model.files.model, same(file));
    expect(model.defaults.width, 512);
    expect(model.defaults.height, 512);
    expect(model.defaults.steps, 20);
    expect(model.defaults.guidanceScale, 7);
    expect(model.defaults.sampler, isNull);
    expect(model.defaults.scheduler, isNull);
    expect(model.defaults.flowShift, isNull);
  });

  test('a model keeps the defaults it is given', () {
    final model = ImageGenerationModel(
      files: ImageGenerationModelFiles(
        model: ModelSource.path('/m/lightning.safetensors'),
      ),
      defaults: const ImageGenerationDefaults(
        width: 1024,
        height: 768,
        steps: 4,
        guidanceScale: 1,
        sampler: ImageGenerationSampler.euler,
        scheduler: ImageGenerationScheduler.sgmUniform,
        flowShift: 3,
      ),
    );

    final defaults = model.defaults;
    expect((defaults.width, defaults.height), (1024, 768));
    expect((defaults.steps, defaults.guidanceScale), (4, 1.0));
    expect(defaults.sampler, ImageGenerationSampler.euler);
    expect(defaults.scheduler, ImageGenerationScheduler.sgmUniform);
    expect(defaults.flowShift, 3);
  });

  test('sources lists every set role in role order, whatever the source '
      'kind', () {
    final unet = ModelSource.parse('hf://owner/repo@main/unet.gguf');
    final vae = ModelSource.url(
      Uri.parse('https://example.com/ae.safetensors'),
    );
    final llm = ModelSource.path('/m/qwen3.gguf');
    final files = ImageGenerationModelFiles(
      llm: llm,
      vae: vae,
      diffusionModel: unet,
    );

    expect(files.sources, {'diffusionModel': unet, 'vae': vae, 'llm': llm});
    expect(files.sources.keys, ['diffusionModel', 'vae', 'llm']);

    final every = ImageGenerationModelFiles(
      t5xxl: llm,
      clipG: llm,
      clipL: llm,
      taesd: llm,
      vae: llm,
      diffusionModel: llm,
      model: llm,
      llm: llm,
    );
    expect(every.sources.keys, [
      'model',
      'diffusionModel',
      'vae',
      'taesd',
      'clipL',
      'clipG',
      't5xxl',
      'llm',
    ]);
    expect(const ImageGenerationModelFiles().sources, isEmpty);
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
