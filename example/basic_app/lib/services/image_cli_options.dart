import 'package:args/args.dart';
import 'package:llamadart/llamadart.dart';

/// Model presets the image example accepts.
enum ImagePreset {
  /// SDXS-512: one step, guidance 1.
  sdxs('sdxs'),

  /// SD-Turbo: one step by default, optional TAESD.
  sdTurbo('sd-turbo', taesd: ImageGenerationPresetFile.taesd),

  /// SDXL-Lightning: 4 steps at 1024x1024, optional VAE or TAESDXL.
  sdxlLightning(
    'sdxl-lightning',
    taesd: ImageGenerationPresetFile.taesdxl,
    roles: {'vae'},
  ),

  /// FLUX.1-schnell: 4 steps at 1024x1024 from split files.
  flux1Schnell(
    'flux1-schnell',
    taesd: ImageGenerationPresetFile.taef1,
    roles: {'vae', 'clipL', 't5xxl'},
  ),

  /// SD 3.5 Large Turbo: 4 steps at 1024x1024 from split files.
  sd35LargeTurbo(
    'sd35-large-turbo',
    taesd: ImageGenerationPresetFile.taesd3,
    roles: {'vae', 'clipL', 'clipG', 't5xxl'},
  ),

  /// Z-Image-Turbo: 8 steps at 1024x1024 with a Qwen3 text encoder.
  zImageTurbo('z-image-turbo', roles: {'vae', 'llm'});

  const ImagePreset(this.flag, {this.taesd, this.roles = const {}});

  /// Value of `--preset`.
  final String flag;

  /// Pinned tiny autoencoder for `--taesd default`, or `null` when the
  /// preset takes none.
  final ImageGenerationPresetFile? taesd;

  /// File roles besides the main weights and TAESD that the preset takes.
  final Set<String> roles;
}

/// Command-line flag of each file role besides the main weights.
const Map<String, String> imageFileFlags = {
  'vae': 'vae',
  'taesd': 'taesd',
  'clipL': 'clip-l',
  'clipG': 'clip-g',
  't5xxl': 't5xxl',
  'llm': 'llm',
};

/// Parsed command-line options for the image example.
final class ImageCliOptions {
  /// Creates parsed options.
  const ImageCliOptions({
    required this.preset,
    required this.modelSource,
    required this.fileSources,
    required this.request,
    required this.outputPath,
    required this.device,
    required this.threads,
  });

  /// Model preset.
  final ImagePreset preset;

  /// Main weights source, or `null` for the preset's pinned file.
  final ModelSource? modelSource;

  /// Sources of the other files given on the command line, keyed by role as
  /// in [imageFileFlags]. The preset downloads its pinned file for any other
  /// role it needs.
  final Map<String, ModelSource> fileSources;

  /// TAESD source, or `null` to decode with the preset's default decoder.
  ModelSource? get taesdSource => fileSources['taesd'];

  /// Generation request.
  final ImageGenerationRequest request;

  /// PNG output path. With `--count` above 1, later images get `-1`, `-2`
  /// suffixes.
  final String outputPath;

  /// Device to run on.
  final ImageGenerationDevice device;

  /// CPU threads; 0 uses the physical cores.
  final int threads;

  /// The engine model for [preset] with the given sources.
  ImageGenerationModel get model {
    final files = fileSources;
    return switch (preset) {
      ImagePreset.sdxs => ImageGenerationModel.sdxsPreset(model: modelSource),
      ImagePreset.sdTurbo => ImageGenerationModel.sdTurboPreset(
        model: modelSource,
        taesd: files['taesd'],
      ),
      ImagePreset.sdxlLightning => ImageGenerationModel.sdxlLightningPreset(
        model: modelSource,
        vae: files['vae'],
        taesd: files['taesd'],
      ),
      ImagePreset.flux1Schnell => ImageGenerationModel.flux1SchnellPreset(
        diffusionModel: modelSource,
        clipL: files['clipL'],
        t5xxl: files['t5xxl'],
        vae: files['vae'],
        taesd: files['taesd'],
      ),
      ImagePreset.sd35LargeTurbo => ImageGenerationModel.sd35LargeTurboPreset(
        diffusionModel: modelSource,
        clipL: files['clipL'],
        clipG: files['clipG'],
        t5xxl: files['t5xxl'],
        vae: files['vae'],
        taesd: files['taesd'],
      ),
      ImagePreset.zImageTurbo => ImageGenerationModel.zImageTurboPreset(
        diffusionModel: modelSource,
        llm: files['llm'],
        vae: files['vae'],
      ),
    };
  }

  /// Output path of image [index].
  String outputPathFor(int index) {
    if (index == 0) {
      return outputPath;
    }
    final dot = outputPath.lastIndexOf('.');
    return dot <= 0
        ? '$outputPath-$index'
        : '${outputPath.substring(0, dot)}-$index${outputPath.substring(dot)}';
  }
}

