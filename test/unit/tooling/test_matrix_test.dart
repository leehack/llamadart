@TestOn('vm')
library;

import 'package:test/test.dart';

import '../../../tool/testing/test_matrix.dart';

void main() {
  group('test_matrix', () {
    test('has unique row ids', () {
      final ids = testMatrixRows.map((row) => row.id).toList();

      expect(ids.toSet(), hasLength(ids.length));
    });

    test('has stable essential rows for baseline PR validation', () {
      final ids = testMatrixRows.map((row) => row.id).toSet();

      expect(ids, contains('static-format-analyze'));
      expect(ids, contains('root-vm'));
      expect(ids, contains('root-chrome'));
      expect(ids, contains('coverage-lib'));
    });

    test(
      'keeps workspace preparation ahead of unscoped format and analyze',
      () {
        final row = testMatrixRows.singleWhere(
          (row) => row.id == 'static-format-analyze',
        );

        expect(
          row.command,
          startsWith(
            'dart run tool/prepare_workspace.dart && '
            'dart format --output=none --set-exit-if-changed . && '
            'dart analyze &&',
          ),
        );
      },
    );

    test('includes targeted local model smoke rows', () {
      final ids = testMatrixRows.map((row) => row.id).toSet();

      expect(ids, contains('gguf-chat-features-smoke'));
      expect(ids, contains('litert-lm-chat-features-smoke'));
      expect(ids, contains('native-inference-benchmark'));
      expect(ids, contains('llama-cpp-speculative-benchmark'));
      expect(ids, contains('web-mock-chat-smoke'));
      expect(ids, contains('web-real-model-smoke'));
      expect(ids, contains('webgpu-multimodal-regression'));
      expect(ids, contains('gemma4-webgpu-mem64'));
      expect(ids, contains('physical-ios-speech-e2e'));
    });

    test('includes targeted physical iOS speech E2E row', () {
      final row = testMatrixRows.singleWhere(
        (row) => row.id == 'physical-ios-speech-e2e',
      );
      expect(row.tier, equals('targeted'));
      expect(row.mode, contains('device'));
      expect(row.covers, contains('physical iOS'));
      expect(row.covers, contains('immutable local artifacts'));
      expect(row.covers, contains('no audio playback'));
      expect(row.covers, contains('llama.cpp Qwen3-ASR'));
      expect(row.covers, contains('LiteRT-LM streaming ASR'));
      expect(row.covers, contains('llama.cpp Qwen3-TTS'));
      expect(row.covers, contains('LiteRT-LM TTS'));
      expect(
        row.command,
        contains('integration_test/physical_ios_speech_e2e_test.dart'),
      );
    });

    test('physical iOS speech row runs the local-only tagged target', () {
      final row = testMatrixRows.singleWhere(
        (row) => row.id == 'physical-ios-speech-e2e',
      );

      // The chat-app dart_test.yaml marks local-only as `skip`, so omitting
      // these flags silently passes the harness without running it.
      expect(row.command, contains('--run-skipped'));
      expect(row.command, contains('-t local-only'));
      expect(row.command, contains('--no-pub'));
      expect(row.command, contains('--no-uninstall'));
      expect(row.command, contains('cd example/chat_app'));
      expect(row.command, contains('flutter test'));
    });

    test('physical iOS speech row targets a physical device only', () {
      final row = testMatrixRows.singleWhere(
        (row) => row.id == 'physical-ios-speech-e2e',
      );

      expect(row.command, contains(r'-d "$PHYSICAL_IOS_DEVICE_ID"'));
      expect(row.command, isNot(contains('<physical-ios-device-id>')));
      expect(row.command, isNot(matches(RegExp(r'(^|\s)<[^>]+>'))));
      expect(row.command.toLowerCase(), isNot(contains('simulator')));
      expect(row.command.toLowerCase(), isNot(contains('http://')));
      expect(row.command.toLowerCase(), isNot(contains('https://')));
      expect(row.command.toLowerCase(), isNot(contains('playback')));
      expect(row.command.toLowerCase(), isNot(contains('--run-skipped-if')));
      expect(row.covers.toLowerCase(), isNot(contains('simulator')));
    });

    test('physical iOS speech row passes every required dart define', () {
      final row = testMatrixRows.singleWhere(
        (row) => row.id == 'physical-ios-speech-e2e',
      );

      const requiredDefines = <String>[
        'IOS_SPEECH_QWEN3_ASR_MODEL_PATH',
        'IOS_SPEECH_QWEN3_ASR_MODEL_SHA256',
        'IOS_SPEECH_QWEN3_ASR_MMPROJ_PATH',
        'IOS_SPEECH_QWEN3_ASR_MMPROJ_SHA256',
        'IOS_SPEECH_ASR_AUDIO_PATH',
        'IOS_SPEECH_ASR_AUDIO_SHA256',
        'IOS_SPEECH_ASR_EXPECTED_TRANSCRIPT',
        'IOS_SPEECH_MIC_DURATION_SECONDS',
        'IOS_SPEECH_MIC_EXPECTED_TRANSCRIPT',
        'IOS_SPEECH_LITERT_ASR_MODEL_PATH',
        'IOS_SPEECH_LITERT_ASR_MODEL_SHA256',
        'IOS_SPEECH_LITERT_ASR_TOKENIZER_PATH',
        'IOS_SPEECH_LITERT_ASR_TOKENIZER_SHA256',
        'IOS_SPEECH_LITERT_ASR_PRESET',
        'IOS_SPEECH_LITERT_ASR_AUDIO_PATH',
        'IOS_SPEECH_LITERT_ASR_AUDIO_SHA256',
        'IOS_SPEECH_LITERT_ASR_EXPECTED_TRANSCRIPT',
        'IOS_SPEECH_QWEN3_TTS_MODEL_PATH',
        'IOS_SPEECH_QWEN3_TTS_MODEL_SHA256',
        'IOS_SPEECH_QWEN3_TTS_MMPROJ_PATH',
        'IOS_SPEECH_QWEN3_TTS_MMPROJ_SHA256',
        'IOS_SPEECH_TTS_TEXT',
        'IOS_SPEECH_TTS_OUTPUT_PATH',
        'IOS_SPEECH_TTS_EXPECTED_TRANSCRIPT',
        'IOS_SPEECH_LITERT_LM_MODEL_PATH',
        'IOS_SPEECH_LITERT_LM_MODEL_SHA256',
      ];

      for (final define in requiredDefines) {
        expect(
          row.command,
          contains('--dart-define=$define='),
          reason: 'Command must pass $define.',
        );
        expect(
          row.command,
          contains('--dart-define=$define="\$$define"'),
          reason: 'Command must quote the operator-provided value for $define.',
        );
      }
      expect(
        '--dart-define='.allMatches(row.command).length,
        equals(requiredDefines.length),
        reason: 'Command must not pass unknown or duplicated defines.',
      );
    });

    test('includes explicit platform coverage rows', () {
      final ids = testMatrixRows.map((row) => row.id).toSet();

      expect(ids, contains('linux-x64-ci-runtime'));
      expect(ids, contains('linux-arm64-runtime-smoke'));
      expect(ids, contains('windows-x64-ci-runtime'));
      expect(ids, contains('windows-arm64-hook-coverage'));
      expect(ids, contains('macos-arm64-runtime-smoke'));
      expect(ids, contains('macos-x64-runtime-smoke'));
      expect(ids, contains('ios-arm64-device-smoke'));
      expect(ids, contains('ios-simulator-smoke'));
      expect(ids, contains('android-arm64-device-smoke'));
      expect(ids, contains('android-x64-emulator-smoke'));
      expect(ids, contains('web-chrome-runtime-smoke'));
    });

    test('includes release gate for companion pub packages', () {
      final releaseTable = formatTestMatrix(tier: 'release');

      expect(releaseTable, contains('release-companion-pub-gate'));
      expect(releaseTable, contains('publish_companion_pubdev.yml'));
      expect(releaseTable, contains('pub.dev/api/packages'));
    });

    test('includes high-risk adversarial review rows', () {
      final highRiskTable = formatTestMatrix(tier: 'high-risk');

      expect(highRiskTable, contains('high-risk-exact-head-independent-qa'));
      expect(highRiskTable, contains('structured-output-adversarial'));
      expect(highRiskTable, contains('production-branch deletion'));
      expect(highRiskTable, contains('compiled grammar acceptance/rejection'));
      expect(highRiskTable, contains('auto/required/none tool choice'));
      expect(highRiskTable, contains('pipeline-only'));
      expect(highRiskTable, isNot(contains('root-vm')));
    });

    test('formats PR evidence template with matrix ids', () {
      final template = formatPrEvidenceTemplate(tier: 'essential');

      expect(template, contains('| Matrix row |'));
      expect(template, contains('`root-vm`'));
      expect(template, contains('PASS / FAIL / N/A'));
      expect(template, isNot(contains('`android-arm64-device-smoke`')));
    });

    test('formats targeted matrix table with commands', () {
      final table = formatTestMatrix(tier: 'targeted');

      expect(table, contains('| ID | Tier | Mode |'));
      expect(table, contains('gguf-chat-features-smoke'));
      expect(table, contains('llama-cpp-chat-template-smoke'));
      expect(
        table,
        contains(
          'run_local_e2e.dart --scenario llama-cpp-speculative-benchmark',
        ),
      );
      expect(
        table,
        contains(
          '--draft-model-path <draft.gguf> --backend cpu '
          '--speculative-cases baseline,draft-dspark,ngram-simple,ngram-map-k,'
          'ngram-map-k4v,ngram-mod,ngram-cache,mixed-ngram',
        ),
      );
      expect(
        table,
        contains(
          '--draft-token-max 1,2 --ngram-size-m 8,16 --benchmark-warmups 1',
        ),
      );
      expect(
        table,
        contains(
          '--ngram-cache-build-static-path /tmp/llamadart-ngram-cache.bin',
        ),
      );
      expect(
        table,
        contains('External draft-model strategies require --draft-model-path'),
      );
      expect(table, contains('bundled MTP omits it'));
      expect(table, contains('ngram-cache can use'));
      expect(table, isNot(contains('LLAMADART_MTP_BENCHMARK')));
      expect(table, isNot(contains('llama_cpp_mtp_benchmark.dart')));
      expect(table, contains('run_local_e2e.dart'));
      expect(table, isNot(contains('static-format-analyze')));
    });

    test('formats platform matrix table separately from targeted rows', () {
      final table = formatTestMatrix(tier: 'platform');

      expect(table, contains('linux-x64-ci-runtime'));
      expect(table, contains('ios-arm64-device-smoke'));
      expect(table, contains('web-chrome-runtime-smoke'));
      expect(table, isNot(contains('gguf-chat-features-smoke')));
    });
  });
}
