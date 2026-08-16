import 'package:llamadart/src/core/speech/litert_lm_speech_to_text_driver.dart';
import 'package:test/test.dart';

void main() {
  test('support result preserves capability diagnostics', () {
    const support = LiteRtLmSpeechToTextSupport(
      isSupported: false,
      unsupportedReason: 'missing ASR ABI',
    );

    expect(support.isSupported, isFalse);
    expect(support.unsupportedReason, 'missing ASR ABI');
  });

  test('worker update preserves cumulative transcript state', () {
    const update = LiteRtLmSpeechToTextUpdate(
      confirmedText: 'hello',
      pendingText: 'world',
      isFinal: false,
      acceptedSamples: 16000,
    );

    expect(update.confirmedText, 'hello');
    expect(update.pendingText, 'world');
    expect(update.isFinal, isFalse);
    expect(update.acceptedSamples, 16000);
  });
}
