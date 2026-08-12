import 'dart:async';
import 'dart:typed_data';

import '../engine/engine.dart';
import '../exceptions.dart';
import '../models/chat/chat_message.dart';
import '../models/chat/chat_role.dart';
import '../models/chat/content_part.dart';
import '../models/inference/generation_params.dart';
import 'speech_platform_stub.dart'
    if (dart.library.js_interop) 'speech_platform_web.dart';

/// The kind of audio input accepted by a speech recognizer.
enum SpeechAudioInputKind {
  /// A local encoded audio file.
  file,

  /// Encoded audio held in memory.
  encodedBytes,
}

/// Model-specific adapter used by [SpeechToTextEngine].
///
/// A profile is an explicit caller declaration. Generic multimodal audio
/// support alone does not prove that a loaded model is an ASR model.
enum SpeechToTextModelProfile {
  /// Qwen3-ASR with its matching llama.cpp multimodal projector.
  qwen3Asr,
}

/// How the active backend implements speech recognition.
enum SpeechToTextImplementation {
  /// No usable speech recognition path is available.
  unavailable,

  /// Audio is routed through multimodal chat with a model-specific adapter.
  multimodalPromptAdapter,

  /// A backend-native, dedicated speech recognition API.
  dedicatedBackend,
}

/// Audio metadata supplied with speech input.
class SpeechAudioFormat {
  /// Sample rate in Hertz, when known.
  final int? sampleRateHz;

  /// Number of interleaved audio channels, when known.
  final int? channelCount;

  /// Container or codec hint such as `wav`, `mp3`, or `flac`.
  final String? encoding;

  /// MIME type supplied by the caller, when available.
  final String? mimeType;

  /// Creates audio metadata.
  const SpeechAudioFormat({
    this.sampleRateHz,
    this.channelCount,
    this.encoding,
    this.mimeType,
  });
}

/// Base class for audio accepted by [SpeechToTextEngine].
sealed class SpeechAudioInput {
  /// Optional source audio metadata.
  final SpeechAudioFormat? format;

  /// Creates a speech audio input.
  const SpeechAudioInput({this.format});

  /// The representation used by this input.
  SpeechAudioInputKind get kind;
}

/// A local encoded audio file.
class SpeechAudioFileInput extends SpeechAudioInput {
  /// Local filesystem path.
  final String path;

  /// Creates a local-file input.
  const SpeechAudioFileInput(this.path, {super.format});

  @override
  SpeechAudioInputKind get kind => SpeechAudioInputKind.file;
}

/// Encoded audio held in memory.
class SpeechAudioBytesInput extends SpeechAudioInput {
  /// Encoded audio bytes.
  final Uint8List bytes;

  /// Creates an encoded in-memory input.
  const SpeechAudioBytesInput(this.bytes, {super.format});

  @override
  SpeechAudioInputKind get kind => SpeechAudioInputKind.encodedBytes;
}

/// A request to recognize speech from one complete audio input.
class SpeechToTextRequest {
  /// Audio to transcribe.
  final SpeechAudioInput audio;

  /// Optional BCP-47 language hint, such as `en` or `fr-CA`.
  ///
  /// The field is reserved for recognizers with a validated language-hint
  /// contract. The first Qwen3-ASR adapter rejects nonempty hints.
  final String? languageHint;

  /// Optional vocabulary or surrounding-text guidance for the recognizer.
  final String? contextPrompt;

  /// Maximum number of generated transcript tokens.
  final int maxOutputTokens;

  /// Creates a speech recognition request.
  const SpeechToTextRequest({
    required this.audio,
    this.languageHint,
    this.contextPrompt,
    this.maxOutputTokens = 1024,
  });
}

/// Runtime speech-to-text capabilities for the loaded engine.
class SpeechToTextCapabilities {
  /// Whether [SpeechToTextEngine.transcribe] can be used now.
  final bool isSupported;

  /// Actionable reason when [isSupported] is false.
  final String? unsupportedReason;

  /// Active runtime backend label.
  final String? backendName;

  /// Whether recognition uses a prompt adapter or a dedicated backend API.
  final SpeechToTextImplementation implementation;

  /// Accepted audio input representations.
  final Set<SpeechAudioInputKind> inputKinds;

  /// File/byte encodings decoded by the first native backend.
  final Set<String> encodedAudioFormats;

  /// Whether text deltas can be emitted before the final transcript.
  final bool supportsPartialResults;

