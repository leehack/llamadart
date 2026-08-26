import 'dart:async';
import 'dart:typed_data';

import '../../backends/backend.dart';
import '../../backends/litert_lm/litert_lm_asr_types.dart';
import '../engine/engine.dart';
import '../exceptions.dart';
import '../models/chat/chat_message.dart';
import '../models/chat/chat_role.dart';
import '../models/chat/content_part.dart';
import '../models/inference/generation_params.dart';
import 'litert_lm_speech_to_text_driver.dart';
import 'litert_lm_speech_to_text_driver_stub.dart'
    if (dart.library.io) 'litert_lm_speech_to_text_driver_io.dart';
import 'speech_engine_lease.dart';
import 'speech_platform_stub.dart'
    if (dart.library.js_interop) 'speech_platform_web.dart';

/// The kind of audio input accepted by a speech recognizer.
enum SpeechAudioInputKind {
  /// A local encoded audio file.
  file,

  /// Encoded audio held in memory.
  encodedBytes,

  /// Mono float PCM held in memory.
  pcmFloat32,
}

/// Model-specific adapter used by [SpeechToTextEngine].
///
/// A profile is an explicit caller declaration. Generic multimodal audio
/// support alone does not prove that a loaded model is an ASR model.
enum SpeechToTextModelProfile {
  /// Qwen3-ASR with its matching llama.cpp multimodal projector.
  qwen3Asr,

  /// Dedicated LiteRT-LM ASR selected by [LiteRtLmAsrRuntimeConfig].
  liteRtLmDedicated,
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

  /// Container, codec, or sample encoding such as `wav`, `flac`, or
  /// `pcm-f32le`.
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

/// Mono float PCM held in memory.
class SpeechAudioPcmInput extends SpeechAudioInput {
  /// Normalized PCM samples in the range -1.0 to 1.0.
  final Float32List samples;

  /// Creates a float PCM input.
  ///
  /// Dedicated LiteRT-LM ASR currently requires mono 16 kHz input.
  SpeechAudioPcmInput(
    this.samples, {
    super.format = const SpeechAudioFormat(
      sampleRateHz: 16000,
      channelCount: 1,
      encoding: 'pcm-f32le',
    ),
  });

  @override
  SpeechAudioInputKind get kind => SpeechAudioInputKind.pcmFloat32;
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
  ///
  /// This applies to prompt-adapted recognition. Dedicated ASR backends ignore
  /// it after validating that it is positive.
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
  /// Whether recognition can be started with the configured engine.
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

  /// Whether awaiting an input push applies bounded native backpressure.
  final bool supportsInputBackpressure;

  /// Maximum number of concurrent tasks owned by one recognizer or engine.
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
    this.supportsInputBackpressure = false,
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

  /// Audio duration accepted by the recognizer, when known.
  final Duration? audioDuration;

  /// Creates a final recognition result.
  const SpeechToTextResult({
    required this.text,
    this.language,
    this.segments = const <TranscriptSegment>[],
    this.sourceFormat,
    this.audioDuration,
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

  /// Stable transcript prefix that will not be revised.
  final String? confirmedText;

  /// Replaceable hypothesis for the current inference window.
  final String? pendingText;

  /// Audio duration accepted when this update was produced.
  final Duration? acceptedAudioDuration;

  /// Creates a partial transcript event.
  const SpeechToTextPartialEvent(
    this.text, {
    this.confirmedText,
    this.pendingText,
    this.acceptedAudioDuration,
  });
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
  void Function()? _cancelTokenStream;
  bool _cancelled = false;

  SpeechToTextTask._({required void Function() onCancel})
    : _onCancel = onCancel,
      _eventsController = StreamController<SpeechToTextEvent>(),
      _doneCompleter = Completer<SpeechToTextCompletion>();

  /// Recognition events.
  ///
  /// This is a single-subscription stream. Runtime failures are emitted as a
  /// stream error and are also reported by [done] as a failed completion.
  /// Prompt-adapted recognition emits one [SpeechToTextFinalEvent]. Dedicated
  /// backends can emit [SpeechToTextPartialEvent] updates first.
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
    try {
      _onCancel();
    } finally {
      _cancelTokenStream?.call();
    }
  }
}

/// An active incremental speech-recognition session.
///
/// Callers must await each [addPcm] operation. This applies bounded input
/// backpressure while native inference runs in a worker isolate.
abstract interface class SpeechToTextStreamingSession {
  /// Partial and final transcript events.
  ///
  /// This is a single-subscription stream. Runtime failures are emitted as a
  /// stream error and are also reported by [done] as a failed completion.
  Stream<SpeechToTextEvent> get events;

