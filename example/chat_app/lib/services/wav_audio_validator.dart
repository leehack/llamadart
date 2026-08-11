import 'dart:io';
import 'dart:typed_data';

/// Returns whether [path] is a RIFF/WAVE file with a nonempty data chunk.
Future<bool> wavHasAudioData(String path) async {
  RandomAccessFile? input;
  try {
    final file = File(path);
    final fileLength = await file.length();
    if (fileLength < 20) {
      return false;
    }
    input = await file.open();
    final riffHeader = await input.read(12);
    if (riffHeader.length != 12 ||
        riffHeader[0] != 0x52 ||
        riffHeader[1] != 0x49 ||
        riffHeader[2] != 0x46 ||
        riffHeader[3] != 0x46 ||
        riffHeader[8] != 0x57 ||
        riffHeader[9] != 0x41 ||
        riffHeader[10] != 0x56 ||
        riffHeader[11] != 0x45) {
      return false;
    }

    var offset = 12;
    while (offset + 8 <= fileLength) {
      await input.setPosition(offset);
      final chunkHeader = await input.read(8);
      if (chunkHeader.length != 8) {
        return false;
      }
      final chunkSize = ByteData.sublistView(
        chunkHeader,
      ).getUint32(4, Endian.little);
      final payloadOffset = offset + 8;
      final isDataChunk =
          chunkHeader[0] == 0x64 &&
          chunkHeader[1] == 0x61 &&
          chunkHeader[2] == 0x74 &&
          chunkHeader[3] == 0x61;
      if (isDataChunk) {
        return chunkSize > 0 && fileLength - payloadOffset >= chunkSize;
      }

      final paddedChunkSize = chunkSize + (chunkSize.isOdd ? 1 : 0);
      final nextOffset = payloadOffset + paddedChunkSize;
      if (nextOffset <= offset || nextOffset > fileLength) {
        return false;
      }
      offset = nextOffset;
    }
    return false;
  } catch (_) {
    return false;
  } finally {
    await input?.close();
  }
}
