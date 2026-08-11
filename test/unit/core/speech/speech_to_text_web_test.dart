@TestOn('browser')
library;

import 'package:llamadart/llamadart.dart';
import 'package:test/test.dart';

void main() {
  test('dedicated speech-to-text is explicitly unsupported on Web', () async {
    final engine = SpeechToTextEngine(LlamaEngine(_WebBackend()));

    final capabilities = await engine.capabilities;

    expect(capabilities.isSupported, isFalse);
    expect(capabilities.unsupportedReason, contains('not available on Web'));
    expect(capabilities.unsupportedReason, contains('generic audio input'));
  });
}

class _WebBackend implements LlamaBackend {
  @override
  bool get isReady => false;

  @override
  bool get supportsUrlLoading => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
