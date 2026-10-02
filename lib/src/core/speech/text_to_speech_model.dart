import '../../backends/backend.dart';
import '../exceptions.dart';
import '../models/model_source.dart';

/// A text-to-speech model: its files and the adapter that drives it.
///
/// Each file is a `ModelSource` (local path, HTTP(S) URL or Hugging Face
/// file) that `TextToSpeechEngine.load` downloads if needed. llama.cpp needs
/// the model's audio-generation [projector].
///
/// ```dart
/// final model = TextToSpeechModel(
///   ModelSource.parse('hf://owner/repo/tts-model.gguf'),
///   projector: ModelSource.parse('hf://owner/repo/mmproj-tts-model.gguf'),
///   adapter: const Qwen3TtsAdapter(),
/// );
/// ```
///
/// Building a model does no network or file access.
class TextToSpeechModel {
  /// The main model file.
  final ModelSource source;

  /// The audio-generation multimodal projector, or null.
  final ModelSource? projector;

  /// What drives the model.
  final TextToSpeechAdapter adapter;

  /// Creates a model from its main [source], its [projector] and the
  /// [adapter].
  const TextToSpeechModel(this.source, {this.projector, required this.adapter});
}

/// Model-specific knowledge `TextToSpeechEngine` needs to run a
/// text-to-speech model.
///
/// The runtime generates the audio itself and reports which audio-generation
/// model it loaded as a [BackendTextToSpeechModel]; the adapter accepts the
/// models it drives and maps request languages to the codes they take.
/// Implement it, or extend it to keep the defaults, for another family the
/// runtime supports.
abstract class TextToSpeechAdapter {
  /// Creates an adapter.
  const TextToSpeechAdapter();

  /// Model family name used in messages, such as `Qwen3-TTS`.
  String get name;

  /// Language codes the model takes, reported as
  /// `TextToSpeechCapabilities.supportedLanguages`. Defaults to none.
  Set<String> get supportedLanguages => const <String>{};

  /// Whether this adapter drives [model], the audio-generation model the
  /// runtime loaded, or null when the runtime does not name it.
  bool supportsModel(BackendTextToSpeechModel? model);

  /// The language code the model takes for [language], a trimmed nonempty
  /// `TextToSpeechRequest.language`.
  ///
  /// Defaults to [language] in lower case. Throws
  /// [LlamaTextToSpeechException] for a language the model does not take.
  String normalizeLanguage(String language) => language.toLowerCase();
}

/// Qwen3-TTS on llama.cpp, with its audio-generation projector.
///
/// It takes the two-letter codes in [supportedLanguages] and their English
/// names, such as `English` for `en` and `Korean` for `ko`.
class Qwen3TtsAdapter extends TextToSpeechAdapter {
  static const Map<String, String> _languageAliases = <String, String>{
    'chinese': 'zh',
    'english': 'en',
    'french': 'fr',
    'german': 'de',
    'italian': 'it',
    'japanese': 'ja',
    'korean': 'ko',
    'portuguese': 'pt',
    'russian': 'ru',
    'spanish': 'es',
  };
  static const Set<String> _languageCodes = <String>{
    'zh',
    'en',
    'ja',
    'ko',
    'de',
    'fr',
    'ru',
    'pt',
    'es',
    'it',
  };

  /// Creates the Qwen3-TTS adapter.
  const Qwen3TtsAdapter();

  @override
  String get name => 'Qwen3-TTS';

  @override
  Set<String> get supportedLanguages => _languageCodes;

  @override
  bool supportsModel(BackendTextToSpeechModel? model) =>
      model == BackendTextToSpeechModel.qwen3Tts;

  @override
  String normalizeLanguage(String language) {
    final normalized = language.toLowerCase();
    final code = _languageAliases[normalized] ?? normalized;
    if (!_languageCodes.contains(code)) {
      throw LlamaTextToSpeechException(
        'Unsupported Qwen3-TTS language `$language`. Use one of: '
        '${_languageCodes.join(', ')}.',
      );
    }
    return code;
  }
}
