@TestOn('vm')
library;

import 'package:llamadart/src/backends/llama_cpp/llama_cpp_service.dart';
import 'package:llamadart/src/backends/llama_cpp/runtime_admission.dart';
import 'package:llamadart/src/core/exceptions.dart';
import 'package:llamadart/src/core/models/inference/model_params.dart';
import 'package:test/test.dart';

const _v1 = 'b1b770d90d94cad9e9ea5b993bdbc383a522fb28';
const _v090 = 'cd959bae99ff4bed22bef2604f45241c09bbb8c8';
const _v080 = '8642541b255bfb5dc39cd351a178be09013a55d6';

String _identity(String commit, {String suffix = ''}) =>
    'llamadart-native-build/1;llama.cpp=$commit;$suffix';

void main() {
  group('admitsRuntimeBuildIdentity', () {
    test('admits the exact llama.cpp v1.0.0 commit', () {
      expect(admitsRuntimeBuildIdentity(_identity(_v1)), isTrue);
      expect(
        admitsRuntimeBuildIdentity(_identity(_v1, suffix: 'wrapper=abc;')),
        isTrue,
      );
      expect(
        admitsRuntimeBuildIdentity(
          'llamadart-native-build/1;wrapper=abc;llama.cpp=$_v1;',
        ),
        isTrue,
      );
    });

    final refused = <String, String?>{
      'missing': null,
      'empty': '',
      'unknown': 'unknown',
      'another schema': 'llamadart-native-build/2;llama.cpp=$_v1;',
      'unknown commit': 'llamadart-native-build/1;llama.cpp=unknown;',
      'dirty': 'llamadart-native-build/1;llama.cpp=$_v1+dirty.123;',
      'duplicate key': _identity(_v1, suffix: 'llama.cpp=unknown;'),
      'duplicate key with the same commit': _identity(
        _v1,
        suffix: 'llama.cpp=$_v1;',
      ),
      'unterminated value': 'llamadart-native-build/1;llama.cpp=$_v1',
      'abbreviated commit': _identity(_v1.substring(0, 12)),
      'prefix of the commit': _identity('${_v1}0'),
      'no schema prefix': 'wrapper=abc;llama.cpp=$_v1;',
      'v0.9.0': _identity(_v090),
      'v0.8.0': _identity(_v080),
    };
    for (final entry in refused.entries) {
      test('refuses ${entry.key}', () {
        expect(admitsRuntimeBuildIdentity(entry.value), isFalse);
      });
    }
  });

  group('refusal message', () {
    test('names the capability, the reported identity and the release', () {
      final identity = _identity(_v090);
      final service = LlamaCppService(buildIdentity: () => identity);

      expect(
        () => service.loadModel('model.gguf', const ModelParams()),
        throwsA(
          isA<LlamaUnsupportedException>().having(
            (error) => error.message,
            'message',
            allOf(
              startsWith('Model loading needs a llamadart-native runtime'),
              contains(identity),
              contains('llama.cpp v1.0.0 ($_v1)'),
              contains('llamadart-native v1.0.0'),
            ),
          ),
        ),
      );
    });

    test('says so when the runtime reports no identity', () {
      final service = LlamaCppService(buildIdentity: () => null);

      expect(
        () => service.loadModel('model.gguf', const ModelParams()),
        throwsA(
          isA<LlamaUnsupportedException>().having(
            (error) => error.message,
            'message',
            contains('no build identity'),
          ),
        ),
      );
    });
  });
}
