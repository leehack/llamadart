@Tags(['local-only'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

// A program that ends with a model still loaded exits normally; on macOS Metal
// it used to abort in ggml's device teardown (#613). Downloads nothing: set
// LLAMADART_EXIT_GGUF to a small GGUF and LLAMADART_SDXS_MODEL to SDXS.
void main() {
  final cases = [
    ('llama', 'a llama.cpp model', 'LLAMADART_EXIT_GGUF'),
    ('image', 'an image model', 'LLAMADART_SDXS_MODEL'),
  ];

  for (final (runtime, label, variable) in cases) {
    final model = Platform.environment[variable];
    for (final (ending, exitCode) in [('return', 0), ('throw', 255)]) {
      test('a program whose main ${ending}s with $label loaded exits with '
          '$exitCode', () async {
        final process = await Process.start(Platform.resolvedExecutable, [
          'run',
          'test/fixtures/end_with_model_loaded.dart',
          runtime,
          ending,
          model!,
        ]);
        final stdout = process.stdout.transform(utf8.decoder).join();
        final stderr = process.stderr.transform(utf8.decoder).join();
        final code = await process.exitCode.timeout(
          const Duration(minutes: 3),
          onTimeout: () {
            process.kill(ProcessSignal.sigkill);
            fail('The program did not exit.');
          },
        );

        expect(await stdout, contains('loaded'));
        expect(await stderr, isNot(contains('GGML_ASSERT')));
        expect(code, exitCode);
      }, skip: model == null ? 'Set $variable.' : false);
    }
  }
}
