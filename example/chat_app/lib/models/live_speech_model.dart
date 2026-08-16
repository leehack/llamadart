import 'package:llamadart/llamadart.dart';

import 'downloadable_model.dart';

/// Native LiteRT-LM assets used by the chat app's live dictation flow.
class LiveSpeechModel {
  /// Stable model identifier.
  final String id;

  /// User-facing model name.
  final String name;

  /// Short user-facing model description.
  final String description;

  /// LiteRT model graph.
  final RemoteModelAssetSource modelSource;

  /// Tokenizer matching [modelSource].
  final RemoteModelAssetSource tokenizerSource;

  /// LiteRT-LM ASR metadata preset.
  final LiteRtLmAsrModelPreset preset;

  /// Languages validated for this model.
  final List<String> languages;

  /// Whether the chat app recommends this model as the default choice.
  final bool isRecommended;

  /// Creates an immutable live-speech model profile.
  const LiveSpeechModel({
    required this.id,
    required this.name,
    required this.description,
    required this.modelSource,
    required this.tokenizerSource,
    required this.preset,
    required this.languages,
    this.isRecommended = false,
  });

  /// Combined download size when both remote assets declare their sizes.
  int get sizeBytes =>
      (modelSource.sizeBytes ?? 0) + (tokenizerSource.sizeBytes ?? 0);

  /// Human-readable combined download size.
  String get sizeLabel {
    if (sizeBytes >= 1000 * 1000 * 1000) {
      return '${(sizeBytes / (1000 * 1000 * 1000)).toStringAsFixed(1)} GB';
    }
    return '${(sizeBytes / (1000 * 1000)).round()} MB';
  }

  /// First live transcription model shipped by the example.
  static const LiveSpeechModel moonshineTiny = LiveSpeechModel(
    id: 'litert-moonshine-tiny-i8',
    name: 'Moonshine Tiny Live STT',
    description:
        'Fast English live transcription using 5-second LiteRT windows.',
    modelSource: RemoteModelAssetSource(
      url:
          'https://huggingface.co/litert-community/moonshine-tiny/resolve/beb49ee5028b4fb21eb989bcbd2db30a433373db/moonshine_tiny_5s_i8.tflite?download=true',
      filename: 'moonshine_tiny_5s_i8.tflite',
      sizeBytes: 51936896,
      sha256:
          '97abdeea122d579229091659c24c59d988c6419d453a200f6471241a53b9a9b9',
    ),
    tokenizerSource: RemoteModelAssetSource(
      url:
          'https://huggingface.co/moonshine-ai/moonshine-tiny/resolve/390624ed33d594443aa4aa221f5b9f283b545b5a/tokenizer.json?download=true',
      filename: 'moonshine_tokenizer.json',
      sizeBytes: 1985530,
      sha256:
          '6579793438bc4fbafffacf699169ff53e3769c5a0a0f5e71cdee8853e8130deb',
    ),
    preset: LiteRtLmAsrModelPreset.moonshineTiny,
    languages: <String>['English'],
    isRecommended: true,
  );

  /// Higher-capacity English dictation model with a substantially larger graph.
  static const LiveSpeechModel parakeetTdt = LiveSpeechModel(
    id: 'litert-parakeet-tdt-0.6b-v3-i8',
    name: 'Parakeet TDT 0.6B Live STT',
    description:
        'Higher-capacity English transcription using 5-second LiteRT windows.',
    modelSource: RemoteModelAssetSource(
      url:
          'https://huggingface.co/litert-community/parakeet-tdt-0.6b-v3/resolve/e3a6f2dec6800733f97c87ff55822f32c405983a/parakeet_tdt_0.6b_v3_5s_i8_stateful.tflite?download=true',
      filename: 'parakeet_tdt_0.6b_v3_5s_i8_stateful.tflite',
      sizeBytes: 614261072,
      sha256:
          '334745b8bc7fd372b1c213516f0b6338bb827b1a2abb3e77ad35fe6fea5cd16b',
    ),
    tokenizerSource: RemoteModelAssetSource(
      url:
          'https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3/resolve/541d1f99c6b0c3cd0b11a95167540bb8edefd82b/tokenizer.json?download=true',
      filename: 'parakeet_tdt_0.6b_v3_tokenizer.json',
      sizeBytes: 1159960,
      sha256:
          'bd321b096832a3f270bd3b2a88823957920f1a5c5ada71114a26ea729d0cbe91',
    ),
    preset: LiteRtLmAsrModelPreset.parakeetTdt0_6bV3,
    languages: <String>['English'],
  );

  /// Live dictation models exposed by the example app.
  static const List<LiveSpeechModel> defaultModels = <LiveSpeechModel>[
    moonshineTiny,
    parakeetTdt,
  ];

  /// Resolves a built-in model by its stable identifier.
  static LiveSpeechModel byId(String? id) => defaultModels.firstWhere(
    (model) => model.id == id,
    orElse: () => moonshineTiny,
  );
}

/// Resolved native paths for one installed live-speech model.
class InstalledLiveSpeechModel {
  /// Model profile that owns these assets.
  final LiveSpeechModel model;

  /// Local LiteRT graph path.
  final String modelPath;

  /// Local tokenizer path.
  final String tokenizerPath;

  /// Creates an installed model descriptor.
  const InstalledLiveSpeechModel({
    required this.model,
    required this.modelPath,
    required this.tokenizerPath,
  });
}
