import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_chat_example/models/live_speech_model.dart';
import 'package:llamadart_chat_example/services/live_speech_transcription_service.dart';
import 'package:llamadart_chat_example/services/live_speech_transcription_service_io.dart';

void main() {
  test('converts little-endian PCM16 to normalized float samples', () {
    final bytes = Uint8List.fromList(const <int>[
      0x00,
      0x80,
      0x00,
      0x00,
      0xff,
      0x7f,
    ]);

    expect(pcm16BytesToFloat32(bytes), <double>[-1, 0, 32767 / 32768]);
  });

  test('rejects incomplete PCM16 samples', () {
    expect(
      () => pcm16BytesToFloat32(Uint8List.fromList(const <int>[0x01])),
      throwsFormatException,
    );
  });

  test('reassembles PCM16 samples across arbitrary byte boundaries', () {
    final source = Uint8List.fromList(<int>[
      0x00,
      0x80,
      0xff,
      0xff,
      0x00,
      0x00,
      0xff,
      0x7f,
    ]);
    final aligner = Pcm16ByteStreamAligner();
    final output = BytesBuilder(copy: false);

    for (final byte in source) {
      output.add(aligner.add(Uint8List.fromList(<int>[byte])));
    }
    aligner.finish();

    expect(output.takeBytes(), source);
    expect(
      pcm16BytesToFloat32(source),
      orderedEquals(<double>[-1, -1 / 32768, 0, 32767 / 32768]),
    );
  });

  test('rejects a trailing split PCM16 sample', () {
    final aligner = Pcm16ByteStreamAligner();

    expect(aligner.add(Uint8List.fromList(<int>[0x01])), isEmpty);
    expect(aligner.finish, throwsFormatException);
  });

  test('Moonshine live model pins graph and tokenizer integrity', () {
    final model = LiveSpeechModel.moonshineTiny;

    expect(model.modelSource.filename, 'moonshine_tiny_5s_i8.tflite');
    expect(model.modelSource.sizeBytes, 51936896);
    expect(
      model.modelSource.sha256,
      '97abdeea122d579229091659c24c59d988c6419d453a200f6471241a53b9a9b9',
    );
    expect(model.tokenizerSource.filename, 'moonshine_tokenizer.json');
    expect(model.tokenizerSource.sizeBytes, 1985530);
    expect(
      model.tokenizerSource.sha256,
      '6579793438bc4fbafffacf699169ff53e3769c5a0a0f5e71cdee8853e8130deb',
    );
    expect(model.sizeBytes, 53922426);
    expect(model.languages, <String>['English']);
  });

  test('skips only LiteRT-LM incomplete BPE ASR windows', () {
    final session = _FakeAsrSession(<Object>[
      LlamaSpeechException(
        'LiteRT-LM ASR inference failed with native status 9.',
        'The set of token IDs passed to the tokenizer is part of a BPE '
            'sequence and needs more tokens to be decoded.',
      ),
      const LiteRtLmAsrProcessResult(
        state: LiteRtLmAsrProcessState.update,
        confirmedText: 'recovered',
      ),
    ]);

    expect(processLiveAsrWindow(session), isNull);
    expect(processLiveAsrWindow(session)?.confirmedText, 'recovered');
  });

  test('does not hide unrelated LiteRT-LM ASR failures', () {
    final error = LlamaSpeechException(
      'LiteRT-LM ASR inference failed with native status 9.',
      'Model invocation failed.',
    );
    final session = _FakeAsrSession(<Object>[error]);

    expect(() => processLiveAsrWindow(session), throwsA(same(error)));
  });
}

class _FakeAsrSession implements LiteRtLmAsrRuntimeSession {
  _FakeAsrSession(this._results);

  final List<Object> _results;
  int _index = 0;

  @override
  LiteRtLmAsrProcessResult processNext() {
    final value = _results[_index++];
    if (value is Exception) {
      throw value;
    }
    return value as LiteRtLmAsrProcessResult;
  }

  @override
  void cancel() {}

  @override
  void dispose() {}

  @override
  void finishAudio() {}

  @override
  LiteRtLmAsrPushResult pushAudio(Float32List samples) =>
      LiteRtLmAsrPushResult(acceptedSamples: samples.length, wouldBlock: false);

  @override
  void reset() {}
}
