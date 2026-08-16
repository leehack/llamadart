import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:llamadart/llamadart.dart';
import 'package:record/record.dart';

import 'live_speech_transcription_service.dart';

const int _sampleRateHz = 16000;

class _IoLiveSpeechTranscriptionService
    implements LiveSpeechTranscriptionService {
  _IoLiveSpeechTranscriptionTask? _activeTask;
  bool _isDisposed = false;

  @override
  bool get isSupported =>
      Platform.isAndroid ||
      Platform.isIOS ||
      Platform.isMacOS ||
      Platform.isWindows;

  @override
  Future<LiveSpeechTranscriptionTask> start({
    required String modelPath,
    required String tokenizerPath,
    required LiteRtLmAsrModelPreset preset,
  }) async {
    if (_isDisposed || !isSupported) {
      throw UnsupportedError(
        'Live microphone transcription is unavailable on this platform.',
      );
    }
    if (_activeTask != null) {
      throw StateError('A live transcription task is already active.');
    }
    if (!await File(modelPath).exists()) {
      throw StateError('Live transcription model is not installed.');
    }
    if (!await File(tokenizerPath).exists()) {
      throw StateError('Live transcription tokenizer is not installed.');
    }

    final recorder = AudioRecorder();
    SpeechToTextStreamingSession? speechSession;
    try {
      if (!await recorder.hasPermission()) {
        throw StateError(
          'Microphone permission was denied. Enable microphone access in '
          'system settings and try again.',
        );
      }
      if (!await recorder.isEncoderSupported(AudioEncoder.pcm16bits)) {
        throw UnsupportedError(
          'PCM16 microphone streaming is unavailable on this device.',
        );
      }
      final speechEngine = SpeechToTextEngine.liteRtLm(
        LiteRtLmAsrRuntimeConfig(
          modelPath: modelPath,
          tokenizerPath: tokenizerPath,
          modelPreset: preset,
        ),
      );
      speechSession = await speechEngine.startStream();
      final stream = await recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: _sampleRateHz,
          numChannels: 1,
          androidConfig: AndroidRecordConfig(manageBluetooth: false),
        ),
      );
      late final _IoLiveSpeechTranscriptionTask task;
      task = _IoLiveSpeechTranscriptionTask(
        recorder: recorder,
        speechSession: speechSession,
        microphoneStream: stream,
        onClosed: () {
          if (identical(_activeTask, task)) {
            _activeTask = null;
          }
        },
      );
      _activeTask = task;
      return task;
    } catch (_) {
      await recorder.dispose();
      await speechSession?.cancel();
      rethrow;
    }
  }

  @override
  Future<void> dispose() async {
    if (_isDisposed) {
      return;
    }
    _isDisposed = true;
    final task = _activeTask;
    _activeTask = null;
    await task?.cancel();
  }
}

class _IoLiveSpeechTranscriptionTask implements LiveSpeechTranscriptionTask {
  final AudioRecorder _recorder;
  final SpeechToTextStreamingSession _speechSession;
  final void Function() _onClosed;
  final StreamController<LiveSpeechTranscriptUpdate> _updates =
      StreamController<LiveSpeechTranscriptUpdate>();
  final Completer<LiveSpeechTranscriptionResult> _done =
      Completer<LiveSpeechTranscriptionResult>();

  StreamSubscription<Uint8List>? _microphoneSubscription;
  StreamSubscription<SpeechToTextEvent>? _speechSubscription;
  Future<void> _feedTail = Future<void>.value();
  final Pcm16ByteStreamAligner _pcmAligner = Pcm16ByteStreamAligner();
  bool _finishing = false;
  bool _acceptingMicrophoneBytes = true;
  bool _closed = false;
  int _acceptedSamples = 0;
  String _latestConfirmedText = '';

  _IoLiveSpeechTranscriptionTask({
    required AudioRecorder recorder,
    required SpeechToTextStreamingSession speechSession,
    required Stream<Uint8List> microphoneStream,
    required void Function() onClosed,
  }) : _recorder = recorder,
       _speechSession = speechSession,
       _onClosed = onClosed {
    _speechSubscription = _speechSession.events.listen(
      _handleSpeechEvent,
      onError: (Object error, StackTrace stackTrace) {
        unawaited(_fail(error, stackTrace));
      },
    );
    _microphoneSubscription = microphoneStream.listen(
      _handleMicrophoneBytes,
      onError: (Object error, StackTrace stackTrace) {
        unawaited(_fail(error, stackTrace));
      },
    );
  }

  @override
  Stream<LiveSpeechTranscriptUpdate> get updates => _updates.stream;

  @override
  Future<LiveSpeechTranscriptionResult> get done => _done.future;

