@TestOn('browser')
library;

import 'package:llamadart/llamadart.dart';
import 'package:test/test.dart';

void main() {
  const reason = 'The active backend does not expose decision models.';

  test('the Web backend reports decision models as unsupported', () async {
    final engine = LlamaEngine(LlamaBackend());
    addTearDown(engine.dispose);

    final capabilities = await DecisionEngine.capabilitiesFor(engine);

    expect(capabilities.isSupported, isFalse);
    expect(capabilities.unsupportedReason, reason);
  });

  test('load throws LlamaUnsupportedException on Web', () async {
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
