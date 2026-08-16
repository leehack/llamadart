@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/core/speech/litert_lm_speech_to_text_driver_io.dart';
import 'package:test/test.dart';

void main() {
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

    expect(processLiteRtLmSpeechWindow(session), isNull);
    expect(processLiteRtLmSpeechWindow(session)?.confirmedText, 'recovered');
  });

  test('does not hide unrelated LiteRT-LM ASR failures', () {
    final error = LlamaSpeechException(
      'LiteRT-LM ASR inference failed with native status 9.',
      'Model invocation failed.',
    );
    final session = _FakeAsrSession(<Object>[error]);

    expect(() => processLiteRtLmSpeechWindow(session), throwsA(same(error)));
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