  /// Whether audio can be pushed incrementally while recognition is running.
  final bool supportsStreamingInput;

  /// Whether word or segment timestamps can be returned.
  bool get supportsTimestamps =>
      supportsSegmentTimestamps || supportsWordTimestamps;

  /// Whether segment timestamps can be returned.
  final bool supportsSegmentTimestamps;

  /// Whether word timestamps can be returned.
  final bool supportsWordTimestamps;

  /// Whether confidence values can be returned.
  final bool supportsConfidence;

  /// Whether speaker labels can be returned.
  final bool supportsSpeakerDiarization;

  /// Whether the runtime can report the recognized language.
  final bool supportsLanguageDetection;

  /// Whether language hints can be passed to the model.
  final bool supportsLanguageHints;

  /// Whether an active task can be cancelled cooperatively.
  final bool supportsCancellation;

  /// Whether pausing the output subscription throttles native inference.
  final bool supportsOutputBackpressure;

  /// Maximum number of concurrent tasks owned by one underlying engine.
  final int maxConcurrentTasks;

  /// Creates a capability snapshot.
  const SpeechToTextCapabilities({
    required this.isSupported,
    this.unsupportedReason,
    this.backendName,
    this.implementation = SpeechToTextImplementation.unavailable,
    this.inputKinds = const <SpeechAudioInputKind>{},
    this.encodedAudioFormats = const <String>{},
    this.supportsPartialResults = false,
    this.supportsStreamingInput = false,
    this.supportsSegmentTimestamps = false,
    this.supportsWordTimestamps = false,
    this.supportsConfidence = false,
    this.supportsSpeakerDiarization = false,
    this.supportsLanguageDetection = false,
    this.supportsLanguageHints = false,
    this.supportsCancellation = false,
    this.supportsOutputBackpressure = false,
    this.maxConcurrentTasks = 0,
  });
}

/// A recognized word with optional backend-provided metadata.
class TranscriptWord {
  /// Recognized word or token text.
  final String text;

  /// Start time relative to the beginning of the input, when available.
  final Duration? start;

  /// End time relative to the beginning of the input, when available.
  final Duration? end;

  /// Confidence in the range 0.0 to 1.0, when available.
  final double? confidence;

  /// Speaker label, when diarization is available.
  final String? speaker;

  /// Creates a recognized word.
  const TranscriptWord({
    required this.text,
    this.start,
    this.end,
    this.confidence,
    this.speaker,
  });
}

/// A recognized transcript segment.
class TranscriptSegment {
  /// Segment text.
  final String text;

  /// Start time relative to the beginning of the input, when available.
  final Duration? start;

  /// End time relative to the beginning of the input, when available.
  final Duration? end;

  /// Confidence in the range 0.0 to 1.0, when available.
  final double? confidence;

  /// Speaker label, when diarization is available.
  final String? speaker;

  /// Word-level details, when available.
  final List<TranscriptWord> words;

  /// Creates a transcript segment.
  const TranscriptSegment({
    required this.text,
    this.start,
    this.end,
    this.confidence,
    this.speaker,
    this.words = const <TranscriptWord>[],
  });
}

/// Final speech recognition result.
class SpeechToTextResult {
  /// Complete normalized transcript text.
  final String text;

  /// Model-reported language, when available.
  final String? language;

  /// Structured transcript segments.
  ///
  /// The first backend returns one untimed segment for the complete transcript.
  final List<TranscriptSegment> segments;

  /// Metadata describing the supplied source audio, when available.
  final SpeechAudioFormat? sourceFormat;

  /// Creates a final recognition result.
  const SpeechToTextResult({
    required this.text,
    this.language,
    this.segments = const <TranscriptSegment>[],
    this.sourceFormat,
  });
}

/// Base class for streamed speech recognition events.
sealed class SpeechToTextEvent {
  /// Creates a speech recognition event.
  const SpeechToTextEvent();
}

/// A replaceable, non-final transcript update.
class SpeechToTextPartialEvent extends SpeechToTextEvent {
  /// Current best transcript text.
  final String text;

  /// Creates a partial transcript event.
  const SpeechToTextPartialEvent(this.text);
}

/// The final transcript event for a task.
class SpeechToTextFinalEvent extends SpeechToTextEvent {
  /// Final recognition result.
  final SpeechToTextResult result;

