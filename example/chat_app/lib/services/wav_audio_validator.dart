import 'dart:typed_data';

/// Returns whether [bytes] contain a RIFF/WAVE file with nonempty audio data.
bool wavBytesHaveAudioData(Uint8List bytes) {
  final fileLength = bytes.length;
  if (fileLength < 20 ||
      bytes[0] != 0x52 ||
      bytes[1] != 0x49 ||
      bytes[2] != 0x46 ||
      bytes[3] != 0x46 ||
      bytes[8] != 0x57 ||
      bytes[9] != 0x41 ||
      bytes[10] != 0x56 ||
      bytes[11] != 0x45) {
    return false;
  }

  var offset = 12;
  while (offset + 8 <= fileLength) {
    final chunkHeader = Uint8List.sublistView(bytes, offset, offset + 8);
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
}
