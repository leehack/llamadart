import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';

import 'speech_wav_source_stub.dart'
    if (dart.library.io) 'speech_wav_source_io.dart';

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
  final SpeechWavSources _sources = SpeechWavSources();

  @override
  Stream<void> get onComplete => _player.onPlayerComplete;

  @override
  Future<void> playWav(Uint8List wavBytes) async =>
      _player.play(await _sources.create(wavBytes));

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> dispose() async {
    try {
      await _player.dispose();
    } finally {
      await _sources.dispose();
    }
  }
}
