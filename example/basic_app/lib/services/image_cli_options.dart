import 'package:args/args.dart';
import 'package:llamadart/llamadart.dart';

/// Default SDXS checkpoint: `concedo/sdxs-512-tinySDdistilled-GGUF`, pinned.
const String defaultSdxsModelSource =
    'hf://concedo/sdxs-512-tinySDdistilled-GGUF'
    '@3144d898d61492f8382ffcabec055733fc5b2a0e/'
    'sdxs-512-tinySDdistilled_Q8_0.gguf';

/// Default SD-Turbo checkpoint: `Green-Sky/SD-Turbo-GGUF`, pinned.
const String defaultSdTurboModelSource =
    'hf://Green-Sky/SD-Turbo-GGUF@19a31586d02d64a73b4419bc193b3ecfaf38e1f0/'
    'sd_turbo-f16-q8_0.gguf';

/// TAESD decoder for SD-Turbo: `madebyollin/taesd`, pinned.
const String defaultTaesdSource =
    'hf://madebyollin/taesd@614f76814bbe30edbe2e627ace1c2234c81a2c0e/'
    'diffusion_pytorch_model.safetensors';

/// Model presets the image example accepts.
enum ImagePreset {
  /// SDXS-512: one step, guidance 1.
  sdxs('sdxs'),

  /// SD-Turbo: one step by default, optional TAESD.
  sdTurbo('sd-turbo');

  const ImagePreset(this.flag);

  /// Value of `--preset`.
  final String flag;
}

/// Parsed command-line options for the image example.
final class ImageCliOptions {
  /// Creates parsed options.
  const ImageCliOptions({
    required this.preset,
    required this.modelSource,
    required this.taesdSource,
    required this.request,
    required this.outputPath,
    required this.device,
    required this.threads,
  });

  /// Model preset.
  final ImagePreset preset;

  /// Checkpoint source.
  final ModelSource modelSource;

  /// TAESD source for SD-Turbo, or `null` to decode with the full VAE.
  final ModelSource? taesdSource;

  /// Generation request.
  final ImageGenerationRequest request;

  /// PNG output path. With `--count` above 1, later images get `-1`, `-2`
  /// suffixes.
  final String outputPath;

  /// Device to run on.
  final ImageGenerationDevice device;

  /// CPU threads; 0 uses the physical cores.
  final int threads;

  /// The engine model for [preset] with the resolved local files.
  ImageGenerationModel model(String modelPath, String? taesdPath) =>
      switch (preset) {
        ImagePreset.sdxs => ImageGenerationModel.sdxs(modelPath),
        ImagePreset.sdTurbo => ImageGenerationModel.sdTurbo(
          modelPath,
          taesdPath: taesdPath,
        ),
      };

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
  return ArgParser()
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
          'Checkpoint: local path, HTTP(S) URL, or hf:// source. Defaults to '
          'the pinned SDXS or SD-Turbo GGUF for --preset.',
    )
    ..addOption(
      'taesd',
      help:
          'TAESD decoder for sd-turbo (local path, URL, or hf:// source), or '
          '"default" for the pinned madebyollin/taesd.',
    )
    ..addOption('prompt', abbr: 'p', help: 'Prompt (required).')
    ..addOption('negative', help: 'Negative prompt.', defaultsTo: '')
    ..addOption('width', help: 'Width in pixels.', defaultsTo: '512')
    ..addOption('height', help: 'Height in pixels.', defaultsTo: '512')
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
/// model source, or for `--taesd` with the sdxs preset. Range checks are left
/// to the engine.
ImageCliOptions parseImageCliOptions(ArgResults results) {
  final preset = ImagePreset.values.firstWhere(
    (preset) => preset.flag == results['preset'],
  );
  final prompt = results['prompt'] as String?;
  if (prompt == null) {
    throw const FormatException('--prompt is required.');
  }
  final taesdText = results['taesd'] as String?;
  if (taesdText != null && preset != ImagePreset.sdTurbo) {
    throw const FormatException('--taesd applies only to --preset sd-turbo.');
  }
  final modelText =
      results['model'] as String? ??
      switch (preset) {
        ImagePreset.sdxs => defaultSdxsModelSource,
        ImagePreset.sdTurbo => defaultSdTurboModelSource,
      };
  return ImageCliOptions(
    preset: preset,
    modelSource: _source('model', modelText),
    taesdSource: switch (taesdText) {
      null => null,
      'default' => ModelSource.parse(defaultTaesdSource),
      final text => _source('taesd', text),
    },
    request: ImageGenerationRequest(
      prompt: prompt,
      negativePrompt: results['negative'] as String,
      width: _int(results, 'width')!,
      height: _int(results, 'height')!,
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
          'Generates a PNG with SDXS or SD-Turbo through the opt-in '
          'stable_diffusion runtime. Ctrl-C cancels.',
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
