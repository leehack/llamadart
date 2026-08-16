import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_chat_example/models/live_speech_model.dart';

void main() {
  test('live speech catalog pins the recommended Moonshine assets', () {
    final model = LiveSpeechModel.moonshineTiny;

    expect(model.isRecommended, isTrue);
    expect(model.preset, LiteRtLmAsrModelPreset.moonshineTiny);
    expect(model.sizeBytes, 53922426);
    expect(model.sizeLabel, '54 MB');
    expect(
      model.modelSource.url,
      contains('beb49ee5028b4fb21eb989bcbd2db30a433373db'),
    );
    expect(
      model.modelSource.sha256,
      '97abdeea122d579229091659c24c59d988c6419d453a200f6471241a53b9a9b9',
    );
  });

  test('live speech catalog pins the optional Parakeet TDT assets', () {
    final model = LiveSpeechModel.parakeetTdt;

    expect(model.isRecommended, isFalse);
    expect(model.preset, LiteRtLmAsrModelPreset.parakeetTdt0_6bV3);
    expect(model.sizeBytes, 615421032);
    expect(model.sizeLabel, '615 MB');
    expect(
      model.modelSource.url,
      contains('e3a6f2dec6800733f97c87ff55822f32c405983a'),
    );
    expect(
      model.modelSource.sha256,
      '334745b8bc7fd372b1c213516f0b6338bb827b1a2abb3e77ad35fe6fea5cd16b',
    );
    expect(
      model.tokenizerSource.url,
      contains('541d1f99c6b0c3cd0b11a95167540bb8edefd82b'),
    );
    expect(
      model.tokenizerSource.sha256,
      'bd321b096832a3f270bd3b2a88823957920f1a5c5ada71114a26ea729d0cbe91',
    );
  });

  test('unknown persisted live speech selection falls back to Moonshine', () {
    expect(LiveSpeechModel.byId('missing'), LiveSpeechModel.moonshineTiny);
    expect(
      LiveSpeechModel.byId(LiveSpeechModel.parakeetTdt.id),
      LiveSpeechModel.parakeetTdt,
    );
  });
}
