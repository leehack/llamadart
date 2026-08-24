@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

void main() {
  String read(String path) => File(path).readAsStringSync();

  group('high-risk review policy', () {
    test('PR template retains the exact-head blocking evidence fields', () {
      final template = read('.github/pull_request_template.md');

      for (final field in [
        '**Classification:**',
        '**Implementation task:**',
        '**Independent blocking QA task:**',
        '**Exact head / current base:**',
        '**Production-branch deletion, bypass, or miswire proof:**',
        '**Affected-family real-model/artifact evidence:**',
        '**Explicit unavailable-family or other N/A evidence:**',
        '**Known PR-caused P1 regressions:**',
        '**Unresolved review threads:**',
      ]) {
        expect(template, contains(field), reason: 'missing $field');
      }
    });

    test('agent and matrix guidance preserve zero-regression boundaries', () {
      final agentGuidance = read('AGENTS.md');
      final matrix = read('doc/testing_matrix.md');

      expect(agentGuidance, contains('zero known PR-caused P1 regressions'));
      expect(agentGuidance, contains('zero unresolved review threads'));
      expect(agentGuidance, contains('pipeline-only evidence'));
      expect(matrix, contains('branch is deleted, bypassed, or miswired'));
      expect(matrix, contains('A known PR-caused P1 or any unresolved'));
      expect(matrix, contains('--name-only --no-renames'));
      expect(matrix, contains('compiled production-path coverage'));
    });

    test('classifier help preserves rename and deletion visibility', () {
      final classifier = read('tool/testing/classify_high_risk_changes.dart');

      expect(
        classifier,
        contains('git diff --name-only --no-renames <base>...HEAD'),
      );
      expect(classifier, isNot(contains('git diff --name-only <base>...HEAD')));
    });

    test('CODEOWNERS protects policy and landed execution evidence', () {
      final codeowners = read('.github/CODEOWNERS');

      for (final path in [
        'AGENTS.md',
        'doc/testing_matrix.md',
        'tool/testing/test_matrix.dart',
        'tool/testing/classify_high_risk_changes.dart',
        'tool/testing/run_template_parity_suites.sh',
        'tool/testing/run_llama_cpp_chat_tests.sh',
        'tool/testing/prepare_llama_cpp_source.sh',
        'tool/testing/llama_cpp_templates.ref',
        'tool/gen_litert_lm_templates.dart',
        'tool/litert_lm_templates/ @leehack',
        'test/integration/core/grammar/'
            'generated_tool_schema_grammar_test.dart',
        'test/e2e/template/'
            'specialized_tool_grammar_validation_e2e_test.dart',
        'test/unit/tooling/high_risk_review_policy_test.dart',
      ]) {
        final rule = path.endsWith(' @leehack') ? path : '$path @leehack';
        expect(codeowners, contains(rule), reason: path);
      }
    });
  });
}
