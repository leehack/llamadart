import 'dart:typed_data';

import 'audio_recording_service_stub.dart'
    if (dart.library.io) 'audio_recording_service_io.dart'
    if (dart.library.js_interop) 'audio_recording_service_web.dart';

/// The reason a microphone recording operation could not be completed.
enum AudioRecordingFailure {
  /// Recording is unavailable on the current platform or runtime.
  unsupported,

  /// The user did not grant microphone access.
  permissionDenied,

  /// The recorder could not begin capturing audio.
  startFailed,

  /// The recorder could not finalize captured audio.
  stopFailed,

  /// A finalized recording could not be read for model input.
  readFailed,
}

/// A user-actionable microphone recording failure.
class AudioRecordingException implements Exception {
  /// The failure category.
  final AudioRecordingFailure failure;

  /// A message suitable for display in the chat UI.
  final String message;

  /// Creates a recording failure.
  const AudioRecordingException(this.failure, this.message);

  @override
  String toString() => message;
}

/// Captures temporary audio for the chat app's speech flows.
abstract class AudioRecordingService {
  /// Creates the platform recording service.
  factory AudioRecordingService() => createAudioRecordingService();

  /// Whether this runtime has a microphone recorder implementation.
  bool get isSupported;

  /// Starts a new temporary recording.
  Future<void> start();

  /// Stops the active recording and returns its temporary WAV reference.
  ///
  /// Native implementations return a filesystem path. Browser implementations
  /// return an object URL that remains valid until [deleteRecording].
  Future<String> stop();

  /// Reads a finalized temporary recording as encoded WAV bytes.
  Future<Uint8List> readRecording(String path);

  /// Cancels the active recording and removes any partial file.
  Future<void> cancel();

  /// Removes a completed temporary recording.
  Future<void> deleteRecording(String path);

  /// Releases recorder resources and removes any active recording.
  Future<void> dispose();
}
