import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';

/// Supplies WAV buffers to the player as `.wav` files this instance owns.
///
/// On macOS, iOS and Linux, audioplayers writes a byte source into
/// `getTemporaryDirectory()` without creating it, and in a sandboxed macOS app
/// nothing else creates that directory.
class SpeechWavSources {
  /// Creates a supplier that keeps its files under [root], by default the
  /// system temporary directory.
  SpeechWavSources({Directory? root}) : _root = root ?? Directory.systemTemp;

  final Directory _root;
  Future<Directory>? _directory;
  File? _current;
  int _nextIndex = 0;

  /// Writes [wavBytes] to a new file, deletes the previous one and returns a
  /// source for the new file.
  Future<Source> create(Uint8List wavBytes) async {
    final directory = await (_directory ??= _root.createTemp(
      'llamadart_chat_speech_',
    ));
    final file = File('${directory.path}/speech_${_nextIndex++}.wav');
    await file.writeAsBytes(wavBytes);
    final previous = _current;
    _current = file;
    if (previous != null) {
      await _deleteIgnoringErrors(previous);
    }
    return DeviceFileSource(file.path, mimeType: 'audio/wav');
  }

  /// Deletes every file this instance wrote.
  Future<void> dispose() async {
    final directory = _directory;
    _directory = null;
    _current = null;
    if (directory != null) {
      await _deleteIgnoringErrors(await directory, recursive: true);
    }
  }
}

Future<void> _deleteIgnoringErrors(
  FileSystemEntity entity, {
  bool recursive = false,
}) async {
  try {
    await entity.delete(recursive: recursive);
  } on FileSystemException {
    return;
  }
}
