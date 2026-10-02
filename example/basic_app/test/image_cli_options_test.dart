import 'package:llamadart/llamadart.dart';
import 'package:llamadart_basic_example/services/image_cli_options.dart';
import 'package:test/test.dart';

ImageCliOptions _parse(List<String> arguments) =>
    parseImageCliOptions(createImageArgParser().parse(arguments));

void main() {
  test('defaults to the pinned SDXS checkpoint and a random seed', () {
    final options = _parse(const ['-p', 'a fox']);

    expect(options.preset, ImagePreset.sdxs);
    expect(
      options.modelSource.canonicalKey,
      ModelSource.parse(defaultSdxsModelSource).canonicalKey,
    );
    expect(options.taesdSource, isNull);
    expect(options.request.prompt, 'a fox');
    expect(options.request.width, isNull);
    expect(options.request.height, isNull);
    expect(options.request.steps, isNull);
    expect(options.request.guidanceScale, isNull);
    expect(options.request.seed, isNull);
    expect(options.request.count, 1);
    expect(options.outputPath, 'image.png');
    expect(options.device, ImageGenerationDevice.auto);
    expect(options.threads, 0);
    final model = options.model;
    expect(model.files.sources.keys, ['model']);
    expect((model.defaults.steps, model.defaults.guidanceScale), (1, 1.0));
    expect(options.engineOptions.vaeDirectConvolution, isFalse);
  });

  test('reads every option for sd-turbo', () {
    final options = _parse(const [
      '--preset',
      'sd-turbo',
      '-m',
      '/models/turbo.gguf',
      '--taesd',
      '/models/taesd.safetensors',
      '-p',
      'a lighthouse',
      '--negative',
      'blurry',
      '--width',
      '256',
      '--height',
      '320',
      '--steps',
      '4',
      '--guidance',
      '1.5',
      '--seed',
      '42',
      '--count',
      '2',
      '-o',
      'out/light.png',
      '--device',
      'cpu',
      '--threads',
      '6',
    ]);

    expect(options.preset, ImagePreset.sdTurbo);
    expect(options.modelSource.path, '/models/turbo.gguf');
    expect(options.taesdSource?.path, '/models/taesd.safetensors');
    expect(options.request.negativePrompt, 'blurry');
    expect((options.request.width, options.request.height), (256, 320));
    expect(options.request.steps, 4);
    expect(options.request.guidanceScale, 1.5);
    expect(options.request.seed, 42);
    expect(options.request.count, 2);
    expect(options.device, ImageGenerationDevice.cpu);
    expect(options.threads, 6);
    expect(options.outputPathFor(0), 'out/light.png');
    expect(options.outputPathFor(1), 'out/light-1.png');
    final model = options.model;
    expect(model.files.model?.path, '/models/turbo.gguf');
    expect(model.files.taesd?.path, '/models/taesd.safetensors');
    expect((model.defaults.steps, model.defaults.width), (1, 512));
    expect(options.engineOptions.device, ImageGenerationDevice.cpu);
    expect(options.engineOptions.threads, 6);
    expect(options.engineOptions.vaeDirectConvolution, isNull);
  });

  test('sd-turbo defaults to the pinned checkpoint and --taesd default', () {
    final options = _parse(const [
      '--preset',
      'sd-turbo',
      '--taesd',
      'default',
      '-p',
      'a',
    ]);

    expect(
      options.modelSource.canonicalKey,
      ModelSource.parse(defaultSdTurboModelSource).canonicalKey,
    );
    expect(
      options.taesdSource?.canonicalKey,
      ModelSource.parse(defaultTaesdSource).canonicalKey,
    );
  });

  test('rejects a missing prompt, malformed numbers and sdxs TAESD', () {
    for (final (arguments, message) in const [
      (<String>[], '--prompt'),
      (['-p', 'a', '--width', 'wide'], '--width'),
      (['-p', 'a', '--guidance', 'high'], '--guidance'),
      (['-p', 'a', '--taesd', 'default'], '--taesd'),
      (['--preset', 'sd-turbo', '-p', 'a', '--vae', '/v'], '--vae'),
      (
        ['--preset', 'z-image-turbo', '-p', 'a', '--taesd', 'default'],
        '--taesd',
      ),
      (['--preset', 'flux1-schnell', '-p', 'a', '--clip-g', '/g'], '--clip-g'),
      (['--preset', 'sdxl-lightning', '-p', 'a', '--llm', '/l'], '--llm'),
      (['-p', 'a', '--model', 'ftp://host/m.gguf'], '--model'),
    ]) {
      expect(
        () => _parse(arguments),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains(message),
          ),
        ),
        reason: '$arguments',
      );
    }
  });

  test('desktop presets default to pinned files and the model size', () {
    String key(String source) => ModelSource.parse(source).canonicalKey;
    Map<String, String> keys(ImageCliOptions options) => {
      for (final MapEntry(key: role, value: source)
          in options.fileSources.entries)
        role: source.canonicalKey,
    };

    final lightning = _parse(const ['--preset', 'sdxl-lightning', '-p', 'a']);
    expect(
      lightning.modelSource.canonicalKey,
      key(defaultSdxlLightningModelSource),
    );
    expect(lightning.fileSources, isEmpty);
    expect((lightning.request.width, lightning.request.height), (null, null));

    final flux = _parse(const ['--preset', 'flux1-schnell', '-p', 'a']);
    expect(flux.modelSource.canonicalKey, key(defaultFlux1SchnellModelSource));
    expect(keys(flux), {
      'vae': key(defaultFluxVaeSource),
      'clipL': key(defaultClipLSource),
      't5xxl': key(defaultT5xxlSource),
    });

    final sd35 = _parse(const ['--preset', 'sd35-large-turbo', '-p', 'a']);
    expect(keys(sd35), {
      'taesd': key(defaultTaesd3Source),
      'clipL': key(defaultClipLSource),
      'clipG': key(defaultClipGSource),
      't5xxl': key(defaultT5xxlSource),
    });

    final zImage = _parse(const ['--preset', 'z-image-turbo', '-p', 'a']);
    expect(zImage.modelSource.canonicalKey, key(defaultZImageTurboModelSource));
    expect(keys(zImage), {
      'vae': key(defaultFluxVaeSource),
      'llm': key(defaultQwen3LlmSource),
    });
  });

  test('a given decoder replaces the default one, and files override '
      'defaults', () {
    final flux = _parse(const [
      '--preset',
      'flux1-schnell',
      '--taesd',
      'default',
      '--t5xxl',
      '/m/t5.gguf',
      '-p',
      'a',
    ]);
    expect(flux.fileSources.keys, unorderedEquals(['taesd', 'clipL', 't5xxl']));
    expect(
      flux.taesdSource?.canonicalKey,
      ModelSource.parse(defaultTaef1Source).canonicalKey,
    );
    expect(flux.fileSources['t5xxl']?.path, '/m/t5.gguf');

    final sd35 = _parse(const [
      '--preset',
      'sd35-large-turbo',
      '--vae',
      '/m/sd3_vae.safetensors',
      '-p',
      'a',
    ]);
    expect(sd35.taesdSource, isNull);
    expect(sd35.fileSources['vae']?.path, '/m/sd3_vae.safetensors');
  });

  test('desktop presets build models with their roles and settings', () {
    for (final (flag, roles, steps) in const [
      ('sdxl-lightning', ['model'], 4),
      ('flux1-schnell', ['diffusionModel', 'vae', 'clipL', 't5xxl'], 4),
      (
        'sd35-large-turbo',
        ['diffusionModel', 'taesd', 'clipL', 'clipG', 't5xxl'],
        4,
      ),
      ('z-image-turbo', ['diffusionModel', 'vae', 'llm'], 8),
    ]) {
      final model = _parse(['--preset', flag, '-p', 'a']).model;
      expect(model.files.sources.keys, roles, reason: flag);
      expect(model.defaults.steps, steps, reason: flag);
      expect(model.defaults.guidanceScale, 1, reason: flag);
      expect((model.defaults.width, model.defaults.height), (1024, 1024));
    }
    final lightning = _parse(const ['--preset', 'sdxl-lightning', '-p', 'a']);
    expect(lightning.model.defaults.sampler, ImageGenerationSampler.euler);
    expect(
      lightning.model.defaults.scheduler,
      ImageGenerationScheduler.sgmUniform,
    );
    expect(lightning.engineOptions.vaeDirectConvolution, isNull);
  });

  test('names output files without an extension', () {
    final options = _parse(const ['-p', 'a', '-o', 'out']);

    expect(options.outputPathFor(2), 'out-2');
  });
}
