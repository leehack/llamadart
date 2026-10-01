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
    expect(options.request.width, 512);
    expect(options.request.height, 512);
    expect(options.request.steps, isNull);
    expect(options.request.guidanceScale, isNull);
    expect(options.request.seed, isNull);
    expect(options.request.count, 1);
    expect(options.outputPath, 'image.png');
    expect(options.device, ImageGenerationDevice.auto);
    expect(options.threads, 0);
    expect(
      options.model('/m/sdxs.gguf', null).family,
      ImageGenerationModelFamily.sdxs,
    );
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
    final model = options.model('/m/turbo.gguf', '/m/taesd.safetensors');
    expect(model.files.taesd, '/m/taesd.safetensors');
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

  test('names output files without an extension', () {
    final options = _parse(const ['-p', 'a', '-o', 'out']);

    expect(options.outputPathFor(2), 'out-2');
  });
}
