import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'audio_recording_service.dart';
import 'wav_audio_file_validator_io.dart';

class _IoAudioRecordingService implements AudioRecordingService {
  AudioRecorder? _recorder;
  String? _activePath;
  bool _isRecording = false;
  bool _isDisposed = false;

  @override
  bool get isSupported =>
      Platform.isAndroid ||
      Platform.isIOS ||
      Platform.isMacOS ||
      Platform.isWindows;

  @override
  Future<void> start() async {
    if (_isDisposed || !isSupported) {
      throw const AudioRecordingException(
        AudioRecordingFailure.unsupported,
        'Microphone recording is unavailable on this platform.',
      );
    }
    if (_isRecording) {
      throw const AudioRecordingException(
        AudioRecordingFailure.startFailed,
        'A microphone recording is already in progress.',
      );
    }

    final recorder = _recorder ??= AudioRecorder();
    String? path;
    try {
      final hasPermission = await recorder.hasPermission();
      if (!hasPermission) {
        throw const AudioRecordingException(
          AudioRecordingFailure.permissionDenied,
          'Microphone permission was denied. Enable microphone access in '
          'system settings and try again.',
        );
      }
      if (!await recorder.isEncoderSupported(AudioEncoder.wav)) {
        throw const AudioRecordingException(
          AudioRecordingFailure.unsupported,
          'WAV microphone recording is unavailable on this device.',
        );
      }

      final temporaryDirectory = await getTemporaryDirectory();
      path = p.join(
        temporaryDirectory.path,
        'llamadart_recording_${DateTime.now().microsecondsSinceEpoch}.wav',
      );
      _activePath = path;
      await recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
          androidConfig: AndroidRecordConfig(manageBluetooth: false),
        ),
        path: path,
      );
      _isRecording = true;
    } on AudioRecordingException {
      rethrow;
    } catch (_) {
      _isRecording = false;
      _activePath = null;
      if (path != null) {
        try {
          await recorder.cancel();
        } catch (_) {
          // Best-effort recorder cleanup continues with the file below.
        }
        await _deleteFile(path);
      }
      throw AudioRecordingException(
        AudioRecordingFailure.startFailed,
        _startFailureMessage,
      );
    }
  }

  @override
  Future<String> stop() async {
    final recorder = _recorder;
    final fallbackPath = _activePath;
    if (!_isRecording || recorder == null || fallbackPath == null) {
      throw const AudioRecordingException(
        AudioRecordingFailure.stopFailed,
        'No microphone recording is in progress.',
      );
    }

    try {
      final stoppedPath = await recorder.stop();
      _isRecording = false;
      _activePath = null;
      final path = stoppedPath ?? fallbackPath;
      if (!await wavFileHasAudioData(path)) {
        await _deleteFile(path);
        if (path != fallbackPath) {
          await _deleteFile(fallbackPath);
        }
        throw const AudioRecordingException(
          AudioRecordingFailure.stopFailed,
          'The microphone recording did not contain any audio.',
        );
      }
      return path;
    } on AudioRecordingException {
      rethrow;
    } catch (_) {
      try {
        await recorder.cancel();
      } catch (_) {
        // Best-effort native recorder cleanup continues with the file below.
      }
      _isRecording = false;
      _activePath = null;
      await _deleteFile(fallbackPath);
      throw const AudioRecordingException(
        AudioRecordingFailure.stopFailed,
        'Could not finish the microphone recording.',
      );
    }
  }

  @override
  Future<Uint8List> readRecording(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      if (bytes.isEmpty) {
        throw const AudioRecordingException(
          AudioRecordingFailure.readFailed,
          'The microphone recording could not be read.',
        );
      }
      return bytes;
    } on AudioRecordingException {
      rethrow;
    } catch (_) {
      throw const AudioRecordingException(
        AudioRecordingFailure.readFailed,
        'The microphone recording could not be read.',
      );
    }
  }

  @override
  Future<Uint8List?> readUntrimmedRecording(String path) async => null;

  @override
  Future<void> cancel() async {
    final recorder = _recorder;
    final path = _activePath;
    final shouldCancelRecorder = _isRecording || path != null;
    _isRecording = false;
    _activePath = null;
    if (recorder != null && shouldCancelRecorder) {
      try {
        await recorder.cancel();
      } catch (_) {
        // Best-effort cleanup continues with the temporary file below.
      }
    }
    if (path != null) {
      await _deleteFile(path);
    }
  }

  @override
  Future<void> deleteRecording(String path) => _deleteFile(path);

  @override
  Future<void> dispose() async {
    if (_isDisposed) {
      return;
    }
    _isDisposed = true;
    await cancel();
    final recorder = _recorder;
    _recorder = null;
    await recorder?.dispose();
  }

  Future<void> _deleteFile(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // Temporary recording cleanup is best effort.
    }
  }

  String get _startFailureMessage {
    if (Platform.isWindows) {
      return 'Could not start microphone recording. Check the input device '
          'and allow desktop apps to access the microphone in system settings.';
    }
    return 'Could not start microphone recording. Check that an input device '
        'is available and not in use.';
  }
}

/// Creates the native microphone recorder implementation.
AudioRecordingService createAudioRecordingService() =>
    _IoAudioRecordingService();
