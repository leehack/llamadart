import 'package:llamadart/llamadart.dart';

import 'downloadable_model.dart';

/// A downloadable image-generation model for the chat app's image screen.
class ImageModelProfile {
  /// Stable model identifier.
  final String id;

  /// User-facing model name.
  final String name;

  /// Short user-facing model description.
  final String description;

  /// Preset family passed to `ImageGenerationModel`.
  final ImageGenerationModelFamily family;

  /// Single-file checkpoint.
  final RemoteModelAssetSource modelSource;

  /// Optional TAESD decoder weights.
  final RemoteModelAssetSource? taesdSource;

  /// Memory guidance shown before download; the load-time memory check in
  /// `ImageGenerationEngine.load` is what actually refuses a model.
  final String? memoryNote;

  /// Whether the app recommends this model as the default choice.
  final bool isRecommended;

  /// Creates an immutable image model profile.
  const ImageModelProfile({
    required this.id,
    required this.name,
    required this.description,
    required this.family,
    required this.modelSource,
    this.taesdSource,
    this.memoryNote,
    this.isRecommended = false,
  });

  /// Every remote file this profile needs, model first.
  List<RemoteModelAssetSource> get sources => <RemoteModelAssetSource>[
    modelSource,
    ?taesdSource,
  ];

  /// Combined download size of [sources].
  int get sizeBytes =>
      sources.fold(0, (total, source) => total + (source.sizeBytes ?? 0));

  /// Human-readable combined download size.
  String get sizeLabel {
    if (sizeBytes >= 1000 * 1000 * 1000) {
      return '${(sizeBytes / (1000 * 1000 * 1000)).toStringAsFixed(1)} GB';
    }
    return '${(sizeBytes / (1000 * 1000)).round()} MB';
  }

  /// Builds the library model for installed files.
  ImageGenerationModel buildModel({
    required String modelPath,
    String? taesdPath,
  }) => switch (family) {
    ImageGenerationModelFamily.sdxs => ImageGenerationModel.sdxs(modelPath),
    ImageGenerationModelFamily.sdTurbo => ImageGenerationModel.sdTurbo(
      modelPath,
      taesdPath: taesdPath,
    ),
    ImageGenerationModelFamily.custom => ImageGenerationModel.custom(
      ImageGenerationModelFiles(model: modelPath, taesd: taesdPath),
    ),
  };

  /// Sampling defaults of the library preset.
  ImageGenerationDefaults get defaults => buildModel(modelPath: '').defaults;

  /// SDXS-512: a one-step distilled SD 1.x-size model that fits phones.
  static const ImageModelProfile sdxs = ImageModelProfile(
    id: 'sdxs-512-q8_0',
    name: 'SDXS-512',
    description: 'One-step distilled model that fits most phones.',
    family: ImageGenerationModelFamily.sdxs,
    modelSource: RemoteModelAssetSource(
      url:
          'https://huggingface.co/concedo/sdxs-512-tinySDdistilled-GGUF/resolve/3144d898d61492f8382ffcabec055733fc5b2a0e/sdxs-512-tinySDdistilled_Q8_0.gguf?download=true',
      filename: 'sdxs-512-tinySDdistilled_Q8_0.gguf',
      sizeBytes: 682847200,
      sha256:
          '409ab23582ee074c6b9d5395784fc0741b0599fb9d138686c69087c71678eb6a',
    ),
    isRecommended: true,
  );

  /// SD-Turbo with the TAESD decoder: more detail, about three times the
  /// memory of SDXS.
  static const ImageModelProfile sdTurbo = ImageModelProfile(
    id: 'sd-turbo-q8_0-taesd',
    name: 'SD-Turbo + TAESD',
    description: 'SD 2.1 Turbo with the tiny TAESD decoder; 1 to 4 steps.',
    family: ImageGenerationModelFamily.sdTurbo,
    modelSource: RemoteModelAssetSource(
      url:
          'https://huggingface.co/Green-Sky/SD-Turbo-GGUF/resolve/19a31586d02d64a73b4419bc193b3ecfaf38e1f0/sd_turbo-f16-q8_0.gguf?download=true',
      filename: 'sd_turbo-f16-q8_0.gguf',
      sizeBytes: 2023745376,
      sha256:
          'd50be7655f0a554cf8041c145d88b210bd5f3c545423119dee62ae08cae51580',
    ),
    taesdSource: RemoteModelAssetSource(
      url:
          'https://huggingface.co/madebyollin/taesd/resolve/614f76814bbe30edbe2e627ace1c2234c81a2c0e/diffusion_pytorch_model.safetensors?download=true',
      filename: 'taesd.safetensors',
      sizeBytes: 9793292,
      sha256:
          'db169d69145ec4ff064e49d99c95fa05d3eb04ee453de35824a6d0f325513549',
    ),
    memoryNote:
        'Needs about 3.1 GB of free memory; phones with less than 8 GB of '
        'RAM usually cannot load it.',
  );

  /// Image models exposed by the example app.
  static const List<ImageModelProfile> defaultModels = <ImageModelProfile>[
    sdxs,
    sdTurbo,
  ];
}

/// Resolved local paths for one installed image model.
class InstalledImageModel {
  /// Profile that owns these files.
  final ImageModelProfile profile;

  /// Local checkpoint path.
  final String modelPath;

  /// Local TAESD path, when the profile has one.
  final String? taesdPath;

  /// Creates an installed image model descriptor.
  const InstalledImageModel({
    required this.profile,
    required this.modelPath,
    this.taesdPath,
  });

  /// Builds the library model for these files.
  ImageGenerationModel toGenerationModel() =>
      profile.buildModel(modelPath: modelPath, taesdPath: taesdPath);
}