  void _handleMicrophoneBytes(Uint8List bytes) {
    if (!_acceptingMicrophoneBytes || _closed || bytes.isEmpty) {
      return;
    }
    final alignedBytes = _pcmAligner.add(bytes);
    if (alignedBytes.isEmpty) {
      return;
    }
    final subscription = _microphoneSubscription;
    subscription?.pause();
    _feedTail = _feedTail
        .then((_) async {
          if (_closed) {
            return;
          }
          final samples = pcm16BytesToFloat32(alignedBytes);
          await _speechSession.addPcm(samples);
          _acceptedSamples += samples.length;
        })
        .whenComplete(() {
          if (_acceptingMicrophoneBytes && !_closed) {
            subscription?.resume();
          }
        })
        .catchError((Object error, StackTrace stackTrace) {
          unawaited(_fail(error, stackTrace));
        });
  }

  void _handleSpeechEvent(SpeechToTextEvent event) {
    if (_closed) {
      return;
    }
    switch (event) {
      case SpeechToTextPartialEvent(
        :final text,
        :final confirmedText,
        :final pendingText,
        :final acceptedAudioDuration,
      ):
        _latestConfirmedText = confirmedText ?? text;
        _updates.add(
          LiveSpeechTranscriptUpdate(
            confirmedText: confirmedText ?? text,
            pendingText: pendingText ?? '',
            acceptedAudioDuration:
                acceptedAudioDuration ?? _acceptedAudioDuration,
            isFinal: false,
          ),
        );
      case SpeechToTextFinalEvent(:final result):
        _latestConfirmedText = result.text;
        _updates.add(
          LiveSpeechTranscriptUpdate(
            confirmedText: result.text,
            pendingText: '',
            acceptedAudioDuration:
                result.audioDuration ?? _acceptedAudioDuration,
            isFinal: true,
          ),
        );
    }
  }

  Duration get _acceptedAudioDuration => Duration(
    microseconds:
        (_acceptedSamples * Duration.microsecondsPerSecond) ~/ _sampleRateHz,
  );

  @override
  Future<void> stop() async {
    if (_finishing || _closed) {
      return;
    }
    _finishing = true;
    try {
      await _recorder.stop();
      _acceptingMicrophoneBytes = false;
      await _feedTail;
      _pcmAligner.finish();
      await _microphoneSubscription?.cancel();
      _microphoneSubscription = null;
      await _speechSession.finish();
      final completion = await _speechSession.done;
      switch (completion.state) {
        case SpeechToTextCompletionState.completed:
          await _complete(completion.result?.text ?? '');
        case SpeechToTextCompletionState.cancelled:
          throw StateError('Live transcription was cancelled.');
        case SpeechToTextCompletionState.failed:
          throw completion.error ??
              LlamaSpeechException('Live transcription failed.');
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
    _acceptingMicrophoneBytes = false;
    try {
      await _recorder.cancel();
    } catch (_) {
      // Native cancellation remains best effort; ASR cleanup still runs.
    }
    await _microphoneSubscription?.cancel();
    _microphoneSubscription = null;
    try {
      await _feedTail;
    } catch (_) {
      // The task is being cancelled, so a queued feed error is terminal too.
    }
    await _speechSession.cancel();
    await _close();
    if (!_done.isCompleted) {
      _done.completeError(StateError('Live transcription was cancelled.'));
    }
  }

  Future<void> _complete(String transcript) async {
    final normalized = transcript.trim().isEmpty
        ? _latestConfirmedText.trim()
        : transcript.trim();
    final result = LiveSpeechTranscriptionResult(
      text: normalized,
      acceptedAudioDuration: _acceptedAudioDuration,
    );
    await _close();
    if (!_done.isCompleted) {
      _done.complete(result);
    }
  }

  Future<void> _fail(Object error, StackTrace stackTrace) async {
    if (_closed) {
      return;
    }
    _finishing = true;
    _acceptingMicrophoneBytes = false;
    try {
      await _recorder.cancel();
    } catch (_) {
      // Best-effort native cleanup.
    }
    await _microphoneSubscription?.cancel();
    _microphoneSubscription = null;
    try {
      await _speechSession.cancel();
    } catch (_) {
      // Preserve the first capture or inference failure.
    }
    await _close();
    if (!_done.isCompleted) {
      _done.completeError(error, stackTrace);
    }
  }

  Future<void> _close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    await _speechSubscription?.cancel();
    _speechSubscription = null;
    await _recorder.dispose();
    if (!_updates.isClosed) {
      unawaited(_updates.close());
    }
    _onClosed();
  }
}

/// Creates the native live-transcription service.
LiveSpeechTranscriptionService createLiveSpeechTranscriptionService() =>
    _IoLiveSpeechTranscriptionService();
