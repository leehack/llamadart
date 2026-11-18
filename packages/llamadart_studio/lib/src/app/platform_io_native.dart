import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:path_provider/path_provider.dart';

/// Writes [bytes] to [filePath] on native platforms.
Future<void> writeBytesToPath(String filePath, Uint8List bytes) async {
  final file = File(filePath);
  await file.parent.create(recursive: true);
  await file.writeAsBytes(bytes, flush: true);
}

/// Reads [filePath] from native disk if it exists.
Future<Uint8List?> readBytesFromPath(String filePath) async {
  final file = File(filePath);
  if (!await file.exists()) {
    return null;
  }
  return file.readAsBytes();
}

/// Resolves [MemoryImage] or [FileImage] on native platforms.
ImageProvider? resolveImageProvider({Uint8List? bytes, String? localPath}) {
  if (bytes != null && bytes.isNotEmpty) {
    return MemoryImage(bytes);
  }
  if (localPath != null && localPath.isNotEmpty) {
    final file = File(localPath);
    if (file.existsSync()) {
      return FileImage(file);
    }
  }
  return null;
}

/// Creates a unique WAV file path inside the OS temporary directory.
Future<String> createTempRecordingPath() async {
  final dir = await getTemporaryDirectory();
  await dir.create(recursive: true);
  final ts = DateTime.now().microsecondsSinceEpoch;
  return '${dir.path}/llamadart_studio_mic_$ts.wav';
}

/// Writes WAV [bytes] to a temporary `.wav` file inside the OS temporary
/// directory for reliable native `AVPlayer` playback.
Future<String?> writeTempWavFile(
  Uint8List bytes, {
  required String clipId,
}) async {
  final dir = await getTemporaryDirectory();
  await dir.create(recursive: true);
  final safeId = clipId.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
  final file = File('${dir.path}/llamadart_studio_play_$safeId.wav');
  await file.writeAsBytes(bytes, flush: true);
  return file.path;
}

/// Deletes [filePath] if it exists on disk.
Future<void> deleteFileIfExists(String filePath) async {
  final file = File(filePath);
  if (await file.exists()) {
    await file.delete();
  }
}
