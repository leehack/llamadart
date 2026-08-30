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
        'CONTRIBUTING.md',
        'doc/testing_matrix.md',
        'doc/pr_branch_writer_inventory.md',
        'doc/high_risk_pre_merge_readiness.md',
        'tool/testing/test_matrix.dart',
        'tool/testing/classify_high_risk_changes.dart',
        'tool/testing/high_risk_readiness.dart',
        'tool/testing/high_risk_readiness_evidence.schema.json',
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
        'test/unit/tooling/high_risk_readiness_test.dart',
        'tool/git/safe_pr_head_update.dart',
        'tool/git/pr_head_update_evidence.schema.json',
        'test/unit/tooling/safe_pr_head_update_test.dart',
      ]) {
        final rule = path.endsWith(' @leehack') ? path : '$path @leehack';
        expect(codeowners, contains(rule), reason: path);
      }
    });

    test('guidance documents machine-verifiable evaluator and runbook', () {
      final agentGuidance = read('AGENTS.md');
      final contributing = read('CONTRIBUTING.md');
      final matrix = read('doc/testing_matrix.md');

      expect(agentGuidance, contains('high_risk_readiness.dart'));
      expect(
        agentGuidance,
        contains('high_risk_readiness_evidence.schema.json'),
      );
      expect(agentGuidance, contains('doc/high_risk_pre_merge_readiness.md'));
      expect(contributing, contains('high_risk_readiness.dart'));
      expect(contributing, contains('doc/high_risk_pre_merge_readiness.md'));
      expect(matrix, contains('high_risk_readiness.dart'));
      expect(matrix, contains('doc/high_risk_pre_merge_readiness.md'));
    });

    test(
      'local evaluator and workflow preserve the external trust boundary',
      () {
        final evaluator = read('tool/testing/high_risk_readiness.dart');
        final workflow = read('.github/workflows/high_risk_readiness.yml');
        final runbook = read('doc/high_risk_pre_merge_readiness.md');

        expect(evaluator, contains('unverifiedPrerequisites'));
        expect(evaluator, contains('standardRiskDiagnostic'));
        expect(
          evaluator,
          contains("'independent_auditor_authenticated': false"),
        );
        expect(evaluator, isNot(contains('LLAMADART_READINESS_APP_ID')));
        expect(evaluator, isNot(contains('LLAMADART_READINESS_PRIVATE_KEY')));
        expect(evaluator, isNot(contains('Platform.environment')));
        expect(workflow, contains('pull_request_target:'));
        expect(workflow, contains(r'ref: ${{ github.workflow_sha }}'));
        expect(workflow, isNot(contains(r'ref: ${{ github.sha }}')));
        expect(workflow, isNot(contains('workflow_dispatch:')));
        expect(
          workflow,
          isNot(
            contains(r'ref: ${{ github.event.repository.default_branch }}'),
          ),
        );
        expect(workflow, contains('persist-credentials: false'));
        expect(workflow, contains('Read-only diagnostic'));
        expect(workflow, contains('observed_head'));
        expect(workflow, contains('current_head'));
        expect(workflow, contains('observed_base'));
        expect(workflow, contains('current_base'));
        expect(workflow, contains('observed_changed_files'));
        expect(workflow, contains('current_changed_files'));
        expect(workflow, contains('--paginate --slurp'));
        expect(workflow, contains(r'($files | length) == $expected'));
        expect(workflow, contains('def safe_path:'));
        expect(workflow, contains(r'test("[\u0000-\u001F\u007F]")'));
        expect(workflow, contains('exit 1'));
        expect(workflow, isNot(contains('|| true')));
        expect(workflow, isNot(contains('continue-on-error')));
        expect(workflow, isNot(contains('PRIVATE_KEY')));
        expect(runbook, contains('issue #419 is not operationally complete'));
        expect(runbook, contains('must not be selected as a required'));
      },
    );

    test(
      'diagnostic workflow warns on high risk without failing while publisher fails closed',
      () {
        final workflow = read('.github/workflows/high_risk_readiness.yml');
        final publisherCli = read(
          'tool/governance/high_risk_readiness_publish.dart',
        );
        final publishTemplate = read(
          'tool/governance/deploy/high_risk_readiness_publish.yml.template',
        );

        final highRiskBranchIndex = workflow.indexOf(
          "steps.classify.outputs.is_high_risk == 'true'",
        );
        expect(highRiskBranchIndex, isNonNegative);
        final highRiskSection = workflow.substring(highRiskBranchIndex);

        expect(highRiskSection, contains(r'GITHUB_STEP_SUMMARY'));
        expect(highRiskSection, contains('::warning::'));
        expect(highRiskSection, isNot(contains('::error::')));
        expect(highRiskSection, isNot(contains('exit 1')));
        expect(highRiskSection, contains('High-risk paths were detected'));
        expect(
          highRiskSection,
          contains(
            'The protected GitHub App evidence publisher is not installed',
          ),
        );
        expect(
          highRiskSection,
          contains(
            'informational diagnostic only and must not be configured as a required readiness check',
          ),
        );
        expect(
          highRiskSection,
          contains(
            'Actual operational readiness remains unavailable until the separately activated authenticated publisher and check exist',
          ),
        );

        expect(workflow, contains('exit 64'));
        expect(workflow, contains('exit 65'));
        expect(workflow, contains('exit 1'));
        expect(workflow, isNot(contains('continue-on-error')));

        expect(publisherCli, contains('unboundTransportMessage'));
        expect(
          publisherCli,
          contains(
            'Refusing to publish: no authenticated GitHub transport is bound',
          ),
        );
        expect(publisherCli, contains("args.contains('--publish')"));
        expect(publisherCli, contains('exitCode = 69;'));

        expect(publishTemplate, contains("github.ref != 'refs/heads/main'"));
        expect(publishTemplate, contains('github.workflow_sha != github.sha'));
        expect(
          publishTemplate,
          contains(
            '::error::Attestation requires a top-level workflow resolved at the exact main run head.',
          ),
        );
        expect(publishTemplate, contains('exit 1'));
      },
    );

    test('schema makes evaluator decisions computed and enum-complete', () {
      final schema = read(
        'tool/testing/high_risk_readiness_evidence.schema.json',
      );

      expect(schema, contains(r'"additionalProperties": false'));
      expect(schema, contains(r'"evaluation"'));
      expect(schema, contains(r'"unverifiedPrerequisites"'));
      expect(schema, contains(r'"standardRiskDiagnostic"'));
      expect(schema, contains(r'"externalPrerequisitesUnavailable"'));
      expect(schema, isNot(contains(r'"decision": "ready"')));
    });
  });
}
