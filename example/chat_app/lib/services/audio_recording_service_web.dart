import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';
import 'package:web/web.dart' as web;

import 'audio_recording_service.dart';
import 'wav_audio_validator.dart';

class _WebAudioRecordingService implements AudioRecordingService {
  static const Duration _captureWarmup = Duration(milliseconds: 500);
  // The published Qwen3-ASR Web runtime consistently returns an empty
  // completion for clean utterances shorter than two seconds. Reject those
  // captures before model generation so users get an actionable retry instead
  // of waiting for two empty inference attempts.
  static const double _minimumDurationSeconds = 2;
  static const int _minimumPeakAmplitude = 96;
  static const double _minimumRmsAmplitude = 20;

  AudioRecorder? _recorder;
  String? _completedRecordingUrl;
  Uint8List? _completedRecordingBytes;
  bool _isRecording = false;
  bool _isDisposed = false;

  @override
  bool get isSupported => web.window.isSecureContext;

  @override
  Future<void> start() async {
    if (_isDisposed || !isSupported) {
      throw const AudioRecordingException(
        AudioRecordingFailure.unsupported,
        'Browser microphone recording requires a secure HTTPS or localhost '
        'context.',
      );
    }
    if (_isRecording) {
      throw const AudioRecordingException(
        AudioRecordingFailure.startFailed,
        'A microphone recording is already in progress.',
      );
    }

    final recorder = _recorder ??= AudioRecorder();
    try {
      if (!await recorder.hasPermission()) {
        throw const AudioRecordingException(
          AudioRecordingFailure.permissionDenied,
          'Microphone permission was denied. Allow microphone access in the '
          'browser site settings and try again.',
        );
      }
      if (!await recorder.isEncoderSupported(AudioEncoder.wav)) {
        throw const AudioRecordingException(
          AudioRecordingFailure.unsupported,
          'WAV microphone recording is unavailable in this browser.',
        );
      }
      await recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
          // Browser input levels vary substantially across built-in,
          // Bluetooth, and continuity microphones. Apply the browser's
          // speech-oriented gain and noise processing before the worklet
          // converts the capture to PCM16. Echo cancellation stays disabled
          // because the app does not play audio while recording and some
          // browsers otherwise suppress nearby speech as playback leakage.
          autoGain: true,
          echoCancel: false,
          noiseSuppress: true,
        ),
        path: '',
      );
      _isRecording = true;
      // Keep the UI in its preparing state while Chromium connects the input
      // stream to the AudioWorklet. Speaking during that startup window can
      // clip the beginning of an utterance, which Qwen3-ASR may reject as an
      // empty transcript.
      await Future<void>.delayed(_captureWarmup);
    } on AudioRecordingException {
      rethrow;
    } catch (_) {
      _isRecording = false;
      try {
        await recorder.cancel();
      } catch (_) {
        // Preserve the actionable recorder failure below.
      }
      throw const AudioRecordingException(
        AudioRecordingFailure.startFailed,
        'Could not start browser microphone recording. Check the selected '
        'input device and site permission.',
      );
    }
  }

  @override
  Future<String> stop() async {
    final recorder = _recorder;
    if (!_isRecording || recorder == null) {
      throw const AudioRecordingException(
        AudioRecordingFailure.stopFailed,
        'No microphone recording is in progress.',
      );
    }

    String? url;
    try {
      url = await recorder.stop();
      _isRecording = false;
      if (url == null || url.isEmpty) {
        throw const AudioRecordingException(
          AudioRecordingFailure.stopFailed,
          'The browser did not return a completed microphone recording.',
        );
      }
      final bytes = await _readBlobUrl(url);
      if (!wavBytesHaveAudioData(bytes)) {
        web.URL.revokeObjectURL(url);
        throw const AudioRecordingException(
          AudioRecordingFailure.stopFailed,
          'The microphone recording did not contain valid WAV audio.',
        );
      }
      final capturedSignal = inspectPcm16WavSignal(bytes);
      if (capturedSignal == null) {
        web.URL.revokeObjectURL(url);
        throw const AudioRecordingException(
          AudioRecordingFailure.stopFailed,
          'The browser microphone returned an unsupported WAV encoding. '
          'Select a different input device or browser and try again.',
        );
      }
      final speechBytes = trimPcm16WavSilence(bytes, signal: capturedSignal);
      final signal = speechBytes == null
          ? null
          : inspectPcm16WavSignal(speechBytes);
      if (signal == null) {
        web.URL.revokeObjectURL(url);
        throw const AudioRecordingException(
          AudioRecordingFailure.stopFailed,
          'The microphone recording was silent or too quiet. Check the '
          'selected input device, speak closer to the microphone, and try '
          'again.',
        );
      }
      if (signal.durationSeconds < _minimumDurationSeconds) {
        web.URL.revokeObjectURL(url);
        throw const AudioRecordingException(
          AudioRecordingFailure.stopFailed,
          'The microphone recording was too short. Record at least two '
          'seconds and speak a complete phrase before choosing Stop & '
          'transcribe.',
        );
      }
      if (signal.peakAmplitude < _minimumPeakAmplitude ||
          signal.rmsAmplitude < _minimumRmsAmplitude) {
        web.URL.revokeObjectURL(url);
        throw const AudioRecordingException(
          AudioRecordingFailure.stopFailed,
          'The microphone recording was silent or too quiet. Check the '
          'selected input device, speak closer to the microphone, and try '
          'again.',
        );
      }
      debugPrint(
        'Browser microphone WAV: '
        '${signal.durationSeconds.toStringAsFixed(2)} s, '
        '${signal.sampleRate} Hz, ${signal.channels} channel(s), '
        'peak ${signal.peakAmplitude}, '
        'RMS ${signal.rmsAmplitude.toStringAsFixed(1)}.',
      );
      _revokeCompletedRecording();
      _completedRecordingUrl = url;
      _completedRecordingBytes = speechBytes;
      return url;
    } on AudioRecordingException {
      rethrow;
    } catch (_) {
      _isRecording = false;
      if (url != null && url.startsWith('blob:')) {
        web.URL.revokeObjectURL(url);
      }
      try {
        await recorder.cancel();
      } catch (_) {
        // Preserve the actionable recorder failure below.
      }
      throw const AudioRecordingException(
        AudioRecordingFailure.stopFailed,
        'Could not finish browser microphone recording.',
      );
    }
  }

  @override
  Future<Uint8List> readRecording(String path) async {
    try {
      final bytes = path == _completedRecordingUrl
          ? _completedRecordingBytes
          : await _readBlobUrl(path);
      if (bytes == null) {
        throw const AudioRecordingException(
          AudioRecordingFailure.readFailed,
          'The microphone recording could not be read.',
        );
      }
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
  Future<void> cancel() async {
    final recorder = _recorder;
    final shouldCancel = _isRecording;
    _isRecording = false;
    if (recorder != null && shouldCancel) {
      try {
        await recorder.cancel();
      } catch (_) {
        // Browser microphone cleanup is best effort.
      }
    }
  }

  @override
  Future<void> deleteRecording(String path) async {
    if (path == _completedRecordingUrl) {
      _completedRecordingUrl = null;
      _completedRecordingBytes = null;
    }
    if (path.startsWith('blob:')) {
      web.URL.revokeObjectURL(path);
    }
  }

  @override
  Future<void> dispose() async {
    if (_isDisposed) {
      return;
    }
    _isDisposed = true;
    await cancel();
    _revokeCompletedRecording();
    final recorder = _recorder;
    _recorder = null;
    await recorder?.dispose();
  }

  Future<Uint8List> _readBlobUrl(String url) async {
    final response = await web.window.fetch(url.toJS).toDart;
    if (!response.ok) {
      throw StateError(
        'Recording fetch failed with status ${response.status}.',
      );
    }
    final buffer = await response.arrayBuffer().toDart;
    return buffer.toDart.asUint8List();
  }

  void _revokeCompletedRecording() {
    final url = _completedRecordingUrl;
    _completedRecordingUrl = null;
    _completedRecordingBytes = null;
    if (url != null && url.startsWith('blob:')) {
      web.URL.revokeObjectURL(url);
    }
  }
}

/// Creates the browser microphone recorder implementation.
AudioRecordingService createAudioRecordingService() =>
    _WebAudioRecordingService();
