import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart_chat_example/services/wav_audio_file_validator_io.dart';

void main() {
  late Directory temporaryDirectory;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'llamadart_wav_file_validator_',
    );
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('validates WAV data without loading the complete file', () async {
    final valid = File('${temporaryDirectory.path}/speech.wav');
    await valid.writeAsBytes(_wavBytes(const <int>[1, 2, 3, 4]));
    final empty = File('${temporaryDirectory.path}/empty.wav');
    await empty.writeAsBytes(_wavBytes(const <int>[]));

    expect(await wavFileHasAudioData(valid.path), isTrue);
    expect(await wavFileHasAudioData(empty.path), isFalse);
    expect(
      await wavFileHasAudioData('${temporaryDirectory.path}/missing.wav'),
      isFalse,
    );
  });
}

Uint8List _wavBytes(List<int> samples) {
  final bytes = Uint8List(44 + samples.length);
  bytes.setAll(0, 'RIFF'.codeUnits);
  final data = ByteData.sublistView(bytes);
  data.setUint32(4, bytes.length - 8, Endian.little);
  bytes.setAll(8, 'WAVE'.codeUnits);
  bytes.setAll(12, 'fmt '.codeUnits);
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, 16000, Endian.little);
  data.setUint32(28, 32000, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  bytes.setAll(36, 'data'.codeUnits);
  data.setUint32(40, samples.length, Endian.little);
  bytes.setAll(44, samples);
  return bytes;
}
