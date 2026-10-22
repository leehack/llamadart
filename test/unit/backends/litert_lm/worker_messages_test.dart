@TestOn('vm')
library;

import 'package:llamadart/src/backends/litert_lm/worker_messages.dart';
import 'package:llamadart/llamadart.dart';
import 'package:test/test.dart';

void main() {
  group('LiteRT-LM worker messages', () {
    test('maps Dart errors into worker error responses', () {
      expect(
        LiteRtLmErrorResponse.from(UnsupportedError('nope')).kind,
        'unsupported',
      );
      expect(LiteRtLmErrorResponse.from(ArgumentError('bad')).kind, 'argument');
      expect(LiteRtLmErrorResponse.from(StateError('wrong')).kind, 'state');
      final unsupported = LiteRtLmErrorResponse.from(
        LlamaUnsupportedException('no remote images'),
      );
      expect(unsupported.kind, 'llamaUnsupported');
      expect(unsupported.message, 'no remote images');

      final cases = <(LlamaException, String)>[
        (LlamaArgumentException('bad value'), 'llamaArgument'),
        (LlamaModelException('bad model', 'detail'), 'llamaModel'),
        (LlamaContextException('no context'), 'llamaContext'),
        (LlamaInferenceException('decode failed'), 'llamaInference'),
        (LlamaStateException('busy'), 'llamaState'),
      ];
      for (final (error, kind) in cases) {
        final response = LiteRtLmErrorResponse.from(error);
        expect(response.kind, kind);
        expect(response.message, isNot(contains('LlamaException:')));
      }
      expect(
        LiteRtLmErrorResponse.from(
          LlamaModelException('bad model', 'detail'),
        ).message,
        'bad model (detail)',
      );

      final generic = LiteRtLmErrorResponse.from(Exception('native failed'));
      expect(generic.kind, 'exception');
      expect(generic.message, contains('native failed'));
    });
  });
}