  /// Creates a final transcript event.
  const SpeechToTextFinalEvent(this.result);
}

/// Terminal state of a speech recognition task.
enum SpeechToTextCompletionState {
  /// Recognition produced a final result.
  completed,

  /// Recognition was cancelled.
  cancelled,

  /// Recognition failed.
  failed,
}

/// Terminal details for a speech recognition task.
class SpeechToTextCompletion {
  /// Terminal state.
  final SpeechToTextCompletionState state;

  /// Final result when [state] is [SpeechToTextCompletionState.completed].
  final SpeechToTextResult? result;

  /// Failure when [state] is [SpeechToTextCompletionState.failed].
  final LlamaException? error;

  const SpeechToTextCompletion._({
    required this.state,
    this.result,
    this.error,
  });

  /// Creates a successful completion.
  factory SpeechToTextCompletion.completed(SpeechToTextResult result) =>
      SpeechToTextCompletion._(
        state: SpeechToTextCompletionState.completed,
        result: result,
      );

  /// Creates a cancelled completion.
  const factory SpeechToTextCompletion.cancelled() =
      _CancelledSpeechToTextCompletion;

  /// Creates a failed completion.
  factory SpeechToTextCompletion.failed(LlamaException error) =>
      SpeechToTextCompletion._(
        state: SpeechToTextCompletionState.failed,
        error: error,
      );
}

class _CancelledSpeechToTextCompletion extends SpeechToTextCompletion {
  const _CancelledSpeechToTextCompletion()
    : super._(state: SpeechToTextCompletionState.cancelled);
}

/// A cancellable speech recognition operation.
class SpeechToTextTask {
  final StreamController<SpeechToTextEvent> _eventsController;
  final Completer<SpeechToTextCompletion> _doneCompleter;
  final void Function() _onCancel;
  bool _cancelled = false;

  SpeechToTextTask._({required void Function() onCancel})
    : _onCancel = onCancel,
      _eventsController = StreamController<SpeechToTextEvent>(),
      _doneCompleter = Completer<SpeechToTextCompletion>();

  /// Recognition events.
  ///
  /// This is a single-subscription stream. Runtime failures are emitted as a
  /// stream error and are also reported by [done] as a failed completion.
  /// The first backend emits one [SpeechToTextFinalEvent]. The event model is
  /// intentionally future-compatible with backends that support partial text.
  Stream<SpeechToTextEvent> get events => _eventsController.stream;

  /// Completes once the task succeeds, is cancelled, or fails.
  Future<SpeechToTextCompletion> get done => _doneCompleter.future;

  /// Whether cancellation has been requested.
  bool get isCancellationRequested => _cancelled;

  /// Requests cooperative cancellation. Calling this more than once is safe.
  void cancel() {
    if (_cancelled || _doneCompleter.isCompleted) {
      return;
    }
    _cancelled = true;
    _onCancel();
  }
}

/// Typed speech-to-text API backed by a loaded [LlamaEngine].
///
/// The first implementation supports complete Qwen3-ASR audio inputs on native
/// llama.cpp with a matching audio-capable multimodal projector.
/// It does not yet provide live microphone ingestion, partial transcripts,
/// timestamps, confidence values, or diarization.
class SpeechToTextEngine {
  static final Expando<_SpeechTaskState> _taskStates =
      Expando<_SpeechTaskState>('llamadart.speechTaskState');

  final LlamaEngine _engine;
  final _SpeechTaskState _taskState;

  /// Model-specific adapter selected by the caller.
  final SpeechToTextModelProfile modelProfile;

  /// Creates a speech recognizer over an existing loaded engine.
  ///
  /// The engine must be used exclusively for this task until [SpeechToTextTask.done]
  /// completes. The recognizer prevents two speech wrappers over the same
  /// engine from running together, but direct [LlamaEngine.create] calls are
  /// owned by the caller.
  SpeechToTextEngine(LlamaEngine engine, {required this.modelProfile})
    : _engine = engine,
      _taskState = _taskStates[engine] ??= _SpeechTaskState();

