import 'package:llamadart/llamadart.dart';
import 'package:llamadart_basic_example/services/image_cli_options.dart';
import 'package:test/test.dart';

ImageCliOptions _parse(List<String> arguments) =>
    parseImageCliOptions(createImageArgParser().parse(arguments));

Map<String, String> _keys(ImageCliOptions options) => {
  for (final MapEntry(key: role, value: source)
      in options.model.files.sources.entries)
    role: source.canonicalKey,
};

Map<String, String> _pinned(Map<String, ImageGenerationPresetFile> files) => {
  for (final MapEntry(key: role, value: file) in files.entries)
    role: file.source.canonicalKey,
};

void main() {
  test('defaults to the pinned SDXS checkpoint and a random seed', () {
    final options = _parse(const ['-p', 'a fox']);

    expect(options.preset, ImagePreset.sdxs);
    expect(options.modelSource, isNull);
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
    expect(options.model.family, ImageGenerationModelFamily.sdxs);
    expect(_keys(options), _pinned({'model': ImageGenerationPresetFile.sdxs}));
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
    expect(options.modelSource?.path, '/models/turbo.gguf');
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
    expect(
      options.model.files.sources.map(
        (role, source) => MapEntry(role, source.path),
      ),
      {'model': '/models/turbo.gguf', 'taesd': '/models/taesd.safetensors'},
    );
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
      _keys(options),
      _pinned({
        'model': ImageGenerationPresetFile.sdTurbo,
        'taesd': ImageGenerationPresetFile.taesd,
      }),
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

  test('desktop presets default to the library pinned files', () {
    final lightning = _parse(const ['--preset', 'sdxl-lightning', '-p', 'a']);
    expect(lightning.fileSources, isEmpty);
    expect(
      _keys(lightning),
      _pinned({'model': ImageGenerationPresetFile.sdxlLightning}),
    );
    expect((lightning.request.width, lightning.request.height), (null, null));

    expect(
      _keys(_parse(const ['--preset', 'flux1-schnell', '-p', 'a'])),
      _pinned({
        'diffusionModel': ImageGenerationPresetFile.flux1Schnell,
        'vae': ImageGenerationPresetFile.fluxVae,
        'clipL': ImageGenerationPresetFile.clipL,
        't5xxl': ImageGenerationPresetFile.t5xxl,
      }),
    );
    expect(
      _keys(_parse(const ['--preset', 'sd35-large-turbo', '-p', 'a'])),
      _pinned({
        'diffusionModel': ImageGenerationPresetFile.sd35LargeTurbo,
        'taesd': ImageGenerationPresetFile.taesd3,
        'clipL': ImageGenerationPresetFile.clipL,
        'clipG': ImageGenerationPresetFile.clipG,
        't5xxl': ImageGenerationPresetFile.t5xxl,
      }),
    );
    expect(
      _keys(_parse(const ['--preset', 'z-image-turbo', '-p', 'a'])),
      _pinned({
        'diffusionModel': ImageGenerationPresetFile.zImageTurbo,
        'vae': ImageGenerationPresetFile.fluxVae,
        'llm': ImageGenerationPresetFile.zImageTurboLlm,
      }),
    );
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
    expect(flux.model.files.sources.keys, [
      'diffusionModel',
      'taesd',
      'clipL',
      't5xxl',
    ]);
    expect(
      flux.taesdSource?.canonicalKey,
      ImageGenerationPresetFile.taef1.source.canonicalKey,
    );
    expect(flux.model.files.sources['t5xxl']?.path, '/m/t5.gguf');

    final sd35 = _parse(const [
      '--preset',
      'sd35-large-turbo',
      '--vae',
      '/m/sd3_vae.safetensors',
      '-p',
      'a',
    ]);
    expect(sd35.model.files.sources, isNot(contains('taesd')));
    expect(sd35.model.files.sources['vae']?.path, '/m/sd3_vae.safetensors');
  });

  test('desktop presets build their library models from given files', () {
    const files = {
      'vae': '/m/vae.safetensors',
      'taesd': '/m/tae.safetensors',
      'clipL': '/m/clip_l.gguf',
      'clipG': '/m/clip_g.gguf',
      't5xxl': '/m/t5.gguf',
      'llm': '/m/qwen3.gguf',
    };
    for (final (flag, family, roles) in const [
      (
        'sdxl-lightning',
        ImageGenerationModelFamily.sdxlLightning,
        ['model', 'vae', 'taesd'],
      ),
      (
        'flux1-schnell',
        ImageGenerationModelFamily.flux1Schnell,
        ['diffusionModel', 'vae', 'taesd', 'clipL', 't5xxl'],
      ),
      (
        'sd35-large-turbo',
        ImageGenerationModelFamily.sd35LargeTurbo,
        ['diffusionModel', 'vae', 'taesd', 'clipL', 'clipG', 't5xxl'],
      ),
      (
        'z-image-turbo',
        ImageGenerationModelFamily.zImageTurbo,
        ['diffusionModel', 'vae', 'llm'],
      ),
    ]) {
      final preset = ImagePreset.values.firstWhere((p) => p.flag == flag);
      final options = _parse([
        '--preset',
        flag,
        '-m',
        '/m/w',
        for (final MapEntry(key: role, value: path) in files.entries)
          if (preset.roles.contains(role) ||
              (role == 'taesd' && preset.taesd != null)) ...[
            '--${imageFileFlags[role]}',
            path,
          ],
        '-p',
        'a',
      ]);
      expect(options.model.family, family, reason: flag);
      expect(options.model.files.sources.keys, roles, reason: flag);
      expect(
        options.model.files.sources.values.every((source) => source.isLocal),
        isTrue,
        reason: flag,
      );
    }
  });

  test('names output files without an extension', () {
    final options = _parse(const ['-p', 'a', '-o', 'out']);

    expect(options.outputPathFor(2), 'out-2');
  });
}