  /// Terminal completion state.
  Future<SpeechToTextCompletion> get done;

  /// Adds mono 16 kHz normalized float PCM.
  ///
  /// The caller must not mutate [samples] until the returned future completes.
  Future<void> addPcm(Float32List samples);

  /// Marks input complete and flushes the final partial inference window.
  Future<void> finish();

  /// Requests cooperative cancellation and releases native resources.
  Future<void> cancel();
}

/// Typed speech-to-text API for prompt-adapted and dedicated ASR runtimes.
///
/// The default constructor adapts a loaded llama.cpp Qwen3-ASR model and its
/// audio projector. [SpeechToTextEngine.liteRtLm] creates a dedicated native
/// LiteRT-LM recognizer with incremental PCM input and partial transcripts.
class SpeechToTextEngine {
  static const String _leaseOwner = 'speech-to-text';
  static const SpeechAudioFormat _liteRtLmPcmFormat = SpeechAudioFormat(
    sampleRateHz: 16000,
    channelCount: 1,
    encoding: 'pcm-f32le',
  );

  final LlamaEngine? _engine;
  final SpeechEngineLease? _engineLease;
  final LiteRtLmAsrRuntimeConfig? _liteRtLmConfig;
  final LiteRtLmSpeechToTextDriver? _liteRtLmDriver;
  final String? _liteRtLmLibraryPath;
  Future<LiteRtLmSpeechToTextSupport>? _liteRtLmSupportFuture;
  bool _liteRtLmTaskActive = false;

  /// Model-specific adapter selected by the caller.
  final SpeechToTextModelProfile modelProfile;

  /// Creates a Qwen3-ASR prompt adapter over an existing loaded engine.
  ///
  /// The engine must be used exclusively until [SpeechToTextTask.done]
  /// completes. Separate speech wrappers over the same engine share a lease,
  /// but direct [LlamaEngine.create] calls remain caller-owned.
  SpeechToTextEngine(LlamaEngine engine, {required this.modelProfile})
    : _engine = engine,
      _engineLease = SpeechEngineLease.forEngine(engine),
      _liteRtLmConfig = null,
      _liteRtLmDriver = null,
      _liteRtLmLibraryPath = null {
    if (modelProfile == SpeechToTextModelProfile.liteRtLmDedicated) {
      throw ArgumentError.value(
        modelProfile,
        'modelProfile',
        'Use SpeechToTextEngine.liteRtLm for dedicated LiteRT-LM ASR.',
      );
    }
  }

  /// Creates a dedicated native LiteRT-LM recognizer.
  ///
  /// The configured model and tokenizer are independent of any chat model
  /// loaded through [LlamaEngine]. The current runtime accepts mono 16 kHz
  /// float PCM and supports one active task per recognizer instance.
  /// [libraryPath] is an advanced local-validation override; packaged apps
  /// should omit it and use the runtime resolved by native assets.
  SpeechToTextEngine.liteRtLm(
    LiteRtLmAsrRuntimeConfig config, {
    String? libraryPath,
  }) : _engine = null,
       _engineLease = null,
       _liteRtLmConfig = config,
       _liteRtLmDriver =
           debugLiteRtLmSpeechToTextDriverOverride ??
           createLiteRtLmSpeechToTextDriver(),
       _liteRtLmLibraryPath = libraryPath,
       modelProfile = SpeechToTextModelProfile.liteRtLmDedicated;

  bool get _usesLiteRtLm => _liteRtLmConfig != null;

