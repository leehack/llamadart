@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

import '../../support/dart_script_snapshot.dart';

void main() {
  test(
    'fixture selector and artifact gate run before loading a model',
    () async {
      final smoke = await compileDartScript(
        'tool/litert_lm_chat_features_smoke.dart',
      );
      final temp = await Directory.systemTemp.createTemp('qwen-smoke-gate-');
      addTearDown(() => temp.delete(recursive: true));
      final model = await File(
        '${temp.path}/other.litertlm',
      ).writeAsString('other');
      for (final fixture in ['unknown', 'qwen3-0.6b']) {
        final result = await Process.run(
          Platform.resolvedExecutable,
          ['--disable-dart-dev', smoke, model.path, 'cpu'],
          environment: {
            'LITERT_LM_TOKENIZER_FIXTURE': fixture,
            'LITERT_LM_AUDIO_PATH': '',
            'LITERT_LM_IMAGE_PATH': '',
          },
        );
        expect(result.exitCode, isNot(0));
        expect(
          result.stderr,
          contains(
            fixture == 'unknown'
                ? 'Unknown tokenizer fixture'
                : 'requires a known Qwen3-0.6B artifact',
          ),
        );
      }
    },
  );

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
