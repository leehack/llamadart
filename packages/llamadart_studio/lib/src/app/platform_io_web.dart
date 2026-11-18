import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

export 'platform_io_stub.dart'
    show
        writeBytesToPath,
        resolveImageProvider,
        createTempRecordingPath,
        writeTempWavFile;

/// Reads a recorder-owned browser blob without treating it as a native path.
Future<Uint8List?> readBytesFromPath(String filePath) async {
  if (!filePath.startsWith('blob:')) return null;
  final response = await web.window.fetch(filePath.toJS).toDart;
  if (!response.ok) {
    throw StateError('The recorded audio could not be read.');
  }
  final buffer = await response.arrayBuffer().toDart;
  return buffer.toDart.asUint8List();
}

/// Releases the recording's browser allocation after use.
Future<void> deleteFileIfExists(String filePath) async {
  if (filePath.startsWith('blob:')) web.URL.revokeObjectURL(filePath);
}
