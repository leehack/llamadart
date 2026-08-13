import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';

/// Plays complete synthesized WAV buffers in the chat example.
abstract class SpeechPlaybackService {
  /// Creates the native audio-player implementation.
  factory SpeechPlaybackService() => _AudioPlayersSpeechPlaybackService();

  /// Emits when the active clip reaches its end.
  Stream<void> get onComplete;

  /// Starts playing one complete WAV buffer.
  Future<void> playWav(Uint8List wavBytes);

  /// Stops the active clip, if any.
  Future<void> stop();

  /// Releases native playback resources.
  Future<void> dispose();
}

class _AudioPlayersSpeechPlaybackService implements SpeechPlaybackService {
  final AudioPlayer _player = AudioPlayer();

  @override
  Stream<void> get onComplete => _player.onPlayerComplete;

  @override
  Future<void> playWav(Uint8List wavBytes) =>
      _player.play(BytesSource(wavBytes, mimeType: 'audio/wav'));

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> dispose() => _player.dispose();
}
