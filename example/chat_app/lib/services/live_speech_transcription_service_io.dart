import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:llamadart/llamadart.dart';
import 'package:record/record.dart';

import 'live_speech_transcription_service.dart';

const int _sampleRateHz = 16000;
const String _incompleteBpeSequenceDetails =
    'The set of token IDs passed to the tokenizer is part of a BPE sequence '
    'and needs more tokens to be decoded.';

/// Processes one live-ASR window, tolerating LiteRT-LM's incomplete trailing
/// BPE result so the overlapping next window can recover the omitted suffix.
///
/// Independent-window presets such as Moonshine can end a window in the middle
/// of a UTF-8 BPE sequence, which LiteRT-LM v0.16 reports as a data-loss error
/// even though the session remains usable. Returning `null` skips only that
/// incomplete window; unrelated inference failures still propagate.
LiteRtLmAsrProcessResult? processLiveAsrWindow(
  LiteRtLmAsrRuntimeSession session,
) {
  try {
    return session.processNext();
  } on LlamaSpeechException catch (error) {
    if (error.message ==
            'LiteRT-LM ASR inference failed with native status 9.' &&
        error.details == _incompleteBpeSequenceDetails) {
      return null;
    }
    rethrow;
  }
}

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
    _LiveAsrWorkerClient? worker;
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
      worker = await _LiveAsrWorkerClient.create(
        modelPath: modelPath,
        tokenizerPath: tokenizerPath,
        preset: preset,
      );
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
        worker: worker,
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
      await worker?.dispose();
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
  final _LiveAsrWorkerClient _worker;
  final void Function() _onClosed;
  final StreamController<LiveSpeechTranscriptUpdate> _updates =
      StreamController<LiveSpeechTranscriptUpdate>();
  final Completer<LiveSpeechTranscriptionResult> _done =
      Completer<LiveSpeechTranscriptionResult>();

  StreamSubscription<Uint8List>? _microphoneSubscription;
  Future<void> _feedTail = Future<void>.value();
  final Pcm16ByteStreamAligner _pcmAligner = Pcm16ByteStreamAligner();
  bool _finishing = false;
  bool _acceptingMicrophoneBytes = true;
  bool _closed = false;
  int _acceptedSamples = 0;
  String _latestConfirmedText = '';

  _IoLiveSpeechTranscriptionTask({
    required AudioRecorder recorder,
    required _LiveAsrWorkerClient worker,
    required Stream<Uint8List> microphoneStream,
    required void Function() onClosed,
  }) : _recorder = recorder,
       _worker = worker,
       _onClosed = onClosed {
    _worker.onUpdate = _handleWorkerUpdate;
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
          final accepted = await _worker.pushPcm16(alignedBytes);
          _acceptedSamples += accepted;
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

  void _handleWorkerUpdate(_WorkerTranscriptUpdate update) {
    if (_closed) {
      return;
    }
    _latestConfirmedText = update.confirmedText;
    _updates.add(
      LiveSpeechTranscriptUpdate(
        confirmedText: update.confirmedText,
        pendingText: update.pendingText,
        acceptedAudioDuration: _durationForSamples(update.acceptedSamples),
        isFinal: update.isFinal,
      ),
    );
  }

  Duration get _acceptedAudioDuration => Duration(
    microseconds:
        (_acceptedSamples * Duration.microsecondsPerSecond) ~/ _sampleRateHz,
  );

  Duration _durationForSamples(int samples) => Duration(
    microseconds: (samples * Duration.microsecondsPerSecond) ~/ _sampleRateHz,
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
      final transcript = await _worker.finish();
      if (!_closed) {
        await _complete(transcript);
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
      // Native cancellation remains best effort; worker cleanup still runs.
    }
    await _microphoneSubscription?.cancel();
    _microphoneSubscription = null;
    try {
      await _feedTail;
    } catch (_) {
      // The task is being cancelled, so a queued feed error is terminal too.
    }
    await _worker.cancel();
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
    await _worker.dispose();
    await _recorder.dispose();
    unawaited(_updates.close());
    _onClosed();
  }
}

class _WorkerTranscriptUpdate {
  final String confirmedText;
  final String pendingText;
  final bool isFinal;
  final int acceptedSamples;

  const _WorkerTranscriptUpdate({
    required this.confirmedText,
    required this.pendingText,
    required this.isFinal,
    required this.acceptedSamples,
  });
}

class _LiveAsrWorkerClient {
  final Isolate _isolate;
  final ReceivePort _messages;
  final ReceivePort _errors;
  final ReceivePort _exits;
  final Map<int, Completer<Object?>> _pending = <int, Completer<Object?>>{};
  final Completer<SendPort> _commandPort = Completer<SendPort>();
  int _nextRequestId = 0;
  bool _disposed = false;

