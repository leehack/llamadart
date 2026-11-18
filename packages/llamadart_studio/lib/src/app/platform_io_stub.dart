import 'dart:typed_data';

import 'package:flutter/painting.dart';

/// Web/Wasm stub implementation for platform file operations.
Future<void> writeBytesToPath(String filePath, Uint8List bytes) async {}

/// Web/Wasm stub implementation returning `null` for filesystem paths.
Future<Uint8List?> readBytesFromPath(String filePath) async => null;

/// Resolves [MemoryImage] when [bytes] are present on Web.
ImageProvider? resolveImageProvider({Uint8List? bytes, String? localPath}) {
  if (bytes != null && bytes.isNotEmpty) {
    return MemoryImage(bytes);
  }
  return null;
}

/// Returns a logical filename for browser MediaRecorder blobs.
Future<String> createTempRecordingPath() async => 'studio_recording.wav';

/// Web/Wasm stub returning `null` so playback uses `BytesSource` directly.
Future<String?> writeTempWavFile(
  Uint8List bytes, {
  required String clipId,
}) async => null;

/// No-op on Web/Wasm.
Future<void> deleteFileIfExists(String filePath) async {}
