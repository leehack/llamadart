@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

import '../../support/dart_script_snapshot.dart';

void main() {
  test('prints usage and exits 64 without a model path', () async {
    final smoke = await compileDartScript(
      'tool/litert_lm_chat_features_smoke.dart',
    );
    final result = await Process.run(Platform.resolvedExecutable, <String>[
      '--disable-dart-dev',
      smoke,
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