  /// Discovers speech recognition support for the configured runtime and model.
  Future<SpeechToTextCapabilities> get capabilities async {
    if (_usesLiteRtLm) {
      final support = await (_liteRtLmSupportFuture ??= _liteRtLmDriver!
          .probeSupport(libraryPath: _liteRtLmLibraryPath));
      if (!support.isSupported) {
        return SpeechToTextCapabilities(
          isSupported: false,
          unsupportedReason: support.unsupportedReason,
          backendName: 'LiteRT-LM ASR',
        );
      }
      return const SpeechToTextCapabilities(
        isSupported: true,
        backendName: 'LiteRT-LM ASR CPU',
        implementation: SpeechToTextImplementation.dedicatedBackend,
        inputKinds: <SpeechAudioInputKind>{SpeechAudioInputKind.pcmFloat32},
        supportsPartialResults: true,
        supportsStreamingInput: true,
        supportsCancellation: true,
        supportsInputBackpressure: true,
        maxConcurrentTasks: 1,
      );
    }

    final engine = _engine!;
    if (speechToTextRequiresBackendCapability) {
      final backend = engine.backend;
      final speechBackend = backend is BackendPromptSpeechToTextSupport
          ? backend as BackendPromptSpeechToTextSupport
          : null;
      if (speechBackend == null || !speechBackend.supportsPromptSpeechToText) {
        return SpeechToTextCapabilities(
          isSupported: false,
          unsupportedReason: speechBackend != null
              ? speechBackend.promptSpeechToTextUnsupportedReason
              : 'The active Web runtime does not expose validated typed '
                    'speech-to-text support.',
        );
      }
    }
    if (!engine.isReady) {
      return const SpeechToTextCapabilities(
        isSupported: false,
        unsupportedReason:
            'Load a model and its audio-capable multimodal projector first.',
      );
    }

    String? backendName;
    try {
      backendName = await engine.getBackendName();
    } catch (_) {
      // Capability discovery can still use the explicit audio probe.
    }
    if (backendName?.toLowerCase().contains('litert-lm') ?? false) {
      return SpeechToTextCapabilities(
        isSupported: false,
        unsupportedReason:
            'A chat-model LiteRT-LM engine is not a dedicated ASR session. '
            'Use SpeechToTextEngine.liteRtLm with an ASR model and tokenizer.',
        backendName: backendName,
      );
    }

    bool supportsAudio;
    try {
      supportsAudio = await engine.supportsAudio;
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
      inputKinds: <SpeechAudioInputKind>{
        if (speechToTextSupportsFileInput) SpeechAudioInputKind.file,
        SpeechAudioInputKind.encodedBytes,
      },
      encodedAudioFormats: speechToTextEncodedAudioFormats,
      supportsCancellation: true,
      maxConcurrentTasks: 1,
    );
  }

  /// Starts recognition for one complete audio input.
  ///
  /// Qwen3-ASR accepts encoded files or bytes. Dedicated LiteRT-LM ASR accepts
  /// [SpeechAudioPcmInput] and emits any intermediate partial events before its
  /// final result. Invalid input and unsupported preflight checks throw before
  /// a task is returned; failures after startup are reported by the task.
  Future<SpeechToTextTask> transcribe(SpeechToTextRequest request) async {
    _validateRequest(request);
    if (_usesLiteRtLm) {
      return _transcribeLiteRtLm(request);
    }

    final lease = _engineLease!;
    if (!lease.acquire(_leaseOwner)) {
      throw LlamaStateException(
        'This LlamaEngine already has an active typed speech task '
        '(${lease.activeOwner}).',
      );
    }

    try {
      final currentCapabilities = await capabilities;
      if (!currentCapabilities.isSupported) {
        throw LlamaUnsupportedException(
          currentCapabilities.unsupportedReason ??
              'Speech-to-text is not supported by the active runtime.',
        );
      }

      final engine = _engine!;
      final task = SpeechToTextTask._(onCancel: engine.cancelGeneration);
      unawaited(_runPromptAdapterTask(task, request));
      return task;
    } catch (_) {
      lease.release(_leaseOwner);
      rethrow;
    }
  }

