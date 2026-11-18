import 'dart:typed_data';

import 'package:flutter/painting.dart';

import 'platform_io_stub.dart'
    if (dart.library.io) 'platform_io_native.dart'
    if (dart.library.js_interop) 'platform_io_web.dart'
    as platform_io;

/// Platform-safe file and image helpers that compile cleanly on both native
/// (`dart:io`) and Web/Wasm hosts.
abstract final class StudioPlatformFileHelper {
  /// Writes [bytes] to [filePath] on native platforms (no-op on Web where
  /// `FilePicker.saveFile(bytes: ...)` triggers a browser download directly).
  static Future<void> writeBytesToPath(String filePath, Uint8List bytes) =>
      platform_io.writeBytesToPath(filePath, bytes);

  /// Reads a native path or a recorder-owned browser blob URL.
  static Future<Uint8List?> readBytesFromPath(String filePath) =>
      platform_io.readBytesFromPath(filePath);

  /// Resolves an [ImageProvider] from in-memory [bytes] or a native [localPath].
  static ImageProvider? resolveImageProvider({
    Uint8List? bytes,
    String? localPath,
  }) => platform_io.resolveImageProvider(bytes: bytes, localPath: localPath);

  /// Allocates a temporary recording file path on native platforms.
  static Future<String> createTempRecordingPath() =>
      platform_io.createTempRecordingPath();

  /// Writes WAV [bytes] to a temporary `.wav` file on native platforms so
  /// macOS/iOS `AVPlayer` always receives a proper `.wav` container extension.
  /// Returns `null` on Web/Wasm.
  static Future<String?> writeTempWavFile(
    Uint8List bytes, {
    required String clipId,
  }) => platform_io.writeTempWavFile(bytes, clipId: clipId);

  /// Deletes a native temporary file or releases a browser recording blob URL.
  static Future<void> deleteFileIfExists(String filePath) =>
      platform_io.deleteFileIfExists(filePath);

  /// Releases an owned temporary file without turning cleanup into a UI error.
  static Future<void> releaseTemporaryFile(String filePath) async {
    try {
      await platform_io.deleteFileIfExists(filePath);
    } catch (_) {
      // The OS can already have removed a cache file during app teardown.
    }
  }
}
