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
  }) => _model(
    model: ModelSource.path(modelPath),
    taesd: taesdPath == null ? null : ModelSource.path(taesdPath),
  );

  ImageGenerationModel _model({ModelSource? model, ModelSource? taesd}) =>
      switch (family) {
        ImageGenerationModelFamily.sdxs => ImageGenerationModel.sdxsPreset(
          model: model,
        ),
        ImageGenerationModelFamily.sdTurbo =>
          ImageGenerationModel.sdTurboPreset(model: model, taesd: taesd),
        ImageGenerationModelFamily.custom => ImageGenerationModel.custom(
          ImageGenerationModelFiles.fromSources(model: model, taesd: taesd),
        ),
        ImageGenerationModelFamily.sdxlLightning ||
        ImageGenerationModelFamily.flux1Schnell ||
        ImageGenerationModelFamily.sd35LargeTurbo ||
        ImageGenerationModelFamily.zImageTurbo => throw UnsupportedError(
          'The example app offers only single-file phone presets, not '
          '${family.name}.',
        ),
      };

  /// Sampling defaults of the library preset.
  ImageGenerationDefaults get defaults => _model().defaults;

  /// SDXS-512: a one-step distilled SD 1.x-size model that fits phones.
  static final ImageModelProfile sdxs = ImageModelProfile(
    id: 'sdxs-512-q8_0',
    name: 'SDXS-512',
    description: 'One-step distilled model that fits most phones.',
    family: ImageGenerationModelFamily.sdxs,
    modelSource: _pinned(ImageGenerationPresetFile.sdxs),
    isRecommended: true,
  );

  /// SD-Turbo with the TAESD decoder: more detail, about three times the
  /// memory of SDXS.
  static final ImageModelProfile sdTurbo = ImageModelProfile(
    id: 'sd-turbo-q8_0-taesd',
    name: 'SD-Turbo + TAESD',
    description: 'SD 2.1 Turbo with the tiny TAESD decoder; 1 to 4 steps.',
    family: ImageGenerationModelFamily.sdTurbo,
    modelSource: _pinned(ImageGenerationPresetFile.sdTurbo),
    taesdSource: _pinned(
      ImageGenerationPresetFile.taesd,
      filename: 'taesd.safetensors',
    ),
    memoryNote:
        'Needs about 3.1 GB of free memory; phones with less than 8 GB of '
        'RAM usually cannot load it.',
  );

  /// Image models exposed by the example app.
  static final List<ImageModelProfile> defaultModels =
      List<ImageModelProfile>.unmodifiable(<ImageModelProfile>[sdxs, sdTurbo]);

  /// The library's pinned [file] as an app-managed download, keeping its
  /// URL so files installed before the pins moved into the library stay
  /// valid.
  static RemoteModelAssetSource _pinned(
    ImageGenerationPresetFile file, {
    String? filename,
  }) => RemoteModelAssetSource(
    url: file.source.resolvedUri.toString(),
    filename: filename ?? file.source.fileName,
    sizeBytes: file.sizeBytes,
    sha256: file.sha256,
  );
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
