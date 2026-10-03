@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('prints usage and exits 64 without a model path', () async {
    final result = await Process.run(Platform.resolvedExecutable, <String>[
      '--disable-dart-dev',
      'tool/litert_lm_chat_features_smoke.dart',
      ' ',
    ]);

    expect(result.exitCode, 64, reason: '${result.stderr}');
    expect(
      result.stderr,
      contains(
        'Usage: dart run tool/litert_lm_chat_features_smoke.dart '
        '<model.litertlm>',
      ),
    );
  });
}
