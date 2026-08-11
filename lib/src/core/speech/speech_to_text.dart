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

/// The representation used by raw PCM speech input.
enum SpeechAudioSampleFormat {
  /// 32-bit IEEE floating-point samples in the range -1.0 to 1.0.
  float32,

  /// Signed 16-bit integer samples.
  signedInt16,
}

/// The kind of audio input accepted by a speech recognizer.
enum SpeechAudioInputKind {
  /// A local encoded audio file.
  file,

  /// Encoded audio held in memory.
  encodedBytes,

  /// Raw PCM samples held in memory.
  pcm,
}

/// Audio metadata supplied with speech input.
class SpeechAudioFormat {
  /// Sample rate in Hertz, when known.
  final int? sampleRateHz;

  /// Number of interleaved audio channels, when known.
  final int? channelCount;

  /// Raw sample representation, when the input is PCM.
  final SpeechAudioSampleFormat? sampleFormat;

  /// Container or codec hint such as `wav`, `mp3`, or `flac`.
  final String? encoding;

  /// MIME type supplied by the caller, when available.
  final String? mimeType;

  /// Creates audio metadata.
  const SpeechAudioFormat({
    this.sampleRateHz,
    this.channelCount,
    this.sampleFormat,
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

/// Raw mono PCM input.
class SpeechPcmInput extends SpeechAudioInput {
  /// Interleaved floating-point PCM samples.
  final Float32List samples;

  /// Creates raw PCM input.
  const SpeechPcmInput(this.samples, {required SpeechAudioFormat format})
    : super(format: format);

  @override
  SpeechAudioInputKind get kind => SpeechAudioInputKind.pcm;
}

/// A request to recognize speech from one complete audio input.
class SpeechToTextRequest {
  /// Audio to transcribe.
  final SpeechAudioInput audio;

  /// Optional BCP-47 language hint, such as `en` or `fr-CA`.
  ///
  /// The first llama.cpp backend forwards this as prompt guidance. It is not a
  /// guarantee that the model supports or obeys the requested language.
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

  /// Accepted audio input representations.
  final Set<SpeechAudioInputKind> inputKinds;

  /// File/byte encodings decoded by the first native backend.
  final Set<String> encodedAudioFormats;

  /// Raw PCM sample rates accepted by the first native backend.
  final Set<int> pcmSampleRatesHz;

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

  /// Maximum number of concurrent tasks owned by one engine wrapper.
  final int maxConcurrentTasks;

  /// Creates a capability snapshot.
  const SpeechToTextCapabilities({
    required this.isSupported,
    this.unsupportedReason,
    this.backendName,
    this.inputKinds = const <SpeechAudioInputKind>{},
    this.encodedAudioFormats = const <String>{},
    this.pcmSampleRatesHz = const <int>{},
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
  final Object? error;

  /// Creates terminal task details.
  const SpeechToTextCompletion({required this.state, this.result, this.error});
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
/// The first implementation supports complete audio inputs on native
/// llama.cpp with an audio-capable multimodal projector, including Qwen3-ASR.
/// It does not yet provide live microphone ingestion, partial transcripts,
/// timestamps, confidence values, or diarization.
class SpeechToTextEngine {
  final LlamaEngine _engine;
  bool _hasActiveTask = false;

  /// Creates a speech recognizer over an existing loaded engine.
  SpeechToTextEngine(this._engine);

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
      inputKinds: const <SpeechAudioInputKind>{
        SpeechAudioInputKind.file,
        SpeechAudioInputKind.encodedBytes,
        SpeechAudioInputKind.pcm,
      },
      encodedAudioFormats: const <String>{'wav', 'mp3', 'flac'},
      pcmSampleRatesHz: const <int>{16000},
      supportsLanguageHints: true,
      supportsLanguageDetection: true,
      supportsCancellation: true,
      maxConcurrentTasks: 1,
    );
  }

  /// Starts recognition for one complete audio input.
  ///
  /// The returned task exposes a future-compatible event stream and explicit
  /// cancellation/completion state. Only one task may run per wrapper because
  /// [LlamaEngine] owns one active generation context.
  Future<SpeechToTextTask> transcribe(SpeechToTextRequest request) async {
    if (_hasActiveTask) {
      throw LlamaStateException(
        'This SpeechToTextEngine already has an active task.',
      );
    }
    _validateRequest(request);

    final currentCapabilities = await capabilities;
    if (!currentCapabilities.isSupported) {
      throw LlamaUnsupportedException(
        currentCapabilities.unsupportedReason ??
            'Speech-to-text is not supported by the active runtime.',
      );
    }

    _hasActiveTask = true;
    late final SpeechToTextTask task;
    task = SpeechToTextTask._(onCancel: _engine.cancelGeneration);
    unawaited(_runTask(task, request));
    return task;
  }

  void _validateRequest(SpeechToTextRequest request) {
    if (request.maxOutputTokens <= 0) {
      throw LlamaSpeechException('maxOutputTokens must be greater than 0.');
    }

    switch (request.audio) {
      case SpeechAudioFileInput(:final path):
        if (path.trim().isEmpty) {
          throw LlamaAudioFormatException('Audio file path must not be empty.');
        }
      case SpeechAudioBytesInput(:final bytes):
        if (bytes.isEmpty) {
          throw LlamaAudioFormatException(
            'Encoded audio bytes must not be empty.',
          );
        }
      case SpeechPcmInput(:final samples, :final format):
        if (samples.isEmpty) {
          throw LlamaAudioFormatException(
            'PCM audio samples must not be empty.',
          );
        }
        if (format?.sampleFormat != SpeechAudioSampleFormat.float32 ||
            format?.sampleRateHz != 16000 ||
            format?.channelCount != 1) {
          throw LlamaAudioFormatException(
            'Raw PCM currently requires 16 kHz mono Float32 samples.',
            format,
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
      task._doneCompleter.complete(
        SpeechToTextCompletion(
          state: SpeechToTextCompletionState.completed,
          result: result,
        ),
      );
    } catch (error, stackTrace) {
      final speechError = error is LlamaSpeechException
          ? error
          : LlamaSpeechException('Speech recognition failed.', error);
      task._eventsController.addError(speechError, stackTrace);
      unawaited(task._eventsController.close());
      task._doneCompleter.complete(
        SpeechToTextCompletion(
          state: SpeechToTextCompletionState.failed,
          error: speechError,
        ),
      );
    } finally {
      _hasActiveTask = false;
    }
  }

  Future<void> _completeCancelled(SpeechToTextTask task) async {
    unawaited(task._eventsController.close());
    task._doneCompleter.complete(
      const SpeechToTextCompletion(
        state: SpeechToTextCompletionState.cancelled,
      ),
    );
  }

  String _promptFor(SpeechToTextRequest request) {
    final prompt = StringBuffer('Transcribe this audio accurately.');
    final languageHint = request.languageHint?.trim();
    if (languageHint != null && languageHint.isNotEmpty) {
      prompt.write(' The requested language is $languageHint.');
    }
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
      SpeechPcmInput(:final samples) => LlamaAudioContent(samples: samples),
    };
  }

  ({String text, String? language}) _normalizeTranscript(String raw) {
    final languagePrefix = RegExp(
      r'^\s*language\s+([^<\r\n]+?)\s*<asr_text>\s*',
      caseSensitive: false,
    ).firstMatch(raw);
    if (languagePrefix != null) {
      return (
        text: raw.substring(languagePrefix.end).trim(),
        language: languagePrefix.group(1)?.trim(),
      );
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
