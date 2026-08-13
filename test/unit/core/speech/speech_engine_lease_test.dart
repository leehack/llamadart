@TestOn('vm')
library;

import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/core/speech/speech_engine_lease.dart';
import 'package:test/test.dart';

void main() {
  test('shares exclusive ownership across wrappers for one engine', () async {
    final engine = LlamaEngine(LlamaBackend());
    addTearDown(engine.dispose);
    final first = SpeechEngineLease.forEngine(engine);
    final second = SpeechEngineLease.forEngine(engine);

    expect(first.acquire('speech-to-text'), isTrue);
    expect(first.isActive, isTrue);
    expect(second.activeOwner, 'speech-to-text');
    expect(second.acquire('text-to-speech'), isFalse);

    second.release('text-to-speech');
    expect(first.activeOwner, 'speech-to-text');

    first.release('speech-to-text');
    expect(second.isActive, isFalse);
    expect(second.acquire('text-to-speech'), isTrue);
  });

  test('keeps leases independent between engines', () async {
    final firstEngine = LlamaEngine(LlamaBackend());
    final secondEngine = LlamaEngine(LlamaBackend());
    addTearDown(firstEngine.dispose);
    addTearDown(secondEngine.dispose);

    expect(
      SpeechEngineLease.forEngine(firstEngine).acquire('speech-to-text'),
      isTrue,
    );
    expect(
      SpeechEngineLease.forEngine(secondEngine).acquire('text-to-speech'),
      isTrue,
    );
  });
}
