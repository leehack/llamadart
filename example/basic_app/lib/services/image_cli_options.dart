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

/// Default SDXL-Lightning checkpoint: `ByteDance/SDXL-Lightning`, pinned.
const String defaultSdxlLightningModelSource =
    'hf://ByteDance/SDXL-Lightning@c9a24f48e1c025556787b0c58dd67a091ece2e44/'
    'sdxl_lightning_4step.safetensors';

/// TAESDXL decoder for SDXL-Lightning: `madebyollin/taesdxl`, pinned.
const String defaultTaesdxlSource =
    'hf://madebyollin/taesdxl@b20258aaef75ef61e659c1e0f14f251cf0ad153e/'
    'diffusion_pytorch_model.safetensors';

const String _fluxRepository =
    'hf://second-state/FLUX.1-schnell-GGUF@'
    '8c45a2ba25e2d02bd34230989fb54983f39e44ec';

const String _sd35MediumRepository =
    'hf://second-state/stable-diffusion-3.5-medium-GGUF@'
    '58b78c305a43ddfcffe1ab54d7022995f61667ac';

/// Default FLUX.1-schnell transformer: `second-state/FLUX.1-schnell-GGUF`
/// Q4_0, pinned.
const String defaultFlux1SchnellModelSource =
    '$_fluxRepository/flux1-schnell-Q4_0.gguf';

/// FLUX autoencoder, also used by Z-Image-Turbo:
/// `second-state/FLUX.1-schnell-GGUF`, pinned.
const String defaultFluxVaeSource = '$_fluxRepository/ae.safetensors';

/// TAEF1 decoder for FLUX: `madebyollin/taef1`, pinned.
const String defaultTaef1Source =
    'hf://madebyollin/taef1@b1b2d00e9e440cfbf3dedb34266864da86016ceb/'
    'diffusion_pytorch_model.safetensors';

/// CLIP-L text encoder for FLUX and SD 3.5:
/// `second-state/stable-diffusion-3.5-medium-GGUF` Q8_0, pinned.
const String defaultClipLSource = '$_sd35MediumRepository/clip_l-Q8_0.gguf';

/// CLIP-G text encoder for SD 3.5:
/// `second-state/stable-diffusion-3.5-medium-GGUF` Q8_0, pinned.
const String defaultClipGSource = '$_sd35MediumRepository/clip_g-Q8_0.gguf';

/// T5-XXL text encoder for FLUX and SD 3.5:
/// `second-state/stable-diffusion-3.5-medium-GGUF` Q8_0, pinned.
const String defaultT5xxlSource = '$_sd35MediumRepository/t5xxl-Q8_0.gguf';

/// Default SD 3.5 Large Turbo transformer:
/// `city96/stable-diffusion-3.5-large-turbo-gguf` Q4_0, pinned.
const String defaultSd35LargeTurboModelSource =
    'hf://city96/stable-diffusion-3.5-large-turbo-gguf'
    '@527c5548afc123f309238ca6bce7dfe3349aa997/sd3.5_large_turbo-Q4_0.gguf';

/// TAESD3 decoder for SD 3.5: `madebyollin/taesd3`, pinned. The SD 3.5 VAE
/// is in a gated repository, so the preset decodes with TAESD3 unless `--vae`
/// names one.
const String defaultTaesd3Source =
    'hf://madebyollin/taesd3@d58dcaccd2b36fcb7a6b9e93c1cc507acab5a778/'
    'diffusion_pytorch_model.safetensors';

/// Default Z-Image-Turbo transformer: `leejet/Z-Image-Turbo-GGUF` Q4_K,
/// pinned.
const String defaultZImageTurboModelSource =
    'hf://leejet/Z-Image-Turbo-GGUF@c61c0e422dc8b541b7548cf33a4ef8302b0f8085/'
    'z_image_turbo-Q4_K.gguf';

/// Qwen3-4B text encoder for Z-Image-Turbo:
/// `unsloth/Qwen3-4B-Instruct-2507-GGUF` Q4_K_M, pinned.
const String defaultQwen3LlmSource =
    'hf://unsloth/Qwen3-4B-Instruct-2507-GGUF'
    '@a06e946bb6b655725eafa393f4a9745d460374c9/'
    'Qwen3-4B-Instruct-2507-Q4_K_M.gguf';

/// Model presets the image example accepts.
enum ImagePreset {
  /// SDXS-512: one step, guidance 1.
  sdxs('sdxs', defaultSdxsModelSource),

  /// SD-Turbo: one step by default, optional TAESD.
  sdTurbo('sd-turbo', defaultSdTurboModelSource, taesd: defaultTaesdSource),

