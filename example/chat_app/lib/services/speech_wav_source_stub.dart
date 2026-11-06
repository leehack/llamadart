import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';

/// Supplies WAV buffers to the player directly as byte sources.
class SpeechWavSources {
  /// Returns a playable source for one complete WAV buffer.
  Future<Source> create(Uint8List wavBytes) async =>
      BytesSource(wavBytes, mimeType: 'audio/wav');

  /// Releases nothing; byte sources own no files.
  Future<void> dispose() async {}
}
