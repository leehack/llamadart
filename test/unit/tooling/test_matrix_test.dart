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

    test('includes targeted local model smoke rows', () {
      final ids = testMatrixRows.map((row) => row.id).toSet();

      expect(ids, contains('gguf-chat-features-smoke'));
      expect(ids, contains('litert-lm-chat-features-smoke'));
      expect(ids, contains('web-real-model-smoke'));
      expect(ids, contains('webgpu-multimodal-regression'));
      expect(ids, contains('gemma4-webgpu-mem64'));
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