  /// Starts an incremental dedicated-ASR session.
  ///
  /// This is currently available only for [SpeechToTextEngine.liteRtLm]. The
  /// accepted [format] is mono 16 kHz `pcm-f32le`. Await every
  /// [SpeechToTextStreamingSession.addPcm] call so bounded native backpressure
  /// can throttle the producer.
  Future<SpeechToTextStreamingSession> startStream({
    SpeechAudioFormat format = _liteRtLmPcmFormat,
  }) async {
    if (!_usesLiteRtLm) {
      throw LlamaUnsupportedException(
        'The Qwen3-ASR prompt adapter accepts complete encoded audio only.',
      );
    }
    _validateLiteRtLmPcmFormat(format);
    if (_liteRtLmTaskActive) {
      throw LlamaStateException(
        'This SpeechToTextEngine already has an active LiteRT-LM ASR task.',
      );
    }
    _liteRtLmTaskActive = true;
    try {
      final currentCapabilities = await capabilities;
      if (!currentCapabilities.isSupported) {
        throw LlamaUnsupportedException(
          currentCapabilities.unsupportedReason ??
              'Dedicated LiteRT-LM speech recognition is unavailable.',
        );
      }
      final worker = await _liteRtLmDriver!.start(
        _liteRtLmConfig!,
        libraryPath: _liteRtLmLibraryPath,
      );
      return _LiteRtLmStreamingSession(
        worker: worker,
        sourceFormat: format,
        onClosed: () => _liteRtLmTaskActive = false,
      );
    } catch (_) {
      _liteRtLmTaskActive = false;
      rethrow;
    }
  }

  Future<SpeechToTextTask> _transcribeLiteRtLm(
    SpeechToTextRequest request,
  ) async {
    final audio = request.audio as SpeechAudioPcmInput;
    final session = await startStream(format: audio.format!);
    late final SpeechToTextTask task;
    task = SpeechToTextTask._(onCancel: () => unawaited(session.cancel()));
    unawaited(_pipeLiteRtLmTask(task, session, audio.samples));
    return task;
  }

  Future<void> _pipeLiteRtLmTask(
    SpeechToTextTask task,
    SpeechToTextStreamingSession session,
    Float32List samples,
  ) async {
    final subscription = session.events.listen(
      task._eventsController.add,
      onError: task._eventsController.addError,
    );
    try {
      await session.addPcm(samples);
      if (!task.isCancellationRequested) {
        await session.finish();
      }
      final completion = await session.done;
      if (!task._doneCompleter.isCompleted) {
        task._doneCompleter.complete(completion);
      }
    } catch (error, stackTrace) {
      try {
        await session.cancel();
      } catch (_) {
        // Preserve the first recognition failure.
      }
      if (task.isCancellationRequested) {
        _completeCancelled(task);
      } else {
        final speechError = _speechError(error);
        task._eventsController.addError(speechError, stackTrace);
        if (!task._doneCompleter.isCompleted) {
          task._doneCompleter.complete(
            SpeechToTextCompletion.failed(speechError),
          );
        }
      }
    } finally {
      await subscription.cancel();
      if (!task._eventsController.isClosed) {
        await task._eventsController.close();
      }
    }
  }