/// Creates the argument parser for the image example.
ArgParser createImageArgParser() {
  final parser = ArgParser()
    ..addOption(
      'preset',
      help: 'Model preset.',
      allowed: [for (final preset in ImagePreset.values) preset.flag],
      defaultsTo: ImagePreset.sdxs.flag,
    )
    ..addOption(
      'model',
      abbr: 'm',
      help:
          'Checkpoint, or the diffusion model of a split preset: local path, '
          'HTTP(S) URL, or hf:// source. Defaults to the pinned file of '
          '--preset.',
    )
    ..addOption(
      'taesd',
      help:
          'Tiny autoencoder decoder (local path, URL, or hf:// source), or '
          '"default" for the pinned one of --preset. Not for sdxs or '
          'z-image-turbo.',
    );
  for (final role in ['vae', 'clipL', 'clipG', 't5xxl', 'llm']) {
    final presets = [
      for (final preset in ImagePreset.values)
        if (preset.roles.contains(role)) preset.flag,
    ];
    parser.addOption(
      imageFileFlags[role]!,
      help: '$role file for ${presets.join(', ')}; defaults to the pinned one.',
    );
  }
  return parser
    ..addOption('prompt', abbr: 'p', help: 'Prompt (required).')
    ..addOption('negative', help: 'Negative prompt.', defaultsTo: '')
    ..addOption('width', help: 'Width in pixels (default: the model size).')
    ..addOption('height', help: 'Height in pixels (default: the model size).')
    ..addOption('steps', help: 'Sampling steps (default: the preset).')
    ..addOption('guidance', help: 'Guidance scale (default: the preset).')
    ..addOption('seed', help: 'Seed (default: random).')
    ..addOption('count', help: 'Number of images.', defaultsTo: '1')
    ..addOption('out', abbr: 'o', help: 'PNG path.', defaultsTo: 'image.png')
    ..addOption(
      'device',
      help: 'Device.',
      allowed: [for (final device in ImageGenerationDevice.values) device.name],
      defaultsTo: ImageGenerationDevice.auto.name,
    )
    ..addOption('threads', help: 'CPU threads (0: all cores).', defaultsTo: '0')
    ..addFlag('help', abbr: 'h', help: 'Show this help.', negatable: false);
}

/// Parses [results] from [createImageArgParser].
///
/// Throws [FormatException] without `--prompt`, for a malformed number or
/// model source, or for a file flag the preset does not take. Range checks
/// are left to the engine.
ImageCliOptions parseImageCliOptions(ArgResults results) {
  final preset = ImagePreset.values.firstWhere(
    (preset) => preset.flag == results['preset'],
  );
  final prompt = results['prompt'] as String?;
  if (prompt == null) {
    throw const FormatException('--prompt is required.');
  }
  final given = <String, String>{
    for (final MapEntry(key: role, value: flag) in imageFileFlags.entries)
      if (results[flag] case final String text) role: text,
  };
  for (final role in given.keys) {
    final accepted = role == 'taesd'
        ? preset.taesd != null
        : preset.roles.contains(role);
    if (!accepted) {
      throw FormatException(
        '--${imageFileFlags[role]} does not apply to --preset ${preset.flag}.',
      );
    }
  }
  final model = results['model'] as String?;
  return ImageCliOptions(
    preset: preset,
    modelSource: model == null ? null : _source('model', model),
    fileSources: {
      for (final MapEntry(key: role, value: text) in given.entries)
        role: role == 'taesd' && text == 'default'
            ? preset.taesd!.source
            : _source(imageFileFlags[role]!, text),
    },
    request: ImageGenerationRequest(
      prompt: prompt,
      negativePrompt: results['negative'] as String,
      width: _int(results, 'width'),
      height: _int(results, 'height'),
      steps: _int(results, 'steps'),
      guidanceScale: _double(results, 'guidance'),
      seed: _int(results, 'seed'),
      count: _int(results, 'count')!,
    ),
    outputPath: results['out'] as String,
    device: ImageGenerationDevice.values.byName(results['device'] as String),
    threads: _int(results, 'threads')!,
  );
}

/// Builds the help text for the image example.
String buildImageHelpText(ArgParser parser) {
  return (StringBuffer()
        ..writeln('llamadart Image Generation Example (experimental)')
        ..writeln()
        ..writeln(
          'Generates a PNG through the opt-in stable_diffusion runtime. sdxs '
          'and sd-turbo fit phones; the other presets download 7 to 12 GB '
          'and need a desktop GPU or a Mac with 16 GB or more. Ctrl-C '
          'cancels.',
        )
        ..writeln()
        ..writeln(parser.usage)
        ..writeln()
        ..writeln('Examples:')
        ..writeln(
          '  dart run bin/llamadart_image_example.dart '
          "-p 'a red fox in autumn leaves' --seed 42",
        )
        ..writeln(
          '  dart run bin/llamadart_image_example.dart --preset sd-turbo '
          "--taesd default --steps 4 -p 'a lighthouse at dusk'",
        )
        ..writeln(
          '  dart run bin/llamadart_image_example.dart --preset '
          "sdxl-lightning --taesd default -p 'a lighthouse at dusk'",
        ))
      .toString();
}

ModelSource _source(String option, String text) {
  try {
    return ModelSource.parse(text);
  } on ArgumentError catch (error) {
    throw FormatException('--$option: ${error.message}');
  }
}

int? _int(ArgResults results, String option) {
  final text = results[option] as String?;
  if (text == null) {
    return null;
  }
  return int.tryParse(text) ??
      (throw FormatException('--$option must be an integer: $text'));
}

double? _double(ArgResults results, String option) {
  final text = results[option] as String?;
  if (text == null) {
    return null;
  }
  return double.tryParse(text) ??
      (throw FormatException('--$option must be a number: $text'));
}
