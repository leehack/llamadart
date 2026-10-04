import 'models/model_format.dart';

/// Base class for all Llama-related exceptions.
abstract class LlamaException implements Exception {
  /// A human-readable error message.
  final String message;

  /// Optional detail about the error.
  final dynamic details;

  /// Creates a new [LlamaException].
  LlamaException(this.message, [this.details]);

  @override
  String toString() =>
      'LlamaException: $message${details != null ? ' ($details)' : ''}';
}

/// Exception thrown when a model fails to load.
class LlamaModelException extends LlamaException {
  /// Creates a new [LlamaModelException].
  LlamaModelException(super.message, [super.details]);
}

/// Exception thrown when a model file's content is in one format but its file
/// extension or an explicit `format:` names another.
///
/// The model is not handed to either runtime.
class LlamaModelFormatException extends LlamaModelException {
  /// The format read from the file header.
  final ModelFormat detected;

  /// The format named by the file extension or the explicit `format:`.
  final ModelFormat declared;

  /// Creates a new [LlamaModelFormatException].
  LlamaModelFormatException({required this.detected, required this.declared})
    : super(
        'The model file is ${detected.name} but was declared '
        '${declared.name}. Fix the file name or pass '
        'format: ModelFormat.${detected.name}.',
      );
}

/// Exception thrown when an argument or a combination of parameters is
/// invalid, such as by `ModelParams.validate`.
class LlamaArgumentException extends LlamaException {
  /// The name of the rejected argument, or `null` when a combination of
  /// arguments is at fault.
  final String? name;

  /// The rejected value of [name].
  final Object? invalidValue;

  /// Creates a new [LlamaArgumentException].
  LlamaArgumentException(super.message, {this.name, this.invalidValue});
}

/// Exception thrown when a context operation fails.
class LlamaContextException extends LlamaException {
  /// Creates a new [LlamaContextException].
  LlamaContextException(super.message, [super.details]);
}

/// Exception thrown during text generation or tokenization.
class LlamaInferenceException extends LlamaException {
  /// Creates a new [LlamaInferenceException].
  LlamaInferenceException(super.message, [super.details]);
}

/// Exception thrown when a backend cannot initialize its runtime.
class LlamaBackendInitializationException extends LlamaException {
  /// Creates a new [LlamaBackendInitializationException].
  LlamaBackendInitializationException(super.message, [super.details]);
}

/// Exception thrown when speech recognition fails.
class LlamaSpeechException extends LlamaException {
  /// Creates a new [LlamaSpeechException].
  LlamaSpeechException(super.message, [super.details]);
}

/// Token limit that stopped speech recognition before the transcript ended.
enum LlamaSpeechTranscriptLimit {
  /// The transcript reached the request's `maxOutputTokens`.
  maxOutputTokens,

  /// The audio prompt and the transcript filled the model context.
  contextSize,

  /// The runtime reported truncation without identifying the limiting budget.
  runtime,
}

/// Exception thrown when speech recognition stops at a token limit before the
/// transcript ends.
class LlamaSpeechTranscriptTruncatedException extends LlamaSpeechException {
  /// The limit that stopped recognition.
  final LlamaSpeechTranscriptLimit limit;

  /// The normalized transcript produced before [limit] stopped recognition.
  final String partialTranscript;

  /// Creates a new [LlamaSpeechTranscriptTruncatedException].
  LlamaSpeechTranscriptTruncatedException(
    super.message, {
    required this.limit,
    required this.partialTranscript,
  });
}

/// Exception thrown when text-to-speech synthesis fails.
class LlamaTextToSpeechException extends LlamaSpeechException {
  /// Creates a new [LlamaTextToSpeechException].
  LlamaTextToSpeechException(super.message, [super.details]);
}

/// Exception thrown when speech audio does not satisfy an input contract.
class LlamaAudioFormatException extends LlamaSpeechException {
  /// Creates a new [LlamaAudioFormatException].
  LlamaAudioFormatException(super.message, [super.details]);
}

/// Exception thrown when an operation is not supported on the current platform.
class LlamaUnsupportedException extends LlamaException {
  /// Creates a new [LlamaUnsupportedException].
  LlamaUnsupportedException(super.message);
}

/// Exception thrown when the engine is in an invalid state.
class LlamaStateException extends LlamaException {
  /// Creates a new [LlamaStateException].
  LlamaStateException(super.message, [super.details]);
}

/// Exception thrown when an image-generation request or image buffer is
/// invalid.
class LlamaImageGenerationException extends LlamaException {
  /// Creates a new [LlamaImageGenerationException].
  LlamaImageGenerationException(super.message, [super.details]);
}

/// Exception thrown when a decision-model request is invalid or cannot be answered.
class LlamaDecisionException extends LlamaException {
  /// Creates a new [LlamaDecisionException].
  LlamaDecisionException(super.message, [super.details]);
}
