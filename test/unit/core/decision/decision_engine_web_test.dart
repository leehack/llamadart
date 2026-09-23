@TestOn('browser')
library;

import 'package:llamadart/llamadart.dart';
import 'package:test/test.dart';

void main() {
  const reason = 'Load a model first.';

  test('the Web backend asks for a model before probing', () async {
    final engine = LlamaEngine(LlamaBackend());
    addTearDown(engine.dispose);

    final capabilities = await DecisionEngine.capabilitiesFor(engine);

    expect(capabilities.isSupported, isFalse);
    expect(capabilities.unsupportedReason, reason);
  });

  test('load without a model throws LlamaUnsupportedException', () async {
    final engine = LlamaEngine(LlamaBackend());
    addTearDown(engine.dispose);

    await expectLater(
      DecisionEngine.load(engine, headPath: 'laya-head.safetensors'),
      throwsA(
        isA<LlamaUnsupportedException>().having(
          (error) => error.message,
          'message',
          reason,
        ),
      ),
    );
  });
}
