import 'dart:math';
import 'dart:typed_data';

Stream<Float32List> readLiveAsrPcm(Stream<List<int>> input) async* {
  const sampleBytes = 4;
  const maxChunkBytes = 16000;
  var carry = <int>[];
  await for (final chunk in input) {
    final bytes = carry.isEmpty ? chunk : [...carry, ...chunk];
    final aligned = bytes.length - bytes.length % sampleBytes;
    carry = bytes.sublist(aligned);
    for (var offset = 0; offset < aligned; offset += maxChunkBytes) {
      final end = min(offset + maxChunkBytes, aligned);
      final data = ByteData.sublistView(
        Uint8List.fromList(bytes.sublist(offset, end)),
      );
      final samples = Float32List(data.lengthInBytes ~/ sampleBytes);
      for (var i = 0; i < samples.length; i++) {
        samples[i] = data.getFloat32(i * sampleBytes, Endian.little);
      }
      yield samples;
    }
  }
  if (carry.isNotEmpty) {
    throw FormatException(
      'Trailing ${carry.length} byte(s) of incomplete float32 PCM.',
    );
  }
}