  /// Discovers speech recognition support for the current runtime and model.
  Future<SpeechToTextCapabilities> get capabilities async {
    if (!isSpeechToTextPlatformSupported) {
      return SpeechToTextCapabilities(
        isSupported: false,
        unsupportedReason: speechToTextPlatformUnsupportedReason,
      );
    }
    if (!_engine.isReady) {
      return const SpeechToTextCapabilities(
        isSupported: false,
        unsupportedReason:
            'Load a model and its audio-capable multimodal projector first.',
      );
    }

    String? backendName;
    try {
      backendName = await _engine.getBackendName();
    } catch (_) {
      // Capability discovery can still use the explicit audio probe.
    }
    if (backendName?.toLowerCase().contains('litert-lm') ?? false) {
      return SpeechToTextCapabilities(
        isSupported: false,
        unsupportedReason:
            'Dedicated LiteRT-LM speech APIs are not exported by the current '
            'native artifact.',
        backendName: backendName,
      );
    }

    bool supportsAudio;
    try {
      supportsAudio = await _engine.supportsAudio;
    } catch (error) {
      return SpeechToTextCapabilities(
        isSupported: false,
        unsupportedReason: 'The audio capability probe failed: $error',
        backendName: backendName,
      );
    }
    if (!supportsAudio) {
      return SpeechToTextCapabilities(
        isSupported: false,
        unsupportedReason:
            'The loaded multimodal projector does not report audio support.',
        backendName: backendName,
      );
    }

    return SpeechToTextCapabilities(
      isSupported: true,
      backendName: backendName,
      implementation: SpeechToTextImplementation.multimodalPromptAdapter,
      inputKinds: const <SpeechAudioInputKind>{
        SpeechAudioInputKind.file,
        SpeechAudioInputKind.encodedBytes,
      },
      encodedAudioFormats: const <String>{'wav', 'mp3', 'flac'},
      supportsLanguageHints: false,
      supportsLanguageDetection: false,
      supportsCancellation: true,
      maxConcurrentTasks: 1,
    );
  }

  /// Starts recognition for one complete audio input.
  ///
  /// The returned task exposes a future-compatible event stream and explicit
  /// cancellation/completion state. Only one speech task may run per
  /// [LlamaEngine], including through separate [SpeechToTextEngine] wrappers.
  /// Invalid input and unsupported runtime/model preflight checks throw before
  /// a task is returned; failures after startup are reported by the task.
  Future<SpeechToTextTask> transcribe(SpeechToTextRequest request) async {
    if (_taskState.isActive) {
      throw LlamaStateException(
        'This LlamaEngine already has an active speech-to-text task.',
      );
    }
    _validateRequest(request);
    _taskState.isActive = true;

    try {
      final currentCapabilities = await capabilities;
      if (!currentCapabilities.isSupported) {
        throw LlamaUnsupportedException(
          currentCapabilities.unsupportedReason ??
              'Speech-to-text is not supported by the active runtime.',
        );
      }

      final task = SpeechToTextTask._(onCancel: _engine.cancelGeneration);
      unawaited(_runTask(task, request));
      return task;
    } catch (_) {
      _taskState.isActive = false;
      rethrow;
    }
  }

  void _validateRequest(SpeechToTextRequest request) {
    if (request.maxOutputTokens <= 0) {
      throw LlamaSpeechException('maxOutputTokens must be greater than 0.');
    }
    final languageHint = request.languageHint?.trim();
    if (languageHint != null && languageHint.isNotEmpty) {
      throw LlamaUnsupportedException(
        'The Qwen3-ASR prompt adapter does not expose validated language hints.',
      );
    }

    switch (request.audio) {
      case SpeechAudioFileInput(:final path):
        if (path.trim().isEmpty) {
          throw LlamaAudioFormatException('Audio file path must not be empty.');
        }
        final encoding = request.audio.format?.encoding?.trim().toLowerCase();
        final extension = _fileExtension(path);
        if (encoding != null && encoding.isNotEmpty) {
          if (!const <String>{'wav', 'mp3', 'flac'}.contains(encoding)) {
            throw LlamaAudioFormatException(
              'Encoded audio files must use WAV, MP3, or FLAC.',
              encoding,
            );
          }
        } else if (extension.isNotEmpty &&
            !const <String>{'wav', 'mp3', 'flac'}.contains(extension)) {
          throw LlamaAudioFormatException(
            'Encoded audio files must use WAV, MP3, or FLAC.',
            extension,
          );
        }
      case SpeechAudioBytesInput(:final bytes):
        if (bytes.isEmpty) {
          throw LlamaAudioFormatException(
            'Encoded audio bytes must not be empty.',
          );
        }
        final encoding = request.audio.format?.encoding?.trim().toLowerCase();
        if (encoding != null &&
            encoding.isNotEmpty &&
            !const <String>{'wav', 'mp3', 'flac'}.contains(encoding)) {
          throw LlamaAudioFormatException(
            'Encoded audio bytes must use WAV, MP3, or FLAC.',
            encoding,
          );
        }
    }
  }

