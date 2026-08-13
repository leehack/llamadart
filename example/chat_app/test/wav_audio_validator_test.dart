import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart_chat_example/services/wav_audio_validator.dart';

void main() {
  late Directory temporaryDirectory;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'llamadart_wav_validator_',
    );
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('accepts a WAV with PCM bytes in its data chunk', () async {
    final file = File('${temporaryDirectory.path}/speech.wav');
    await file.writeAsBytes(_wavBytes(const <int>[1, 2, 3, 4]));

    expect(await wavHasAudioData(file.path), isTrue);
  });

  test('rejects a header-only WAV', () async {
    final file = File('${temporaryDirectory.path}/silent.wav');
    await file.writeAsBytes(_wavBytes(const <int>[]));

    expect(await wavHasAudioData(file.path), isFalse);
  });

  test('rejects a truncated data chunk and a non-WAV file', () async {
    final truncated = File('${temporaryDirectory.path}/truncated.wav');
    final truncatedBytes = _wavBytes(const <int>[1, 2]);
    ByteData.sublistView(truncatedBytes).setUint32(40, 64, Endian.little);
    await truncated.writeAsBytes(truncatedBytes);
    final invalid = File('${temporaryDirectory.path}/invalid.wav');
    await invalid.writeAsString('not audio');

    expect(await wavHasAudioData(truncated.path), isFalse);
    expect(await wavHasAudioData(invalid.path), isFalse);
    expect(
      await wavHasAudioData('${temporaryDirectory.path}/missing.wav'),
      isFalse,
    );
  });
}

Uint8List _wavBytes(List<int> audioBytes) {
  final bytes = Uint8List(44 + audioBytes.length);
  final data = ByteData.sublistView(bytes);

  void writeAscii(int offset, String value) {
    for (var index = 0; index < value.length; index += 1) {
      bytes[offset + index] = value.codeUnitAt(index);
    }
  }

  writeAscii(0, 'RIFF');
  data.setUint32(4, bytes.length - 8, Endian.little);
  writeAscii(8, 'WAVE');
  writeAscii(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, 16000, Endian.little);
  data.setUint32(28, 32000, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  writeAscii(36, 'data');
  data.setUint32(40, audioBytes.length, Endian.little);
  bytes.setRange(44, bytes.length, audioBytes);
  return bytes;
}