  void _validateRequest(SpeechToTextRequest request) {
    if (request.maxOutputTokens <= 0) {
      throw LlamaSpeechException('maxOutputTokens must be greater than 0.');
    }
    final languageHint = request.languageHint?.trim();
    if (languageHint != null && languageHint.isNotEmpty) {
      throw LlamaUnsupportedException(
        'The selected speech recognizer does not expose validated language hints.',
      );
    }
    if (_usesLiteRtLm) {
      final contextPrompt = request.contextPrompt?.trim();
      if (contextPrompt != null && contextPrompt.isNotEmpty) {
        throw LlamaUnsupportedException(
          'Dedicated LiteRT-LM ASR does not expose context prompting.',
        );
      }
      final audio = request.audio;
      if (audio is! SpeechAudioPcmInput) {
        throw LlamaUnsupportedException(
          'Dedicated LiteRT-LM ASR accepts SpeechAudioPcmInput only.',
        );
      }
      if (audio.samples.isEmpty) {
        throw LlamaAudioFormatException('Float PCM samples must not be empty.');
      }
      final format = audio.format;
      if (format == null) {
        throw LlamaAudioFormatException(
          'Dedicated LiteRT-LM ASR requires explicit PCM metadata.',
        );
      }
      _validateLiteRtLmPcmFormat(format);
      return;
    }

    switch (request.audio) {
      case SpeechAudioFileInput(:final path):
        if (!speechToTextSupportsFileInput) {
          throw LlamaUnsupportedException(
            'Web speech-to-text accepts encoded audio bytes only; browser '
            'local filesystem paths are not available to the runtime.',
          );
        }
        if (path.trim().isEmpty) {
          throw LlamaAudioFormatException('Audio file path must not be empty.');
        }
        final encoding = request.audio.format?.encoding?.trim().toLowerCase();
        final extension = _fileExtension(path);
        if (encoding != null && encoding.isNotEmpty) {
          if (!speechToTextEncodedAudioFormats.contains(encoding)) {
            throw LlamaAudioFormatException(
              'Encoded audio files must use ${_encodedFormatList()}.',
              encoding,
            );
          }
        } else if (extension.isNotEmpty &&
            !speechToTextEncodedAudioFormats.contains(extension)) {
          throw LlamaAudioFormatException(
            'Encoded audio files must use ${_encodedFormatList()}.',
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
        if (speechToTextRequiresEncodedAudioFormat &&
            (encoding == null || encoding.isEmpty)) {
          throw LlamaAudioFormatException(
            'Web encoded audio bytes require SpeechAudioFormat.encoding; '
            'the validated format is WAV.',
          );
        }
        if (encoding != null &&
            encoding.isNotEmpty &&
            !speechToTextEncodedAudioFormats.contains(encoding)) {
          throw LlamaAudioFormatException(
            'Encoded audio bytes must use ${_encodedFormatList()}.',
            encoding,
          );
        }
      case SpeechAudioPcmInput():
        throw LlamaUnsupportedException(
          'The Qwen3-ASR prompt adapter accepts encoded audio only.',
        );
    }
  }

  String _encodedFormatList() {
    final formats = speechToTextEncodedAudioFormats
        .map((format) => format.toUpperCase())
        .toList(growable: false);
    if (formats.length == 1) {
      return formats.single;
    }
    return '${formats.take(formats.length - 1).join(', ')}, or ${formats.last}';
  }

  void _validateLiteRtLmPcmFormat(SpeechAudioFormat format) {
    final encoding = format.encoding?.trim().toLowerCase();
    if (format.sampleRateHz != 16000 ||
        format.channelCount != 1 ||
        (encoding != null && encoding.isNotEmpty && encoding != 'pcm-f32le')) {
      throw LlamaAudioFormatException(
        'Dedicated LiteRT-LM ASR requires mono 16 kHz pcm-f32le audio.',
        'sampleRateHz=${format.sampleRateHz}, '
            'channelCount=${format.channelCount}, encoding=${format.encoding}',
      );
    }
  }

  Future<void> _runPromptAdapterTask(
    SpeechToTextTask task,
    SpeechToTextRequest request,
  ) async {
    try {
      if (task.isCancellationRequested) {
        _completeCancelled(task);
        return;
      }

      final output = StringBuffer();
      final tokenStreamDone = Completer<void>();
      StreamSubscription<String>? tokenSubscription;
      Future<void>? tokenStreamCancellation;
      void cancelTokenStream() {
        if (tokenStreamCancellation != null) {
          return;
        }
        final subscription = tokenSubscription;
        if (subscription == null) {
          return;
        }
        late final Future<void> cancellation;
        try {
          cancellation = subscription.cancel();
        } catch (error, stackTrace) {
          cancellation = Future<void>.error(error, stackTrace);
        }
        tokenStreamCancellation = cancellation;
        unawaited(cancellation.catchError((Object _, StackTrace _) {}));
        if (!tokenStreamDone.isCompleted) {
          tokenStreamDone.complete();
        }
      }

      Object? tokenStreamError;
      StackTrace? tokenStreamStackTrace;
      try {
        tokenSubscription = _promptAdapterTokens(request).listen(
          (token) {
            if (!task.isCancellationRequested && tokenStreamError == null) {
              output.write(token);
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            tokenStreamError ??= error;
            tokenStreamStackTrace ??= stackTrace;
            if (!tokenStreamDone.isCompleted) {
              tokenStreamDone.complete();
            }
          },
          onDone: () {
            if (!tokenStreamDone.isCompleted) {
              tokenStreamDone.complete();
            }
          },
          cancelOnError: false,
        );
        task._cancelTokenStream = cancelTokenStream;
        if (task.isCancellationRequested) {
          cancelTokenStream();
        }
        await tokenStreamDone.future;
      } catch (error, stackTrace) {
        tokenStreamError ??= error;
        tokenStreamStackTrace ??= stackTrace;
      } finally {
        if (identical(task._cancelTokenStream, cancelTokenStream)) {
          task._cancelTokenStream = null;
        }
        try {
          cancelTokenStream();
          await tokenStreamCancellation;
        } catch (error, stackTrace) {
          tokenStreamError ??= error;
          tokenStreamStackTrace ??= stackTrace;
        }
      }
      final error = tokenStreamError;
      if (error != null) {
        Error.throwWithStackTrace(error, tokenStreamStackTrace!);
      }

      if (task.isCancellationRequested) {
        _completeCancelled(task);
        return;
      }

      final normalized = _normalizeTranscript(output.toString());
      if (normalized.text.isEmpty) {
        throw LlamaSpeechException(
          'Speech recognition produced an empty transcript.',
        );
      }
      final result = SpeechToTextResult(
        text: normalized.text,
        language: normalized.language,
        segments: <TranscriptSegment>[TranscriptSegment(text: normalized.text)],
        sourceFormat: request.audio.format,
      );
      task._eventsController.add(SpeechToTextFinalEvent(result));
      unawaited(task._eventsController.close());
      task._doneCompleter.complete(SpeechToTextCompletion.completed(result));
    } catch (error, stackTrace) {
      if (task.isCancellationRequested) {
        _completeCancelled(task);
        return;
      }
      final speechError = _speechError(error);
      task._eventsController.addError(speechError, stackTrace);
      unawaited(task._eventsController.close());
      task._doneCompleter.complete(SpeechToTextCompletion.failed(speechError));
    } finally {
      _engineLease!.release(_leaseOwner);
    }
  }

  void _completeCancelled(SpeechToTextTask task) {
    if (!task._eventsController.isClosed) {
      unawaited(task._eventsController.close());
    }
    if (!task._doneCompleter.isCompleted) {
      task._doneCompleter.complete(const SpeechToTextCompletion.cancelled());
    }
  }

  /// Streams transcript text for the prompt-adapted profile.
  ///
  /// Native Qwen3-ASR needs the audio turn wrapped by the model chat template,
  /// so it goes through [LlamaEngine.create]. The Web bridge speech contract is
  /// validated against raw prompt generation with bytes-only audio parts.
  Stream<String> _promptAdapterTokens(SpeechToTextRequest request) {
    final engine = _engine!;
    final params = GenerationParams(
      maxTokens: request.maxOutputTokens,
      temp: 0,
      topK: 1,
      topP: 1,
      penalty: 1,
      seed: 1,
      streamBatchTokenThreshold: 1,
    );
    if (!speechToTextUsesChatTemplate) {
      return engine.generate(
        _promptFor(request),
        parts: <LlamaContentPart>[_contentFor(request.audio)],
        params: params,
      );
    }
    return engine
        .create(
          <LlamaChatMessage>[
            LlamaChatMessage.withContent(
              role: LlamaChatRole.user,
              content: <LlamaContentPart>[
                LlamaTextContent(_promptFor(request)),
                _contentFor(request.audio),
              ],
            ),
          ],
          params: params,
          enableThinking: false,
        )
        .expand((chunk) {
          if (chunk.choices.isEmpty) {
            return const <String>[];
          }
          final text = chunk.choices.first.delta.content;
          return text == null ? const <String>[] : <String>[text];
        });
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
      SpeechAudioPcmInput() => throw LlamaUnsupportedException(
        'The Qwen3-ASR prompt adapter accepts encoded audio only.',
      ),
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

class _LiteRtLmStreamingSession implements SpeechToTextStreamingSession {
  static const int _sampleRateHz = 16000;

  final LiteRtLmSpeechToTextWorker _worker;
  final SpeechAudioFormat _sourceFormat;
  final void Function() _onClosed;
  final StreamController<SpeechToTextEvent> _events =
      StreamController<SpeechToTextEvent>();
  final Completer<SpeechToTextCompletion> _done =
      Completer<SpeechToTextCompletion>();
  late final StreamSubscription<LiteRtLmSpeechToTextUpdate> _workerSubscription;

  Future<void> _operationTail = Future<void>.value();
  bool _finishing = false;
  bool _closed = false;
  int _acceptedSamples = 0;
  String _latestConfirmedText = '';

  _LiteRtLmStreamingSession({
    required LiteRtLmSpeechToTextWorker worker,
    required SpeechAudioFormat sourceFormat,
    required void Function() onClosed,
  }) : _worker = worker,
       _sourceFormat = sourceFormat,
       _onClosed = onClosed {
    _workerSubscription = _worker.updates.listen(
      _handleUpdate,
      onError: (Object error, StackTrace stackTrace) {
        unawaited(_fail(error, stackTrace));
      },
    );
  }

  @override
  Stream<SpeechToTextEvent> get events => _events.stream;

  @override
  Future<SpeechToTextCompletion> get done => _done.future;

  @override
  Future<void> addPcm(Float32List samples) {
    if (_finishing || _closed) {
      throw LlamaStateException(
        'Cannot add audio after the speech stream has finished.',
      );
    }
    if (samples.isEmpty) {
      return Future<void>.value();
    }
    final operation = _operationTail.then((_) async {
      if (_finishing || _closed) {
        throw LlamaStateException(
          'Cannot add audio after the speech stream has finished.',
        );
      }
      final accepted = await _worker.pushAudio(samples);
      if (accepted != samples.length) {
        throw LlamaSpeechException(
          'LiteRT-LM ASR did not accept the complete PCM input.',
          'acceptedSamples=$accepted, suppliedSamples=${samples.length}',
        );
      }
      _acceptedSamples += accepted;
    });
    final guarded = operation.catchError((
      Object error,
      StackTrace stackTrace,
    ) async {
      await _fail(error, stackTrace);
      Error.throwWithStackTrace(error, stackTrace);
    });
    _operationTail = guarded;
    return guarded;
  }

  @override
  Future<void> finish() async {
    if (_finishing || _closed) {
      return;
    }
    _finishing = true;
    try {
      await _operationTail;
      final transcript = await _worker.finish();
      final normalized = transcript.trim().isEmpty
          ? _latestConfirmedText.trim()
          : transcript.trim();
      final result = SpeechToTextResult(
        text: normalized,
        segments: normalized.isEmpty
            ? const <TranscriptSegment>[]
            : <TranscriptSegment>[TranscriptSegment(text: normalized)],
        sourceFormat: _sourceFormat,
        audioDuration: _durationForSamples(_acceptedSamples),
      );
      if (!_events.isClosed) {
        _events.add(SpeechToTextFinalEvent(result));
      }
      await _close();
      if (!_done.isCompleted) {
        _done.complete(SpeechToTextCompletion.completed(result));
      }
    } catch (error, stackTrace) {
      await _fail(error, stackTrace);
    }
  }

  @override
  Future<void> cancel() async {
    if (_closed) {
      return;
    }
    _finishing = true;
    try {
      await _worker.cancel();
    } finally {
      await _close();
      if (!_done.isCompleted) {
        _done.complete(const SpeechToTextCompletion.cancelled());
      }
    }
  }

  void _handleUpdate(LiteRtLmSpeechToTextUpdate update) {
    if (_closed) {
      return;
    }
    _latestConfirmedText = update.confirmedText;
    _acceptedSamples = update.acceptedSamples;
    if (update.isFinal) {
      return;
    }
    final confirmed = update.confirmedText.trim();
    final pending = update.pendingText.trim();
    final text = <String>[
      confirmed,
      pending,
    ].where((part) => part.isNotEmpty).join(' ');
    _events.add(
      SpeechToTextPartialEvent(
        text,
        confirmedText: confirmed,
        pendingText: pending,
        acceptedAudioDuration: _durationForSamples(update.acceptedSamples),
      ),
    );
  }

  Duration _durationForSamples(int samples) => Duration(
    microseconds: (samples * Duration.microsecondsPerSecond) ~/ _sampleRateHz,
  );

  Future<void> _fail(Object error, StackTrace stackTrace) async {
    if (_closed) {
      return;
    }
    final speechError = _speechError(error);
    if (!_events.isClosed) {
      _events.addError(speechError, stackTrace);
    }
    await _close();
    if (!_done.isCompleted) {
      _done.complete(SpeechToTextCompletion.failed(speechError));
    }
  }

  Future<void> _close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    try {
      await _workerSubscription.cancel();
    } catch (_) {
      // Continue releasing the worker and public task lease.
    }
    try {
      await _worker.dispose();
    } catch (_) {
      // Native teardown is best effort after the task has reached a terminal
      // state. The original recognition error remains authoritative.
    }
    if (!_events.isClosed) {
      unawaited(_events.close());
    }
    _onClosed();
  }
}

LlamaException _speechError(Object error) => error is LlamaException
    ? error
    : LlamaSpeechException('Speech recognition failed.', error);