  void Function(_WorkerTranscriptUpdate update)? onUpdate;

  _LiveAsrWorkerClient._(
    this._isolate,
    this._messages,
    this._errors,
    this._exits,
  ) {
    _messages.listen(_handleMessage);
    _errors.listen((dynamic message) {
      final summary = message is List && message.isNotEmpty
          ? message.first
          : message;
      _failPending(
        LlamaSpeechException('Live transcription worker failed.', summary),
      );
    });
    _exits.listen((dynamic _) {
      if (!_disposed) {
        _failPending(StateError('Live transcription worker exited.'));
      }
    });
  }

  static Future<_LiveAsrWorkerClient> create({
    required String modelPath,
    required String tokenizerPath,
    required LiteRtLmAsrModelPreset preset,
  }) async {
    final messages = ReceivePort();
    final errors = ReceivePort();
    final exits = ReceivePort();
    final isolate = await Isolate.spawn<SendPort>(
      _liveAsrWorkerMain,
      messages.sendPort,
      errorsAreFatal: true,
      onError: errors.sendPort,
      onExit: exits.sendPort,
      debugName: 'llamadart-live-asr',
    );
    final client = _LiveAsrWorkerClient._(isolate, messages, errors, exits);
    try {
      await client._request('initialize', <String, Object>{
        'modelPath': modelPath,
        'tokenizerPath': tokenizerPath,
        'preset': preset.index,
      });
      return client;
    } catch (_) {
      await client.dispose();
      rethrow;
    }
  }

  Future<int> pushPcm16(Uint8List bytes) async {
    final result = await _request(
      'push',
      TransferableTypedData.fromList(<Uint8List>[bytes]),
    );
    return result as int;
  }

  Future<String> finish() async => (await _request('finish', null)) as String;

  Future<void> cancel() async {
    if (_disposed) {
      return;
    }
    try {
      await _request('cancel', null);
    } catch (_) {
      // Cooperative cancellation remains best effort during worker teardown.
    }
  }

  Future<Object?> _request(String command, Object? payload) async {
    if (_disposed) {
      throw StateError('Live transcription worker is disposed.');
    }
    final port = await _commandPort.future;
    final id = ++_nextRequestId;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    port.send(<String, Object?>{
      'id': id,
      'command': command,
      'payload': payload,
    });
    return completer.future;
  }

  void _handleMessage(dynamic message) {
    if (message is! Map) {
      return;
    }
    final kind = message['kind'];
    if (kind == 'ready') {
      final port = message['port'];
      if (port is SendPort && !_commandPort.isCompleted) {
        _commandPort.complete(port);
      }
      return;
    }
    if (kind == 'update') {
      onUpdate?.call(
        _WorkerTranscriptUpdate(
          confirmedText: message['confirmedText'] as String? ?? '',
          pendingText: message['pendingText'] as String? ?? '',
          isFinal: message['isFinal'] as bool? ?? false,
          acceptedSamples: message['acceptedSamples'] as int? ?? 0,
        ),
      );
      return;
    }
    if (kind != 'response') {
      return;
    }
    final id = message['id'];
    if (id is! int) {
      return;
    }
    final completer = _pending.remove(id);
    if (completer == null) {
      return;
    }
    final error = message['error'];
    if (error != null) {
      completer.completeError(
        LlamaSpeechException('Live transcription failed.', error.toString()),
      );
    } else {
      completer.complete(message['result']);
    }
  }

  void _failPending(Object error) {
    if (!_commandPort.isCompleted) {
      _commandPort.completeError(error);
    }
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(error);
      }
    }
    _pending.clear();
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    try {
      await _request('dispose', null);
    } catch (_) {
      // The isolate may already have exited after an error.
    }
    _disposed = true;
    _isolate.kill(priority: Isolate.immediate);
    _messages.close();
    _errors.close();
    _exits.close();
    _failPending(StateError('Live transcription worker is disposed.'));
  }
}