  /// SDXL-Lightning: 4 steps at 1024x1024, optional VAE or TAESDXL.
  sdxlLightning(
    'sdxl-lightning',
    defaultSdxlLightningModelSource,
    taesd: defaultTaesdxlSource,
    roles: {'vae'},
  ),

  /// FLUX.1-schnell: 4 steps at 1024x1024 from split files.
  flux1Schnell(
    'flux1-schnell',
    defaultFlux1SchnellModelSource,
    taesd: defaultTaef1Source,
    roles: {'vae', 'clipL', 't5xxl'},
    defaults: {
      'vae': defaultFluxVaeSource,
      'clipL': defaultClipLSource,
      't5xxl': defaultT5xxlSource,
    },
  ),

  /// SD 3.5 Large Turbo: 4 steps at 1024x1024 from split files.
  sd35LargeTurbo(
    'sd35-large-turbo',
    defaultSd35LargeTurboModelSource,
    taesd: defaultTaesd3Source,
    roles: {'vae', 'clipL', 'clipG', 't5xxl'},
    defaults: {
      'taesd': defaultTaesd3Source,
      'clipL': defaultClipLSource,
      'clipG': defaultClipGSource,
      't5xxl': defaultT5xxlSource,
    },
  ),

  /// Z-Image-Turbo: 8 steps at 1024x1024 with a Qwen3 text encoder.
  zImageTurbo(
    'z-image-turbo',
    defaultZImageTurboModelSource,
    roles: {'vae', 'llm'},
    defaults: {'vae': defaultFluxVaeSource, 'llm': defaultQwen3LlmSource},
  );

  const ImagePreset(
    this.flag,
    this.modelSource, {
    this.taesd,
    this.roles = const {},
    this.defaults = const {},
  });

  /// Value of `--preset`.
  final String flag;

  /// Pinned main weights: the checkpoint, or the diffusion model of a split
  /// preset.
  final String modelSource;

  /// Pinned tiny autoencoder for `--taesd default`, or `null` when the
  /// preset takes none.
  final String? taesd;

  /// File roles besides the main weights and TAESD that the preset takes.
  final Set<String> roles;

  /// Pinned sources for the roles the user leaves unset.
  final Map<String, String> defaults;
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

  /// Main weights source.
  final ModelSource modelSource;

  /// Sources of the other files, keyed by role as in [imageFileFlags].
  final Map<String, ModelSource> fileSources;

  /// TAESD source, or `null` to decode with the full VAE.
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

  /// The engine model for [preset] with the resolved local [modelPath] and
  /// [files], keyed like [fileSources].
  ImageGenerationModel model(String modelPath, Map<String, String> files) =>
      switch (preset) {
        ImagePreset.sdxs => ImageGenerationModel.sdxs(modelPath),
        ImagePreset.sdTurbo => ImageGenerationModel.sdTurbo(
          modelPath,
          taesdPath: files['taesd'],
        ),
        ImagePreset.sdxlLightning => ImageGenerationModel.sdxlLightning(
          modelPath,
          vaePath: files['vae'],
          taesdPath: files['taesd'],
        ),
        ImagePreset.flux1Schnell => ImageGenerationModel.flux1Schnell(
          diffusionModelPath: modelPath,
          clipLPath: files['clipL']!,
          t5xxlPath: files['t5xxl']!,
          vaePath: files['vae'],
          taesdPath: files['taesd'],
        ),
        ImagePreset.sd35LargeTurbo => ImageGenerationModel.sd35LargeTurbo(
          diffusionModelPath: modelPath,
          clipLPath: files['clipL']!,
          clipGPath: files['clipG']!,
          t5xxlPath: files['t5xxl']!,
          vaePath: files['vae'],
          taesdPath: files['taesd'],
        ),
        ImagePreset.zImageTurbo => ImageGenerationModel.zImageTurbo(
          diffusionModelPath: modelPath,
          llmPath: files['llm']!,
          vaePath: files['vae']!,
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
  final decoderGiven = given.containsKey('vae') || given.containsKey('taesd');
  final texts = <String, String>{
    for (final MapEntry(key: role, value: text) in preset.defaults.entries)
      if (!decoderGiven || (role != 'vae' && role != 'taesd')) role: text,
    ...given,
  };
  return ImageCliOptions(
    preset: preset,
    modelSource: _source(
      'model',
      results['model'] as String? ?? preset.modelSource,
    ),
    fileSources: {
      for (final MapEntry(key: role, value: text) in texts.entries)
        role: role == 'taesd' && text == 'default'
            ? ModelSource.parse(preset.taesd!)
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
