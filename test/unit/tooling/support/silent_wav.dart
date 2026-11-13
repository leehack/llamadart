import 'dart:convert';
import 'dart:typed_data';

/// A valid 0.1 s mono 16 kHz PCM16 WAV of silence.
Uint8List silentWav() {
  const dataBytes = 3200;
  final wav = Uint8List(44 + dataBytes);
  ByteData.sublistView(wav)
    ..setUint32(4, 36 + dataBytes, Endian.little)
    ..setUint32(16, 16, Endian.little)
    ..setUint16(20, 1, Endian.little)
    ..setUint16(22, 1, Endian.little)
    ..setUint32(24, 16000, Endian.little)
    ..setUint32(28, 32000, Endian.little)
    ..setUint16(32, 2, Endian.little)
    ..setUint16(34, 16, Endian.little)
    ..setUint32(40, dataBytes, Endian.little);
  wav
    ..setRange(0, 4, ascii.encode('RIFF'))
    ..setRange(8, 16, ascii.encode('WAVEfmt '))
    ..setRange(36, 40, ascii.encode('data'));
  return wav;
}
