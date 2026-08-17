import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart_chat_example/services/wav_audio_validator.dart';

void main() {
  test('accepts a WAV with PCM bytes in its data chunk', () {
    expect(wavBytesHaveAudioData(_wavBytes(const <int>[1, 2, 3, 4])), isTrue);
  });

  test('rejects a header-only WAV', () {
    expect(wavBytesHaveAudioData(_wavBytes(const <int>[])), isFalse);
  });

  test('rejects a truncated data chunk and a non-WAV file', () {
    final truncatedBytes = _wavBytes(const <int>[1, 2]);
    ByteData.sublistView(truncatedBytes).setUint32(40, 64, Endian.little);

    expect(wavBytesHaveAudioData(truncatedBytes), isFalse);
    expect(
      wavBytesHaveAudioData(Uint8List.fromList('not audio'.codeUnits)),
      isFalse,
    );
  });

  test('inspects PCM16 duration and signal levels', () {
    final signal = inspectPcm16WavSignal(
      _pcm16Wav(const <int>[100, -100, 200, -200]),
    );

    expect(signal, isNotNull);
    expect(signal!.sampleRate, 16000);
    expect(signal.channels, 1);
    expect(signal.sampleFrames, 4);
    expect(signal.durationSeconds, closeTo(4 / 16000, 0.000001));
    expect(signal.peakAmplitude, 200);
    expect(signal.rmsAmplitude, closeTo(158.11, 0.01));
  });

  test('trims leading and trailing quiet PCM16 frames', () {
    final trimmed = trimPcm16WavSilence(
      _pcm16Wav(const <int>[0, 0, 50, 200, -300, 40, 0]),
    );

    expect(trimmed, isNotNull);
    final signal = inspectPcm16WavSignal(trimmed!);
    expect(signal, isNotNull);
    expect(signal!.sampleFrames, 2);
    expect(signal.peakAmplitude, 300);
    expect(ByteData.sublistView(trimmed).getInt16(44, Endian.little), 200);
    expect(ByteData.sublistView(trimmed).getInt16(46, Endian.little), -300);
  });

  test('returns the original WAV when edge frames contain speech', () {
    final original = _pcm16Wav(const <int>[200, 0, -300]);

    expect(trimPcm16WavSilence(original), same(original));
  });

  test('rejects a PCM16 WAV containing only quiet frames', () {
    expect(trimPcm16WavSilence(_pcm16Wav(const <int>[0, 20, -20, 0])), isNull);
  });

  test('rejects a non-PCM16 WAV from signal inspection', () {
    final bytes = _wavBytes(const <int>[1, 2, 3, 4]);
    ByteData.sublistView(bytes).setUint16(34, 8, Endian.little);

    expect(inspectPcm16WavSignal(bytes), isNull);
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

Uint8List _pcm16Wav(List<int> samples) {
  final bytes = _wavBytes(List<int>.filled(samples.length * 2, 0));
  final data = ByteData.sublistView(bytes);
  for (var index = 0; index < samples.length; index += 1) {
    data.setInt16(44 + index * 2, samples[index], Endian.little);
  }
  return bytes;
}