void _liveAsrWorkerMain(SendPort mainPort) {
  final commands = ReceivePort();
  mainPort.send(<String, Object>{'kind': 'ready', 'port': commands.sendPort});
  LiteRtLmRuntimeClient? runtime;
  LiteRtLmAsrRuntimeSession? session;
  final confirmed = <String>[];
  var acceptedSamples = 0;

  void sendUpdate(LiteRtLmAsrProcessResult result) {
    final value = result.confirmedText.trim();
    if (value.isNotEmpty) {
      confirmed.add(value);
    }
    mainPort.send(<String, Object>{
      'kind': 'update',
      'confirmedText': confirmed.join(' ').trim(),
      'pendingText': result.unconfirmedText,
      'isFinal': result.isFinal,
      'acceptedSamples': acceptedSamples,
    });
  }

  LiteRtLmAsrProcessState processAvailable() {
    final activeSession = session;
    if (activeSession == null) {
      throw StateError('Live transcription session is not initialized.');
    }
    for (var attempt = 0; attempt < 10000; attempt++) {
      final result = processLiveAsrWindow(activeSession);
      if (result == null) {
        return LiteRtLmAsrProcessState.needsMoreAudio;
      }
      if (result.state != LiteRtLmAsrProcessState.update) {
        return result.state;
      }
      sendUpdate(result);
      if (result.isFinal) {
        return LiteRtLmAsrProcessState.endOfStream;
      }
    }
    throw StateError('Live transcription processing did not quiesce.');
  }

  commands.listen((dynamic raw) {
    if (raw is! Map) {
      return;
    }
    final id = raw['id'];
    final command = raw['command'];
    if (id is! int || command is! String) {
      return;
    }
    try {
      Object? result;
      switch (command) {
        case 'initialize':
          final payload = raw['payload'] as Map;
          runtime = LiteRtLmRuntimeClient();
          if (!runtime!.supportsAsrBridge) {
            throw StateError(
              'The installed LiteRT-LM runtime does not expose live ASR.',
            );
          }
          final presetIndex = payload['preset'] as int;
          session = runtime!.createAsrSession(
            LiteRtLmAsrRuntimeConfig(
              modelPath: payload['modelPath'] as String,
              tokenizerPath: payload['tokenizerPath'] as String,
              modelPreset: LiteRtLmAsrModelPreset.values[presetIndex],
            ),
          );
        case 'push':
          final transfer = raw['payload'] as TransferableTypedData;
          final bytes = transfer.materialize().asUint8List();
          final samples = pcm16BytesToFloat32(bytes);
          final activeSession = session;
          if (activeSession == null) {
            throw StateError('Live transcription session is not initialized.');
          }
          var offset = 0;
          while (offset < samples.length) {
            final push = activeSession.pushAudio(
              Float32List.sublistView(samples, offset),
            );
            if (push.acceptedSamples == 0 && !push.wouldBlock) {
              throw StateError(
                'LiteRT-LM ASR accepted no audio without backpressure.',
              );
            }
            offset += push.acceptedSamples;
            acceptedSamples += push.acceptedSamples;
            final state = processAvailable();
            if (push.wouldBlock &&
                push.acceptedSamples == 0 &&
                state == LiteRtLmAsrProcessState.needsMoreAudio) {
              throw StateError(
                'LiteRT-LM ASR reported backpressure without processing a window.',
              );
            }
            if (state == LiteRtLmAsrProcessState.endOfStream) {
              break;
            }
          }
          result = offset;
        case 'finish':
          final activeSession = session;
          if (activeSession == null) {
            throw StateError('Live transcription session is not initialized.');
          }
          activeSession.finishAudio();
          var finalized = false;
          for (var attempt = 0; attempt < 10000; attempt++) {
            final update = processLiveAsrWindow(activeSession);
            if (update == null) {
              continue;
            }
            if (update.state == LiteRtLmAsrProcessState.endOfStream) {
              finalized = true;
              break;
            }
            if (update.state == LiteRtLmAsrProcessState.needsMoreAudio) {
              throw StateError(
                'LiteRT-LM ASR requested audio after finalization.',
              );
            }
            sendUpdate(update);
            if (update.isFinal) {
              finalized = true;
              break;
            }
          }
          if (!finalized) {
            throw StateError('LiteRT-LM ASR did not produce a final result.');
          }
          result = confirmed.join(' ').trim();
        case 'cancel':
          session?.cancel();
        case 'dispose':
          session?.dispose();
          session = null;
          runtime?.dispose();
          runtime = null;
        default:
          throw StateError('Unknown live transcription command: $command');
      }
      mainPort.send(<String, Object?>{
        'kind': 'response',
        'id': id,
        'result': result,
      });
      if (command == 'dispose') {
        commands.close();
      }
    } catch (error) {
      mainPort.send(<String, Object?>{
        'kind': 'response',
        'id': id,
        'error': error.toString(),
      });
    }
  });
}

/// Creates the native live-transcription service.
LiveSpeechTranscriptionService createLiveSpeechTranscriptionService() =>
    _IoLiveSpeechTranscriptionService();
