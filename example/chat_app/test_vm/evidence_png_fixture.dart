import 'dart:io';
import 'dart:typed_data';

/// Builds a filter-0 PNG with all-zero samples. [rowBytes] overrides the
/// scanline length the header implies, to declare one layout and store another.
Uint8List evidencePngFixture({
  required int width,
  required int height,
  int bitDepth = 16,
  int colorType = 6,
  int interlace = 0,
  int? rowBytes,
}) {
  const channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4};
  final header = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, bitDepth)
    ..setUint8(9, colorType)
    ..setUint8(12, interlace);
  final scanlines = Uint8List(
    ((rowBytes ?? width * channels[colorType]! * bitDepth ~/ 8) + 1) * height,
  );
  final out = BytesBuilder()..add(const [137, 80, 78, 71, 13, 10, 26, 10]);
  for (final (type, data) in [
    ('IHDR', header.buffer.asUint8List()),
    ('IDAT', zlib.encode(scanlines)),
    ('IEND', const <int>[]),
  ]) {
    final body = [...type.codeUnits, ...data];
    out
      ..add(_uint32(data.length))
      ..add(body)
      ..add(_uint32(_crc32(body)));
  }
  return out.takeBytes();
}

Uint8List _uint32(int value) =>
    (ByteData(4)..setUint32(0, value)).buffer.asUint8List();

int _crc32(List<int> bytes) {
  var crc = 0xffffffff;
  for (final byte in bytes) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = crc & 1 != 0 ? 0xedb88320 ^ (crc >> 1) : crc >> 1;
    }
  }
  return crc ^ 0xffffffff;
}