  Future<void> _runTask(
    SpeechToTextTask task,
    SpeechToTextRequest request,
  ) async {
    try {
      if (task.isCancellationRequested) {
        await _completeCancelled(task);
        return;
      }

      final output = StringBuffer();
      await for (final chunk in _engine.create(
        <LlamaChatMessage>[
          LlamaChatMessage.withContent(
            role: LlamaChatRole.user,
            content: <LlamaContentPart>[
              LlamaTextContent(_promptFor(request)),
              _contentFor(request.audio),
            ],
          ),
        ],
        params: GenerationParams(
          maxTokens: request.maxOutputTokens,
          temp: 0,
          topK: 1,
          topP: 1,
          penalty: 1,
          seed: 1,
          streamBatchTokenThreshold: 1,
        ),
        enableThinking: false,
      )) {
        if (task.isCancellationRequested) {
          break;
        }
        if (chunk.choices.isEmpty) {
          continue;
        }
        final text = chunk.choices.first.delta.content;
        if (text != null) {
          output.write(text);
        }
      }

      if (task.isCancellationRequested) {
        await _completeCancelled(task);
        return;
      }

      final normalized = _normalizeTranscript(output.toString());
      final result = SpeechToTextResult(
        text: normalized.text,
        language: normalized.language,
        segments: normalized.text.isEmpty
            ? const <TranscriptSegment>[]
            : <TranscriptSegment>[TranscriptSegment(text: normalized.text)],
        sourceFormat: request.audio.format,
      );
      task._eventsController.add(SpeechToTextFinalEvent(result));
      unawaited(task._eventsController.close());
      task._doneCompleter.complete(SpeechToTextCompletion.completed(result));
    } catch (error, stackTrace) {
      if (task.isCancellationRequested) {
        await _completeCancelled(task);
        return;
      }
      final speechError = error is LlamaException
          ? error
          : LlamaSpeechException('Speech recognition failed.', error);
      task._eventsController.addError(speechError, stackTrace);
      unawaited(task._eventsController.close());
      task._doneCompleter.complete(SpeechToTextCompletion.failed(speechError));
    } finally {
      _taskState.isActive = false;
    }
  }

  Future<void> _completeCancelled(SpeechToTextTask task) async {
    unawaited(task._eventsController.close());
    if (!task._doneCompleter.isCompleted) {
      task._doneCompleter.complete(const SpeechToTextCompletion.cancelled());
    }
  }

  String _promptFor(SpeechToTextRequest request) {
    final prompt = StringBuffer('Transcribe this audio accurately.');
    final contextPrompt = request.contextPrompt?.trim();
    if (contextPrompt != null && contextPrompt.isNotEmpty) {
      prompt.write(' Context: $contextPrompt');
    }
    return prompt.toString();
  }

  LlamaAudioContent _contentFor(SpeechAudioInput audio) {
    return switch (audio) {
      SpeechAudioFileInput(:final path) => LlamaAudioContent(path: path),
      SpeechAudioBytesInput(:final bytes) => LlamaAudioContent(bytes: bytes),
    };
  }

  String _fileExtension(String path) {
    final cleanPath = path.split('?').first.split('#').first;
    final filename = cleanPath.replaceAll('\\', '/').split('/').last;
    final separator = filename.lastIndexOf('.');
    if (separator < 0 || separator == filename.length - 1) {
      return '';
    }
    return filename.substring(separator + 1).toLowerCase();
  }

  ({String text, String? language}) _normalizeTranscript(String raw) {
    final languagePrefix = RegExp(
      r'^\s*language\s+([^<\r\n]+?)\s*<asr_text>\s*',
      caseSensitive: false,
    ).firstMatch(raw);
    if (languagePrefix != null) {
      return (text: raw.substring(languagePrefix.end).trim(), language: null);
    }

    final marker = RegExp(
      r'^\s*<asr_text>\s*',
      caseSensitive: false,
    ).firstMatch(raw);
    return (
      text: marker == null ? raw.trim() : raw.substring(marker.end).trim(),
      language: null,
    );
  }
}

class _SpeechTaskState {
  bool isActive = false;
}
