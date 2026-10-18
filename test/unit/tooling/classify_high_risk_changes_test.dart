@TestOn('vm')
library;

import 'dart:convert';

import 'package:test/test.dart';

import '../../../tool/testing/classify_high_risk_changes.dart';

Future<HighRiskCliResult> runClassifier(List<int> input) =>
    classifyHighRiskInput(Stream.value(input));

void main() {
  test('impact hints separate known boundaries and union mixed effects', () {
    const render = 'lib/src/core/template/template_render_context.dart';
    const parser = 'lib/src/core/template/peg_chat_parser.dart';
    expect(
      structuredImpactHints(['lib/src/core/template/tool_schema_utils.dart']),
      StructuredImpact.values.toSet(),
    );
    const grammar = 'lib/src/core/grammar/gbnf_grammar_generator.dart';
    expect(structuredImpactHints([render]), {
      StructuredImpact.inputRenderingHistory,
    });
    expect(structuredImpactHints([parser]), {
      StructuredImpact.outputParsingStreaming,
    });
    expect(structuredImpactHints([grammar]), {StructuredImpact.grammarSchema});
    expect(
      structuredImpactHints([render, parser, grammar]),
      StructuredImpact.values.toSet(),
    );
    expect(
      structuredImpactHints(['lib/src/core/template/new_helper.dart']),
      StructuredImpact.values.toSet(),
    );
    expect(
      structuredImpactHints([
        'lib/src/core/template/handlers/qwen3_handler.dart',
      ]),
      StructuredImpact.values.toSet(),
    );
    expect(
      structuredImpactHints(['test/unit/core/template/handler_test.dart']),
      StructuredImpact.values.toSet(),
    );
    expect(
      assessHighRiskFiles([
        'tool/testing/high_risk_readiness_evidence.v1.schema.json',
      ]).surfaces,
      contains(HighRiskSurface.regressionPolicy),
    );
  });

  group('assessHighRiskFiles', () {
    test(
      'independent Genkit runtime, schema, archive and policy paths retain gates',
      () {
        const prefix = 'packages/genkit_llamadart/';
        expect(
          assessHighRiskFiles([
            'tool/release/genkit_release_helpers.sh',
          ]).surfaces,
          contains(HighRiskSurface.releaseAutomation),
        );
        for (final path in [
          'lib/src/core/runtime/engine_registry.dart',
          'lib/src/api/runtime_owner.dart',
          'lib/src/api/model_preparation.dart',
        ]) {
          expect(
            assessHighRiskFiles(['$prefix$path']).surfaces,
            contains(HighRiskSurface.backendRuntime),
            reason: path,
          );
        }
        for (final path in [
          'lib/genkit_llamadart.dart',
          'lib/experimental.dart',
          'lib/src/core/streaming/completion_accumulator.dart',
          'lib/src/integration/genkit/converters/schema_to_tool_params.dart',
          'lib/src/integration/genkit/converters/genkit_to_llama.dart',
          'lib/src/integration/genkit/actions/model_action.dart',
        ]) {
          expect(
            assessHighRiskFiles(['$prefix$path']).surfaces,
            containsAll({
              HighRiskSurface.structuredOutput,
              HighRiskSurface.backendRuntime,
            }),
            reason: path,
          );
        }
        for (final path in [
          'pubspec.yaml',
          '.pubignore',
          'pubspec_overrides.yaml',
        ]) {
          expect(
            assessHighRiskFiles(['$prefix$path']).surfaces,
            contains(HighRiskSurface.artifactConsumer),
            reason: path,
          );
        }
        expect(
          assessHighRiskFiles(['${prefix}CONTRIBUTING.md']).surfaces,
          contains(HighRiskSurface.regressionPolicy),
        );
        expect(
          assessHighRiskFiles(['$prefix.github/check_docs.py']).surfaces,
          contains(HighRiskSurface.regressionPolicy),
        );
        for (final path in [
          'test/integration/genkit/plugin/real_model_constrained_grammar_test.dart',
          'test/integration/genkit/plugin/real_model_rich_tool_schemas_test.dart',
          'test/integration/genkit/test_support/tool_schema_grammar_validation.dart',
        ]) {
          expect(
            assessHighRiskFiles(['$prefix$path']).surfaces,
            contains(HighRiskSurface.structuredOutput),
          );
        }
        expect(assessHighRiskFiles(['${prefix}README.md']).isHighRisk, isFalse);
        expect(
          assessHighRiskFiles(['${prefix}doc/usage.md']).isHighRisk,
          isFalse,
        );
      },
    );

    test('classifies structured-output production and parity changes', () {
      final assessment = assessHighRiskFiles([
        'lib/src/core/template/chat_template_handler.dart',
        'lib/src/core/grammar/gbnf_grammar_generator.dart',
        'tool/testing/run_template_parity_suites.sh',
      ]);

      expect(assessment.isHighRisk, isTrue);
      expect(assessment.surfaces, contains(HighRiskSurface.structuredOutput));
    });

    test('protects landed compiled grammar and upstream parity evidence', () {
      final assessment = assessHighRiskFiles([
        'test/integration/core/grammar/'
            'generated_tool_schema_grammar_test.dart',
        'tool/testing/run_llama_cpp_chat_tests.sh',
        'tool/testing/llama_cpp_templates.ref',
        'test/e2e/template/'
            'specialized_tool_grammar_validation_e2e_test.dart',
        'test/fixtures/templates/Kimi-K3.jinja',
      ]);

      expect(assessment.surfaces, contains(HighRiskSurface.structuredOutput));
    });

    test(
      'classifies LiteRT template generator inputs as structured output',
      () {
        final assessment = assessHighRiskFiles([
          'tool/gen_litert_lm_templates.dart',
          'tool/litert_lm_templates/gemma3.jinja',
        ]);

        expect(assessment.surfaces, contains(HighRiskSurface.structuredOutput));
      },
    );

    test('classifies every public entrypoint as an API surface', () {
      for (final entrypoint in [
        'lib/llamadart.dart',
        'lib/backend.dart',
        'lib/llama_cpp_bindings.dart',
      ]) {
        expect(
          assessHighRiskFiles([entrypoint]).surfaces,
          containsAll({
            HighRiskSurface.structuredOutput,
            HighRiskSurface.backendRuntime,
          }),
          reason: entrypoint,
        );
      }
    });

    test('classifies backend, capability, and artifact consumers', () {
      final assessment = assessHighRiskFiles([
        'lib/src/backends/webgpu/webgpu_backend.dart',
        'lib/src/core/models/backend_capabilities.dart',
        'lib/src/core/cache_policy.dart',
        'scripts/fetch_webgpu_bridge_assets.sh',
      ]);

      expect(
        assessment.surfaces,
        containsAll({
          HighRiskSurface.backendRuntime,
          HighRiskSurface.artifactConsumer,
        }),
      );
    });

    test('classifies runtime pin checks as artifact consumers', () {
      for (final path in [
        'tool/testing/check_webgpu_bridge_tag.dart',
        'tool/testing/check_native_release_digests.dart',
      ]) {
        expect(
          assessHighRiskFiles([path]).surfaces,
          contains(HighRiskSurface.artifactConsumer),
          reason: path,
        );
      }
    });

    test(
      'classifies every Flutter Apple companion as an artifact consumer',
      () {
        for (final companion in [
          'llamadart_llama_cpp_flutter',
          'llamadart_litert_lm_flutter',
          'llamadart_stable_diffusion_flutter',
        ]) {
          final assessment = assessHighRiskFiles([
            'packages/$companion/darwin/$companion/Package.swift',
          ]);

          expect(
            assessment.surfaces,
            contains(HighRiskSurface.artifactConsumer),
            reason: companion,
          );
        }
      },
    );

    test('classifies release and regression-policy changes', () {
      final assessment = assessHighRiskFiles([
        '.github/workflows/release_on_prep_merge.yml',
        '.github/pull_request_template.md',
        'CONTRIBUTING.md',
        'tool/git/safe_pr_head_update.dart',
        'tool/git/pr_head_update_evidence.schema.json',
        'test/unit/tooling/safe_pr_head_update_test.dart',
        'doc/pr_branch_writer_inventory.md',
        'doc/high_risk_pre_merge_readiness.md',
        'tool/testing/high_risk_readiness.dart',
        'tool/testing/release_metadata_readiness.dart',
        'tool/testing/high_risk_readiness_evidence.schema.json',
        'test/unit/tooling/high_risk_readiness_test.dart',
      ]);

      expect(
        assessment.surfaces,
        containsAll({
          HighRiskSurface.releaseAutomation,
          HighRiskSurface.regressionPolicy,
        }),
      );
    });

    test('keeps ordinary docs-only changes standard risk', () {
      final assessment = assessHighRiskFiles([
        'website/docs/guides/model-downloads.md',
      ]);

      expect(assessment.isHighRisk, isFalse);
      expect(
        formatHighRiskAssessment(assessment),
        'Classification: standard\n',
      );
    });

    test('release metadata validator alone remains regression-policy risk', () {
      expect(
        assessHighRiskFiles([
          'tool/testing/release_metadata_readiness.dart',
        ]).surfaces,
        {HighRiskSurface.regressionPolicy},
      );
    });

    test('normalizes blank input and prints deterministic surfaces', () {
      final assessment = assessHighRiskFiles([
        '',
        '  ',
        ' lib/src/backends/backend.dart ',
        '.github/workflows/ci.yml',
      ]);

      expect(
        formatHighRiskAssessment(assessment),
        'Classification: high-risk\n'
        'Surfaces: backendRuntime, regressionPolicy\n'
        'Required matrix: '
        'dart run tool/testing/test_matrix.dart --tier high-risk\n',
      );
    });
  });

  group('classifier CLI', () {
    test(
      'rejects whitespace-only input instead of reporting standard',
      () async {
        final result = await runClassifier(utf8.encode('  \n\t\n'));

        expect(result.exitCode, 64);
        expect(result.standardOutput, isEmpty);
        expect(
          result.standardError,
          contains('No changed paths were provided.'),
        );
        expect(
          result.standardError,
          isNot(contains('Classification: standard')),
        );
      },
    );

    test('rejects malformed UTF-8 without a traceback', () async {
      final result = await runClassifier([0xff, 0x0a]);

      expect(result.exitCode, 65);
      expect(result.standardOutput, isEmpty);
      expect(
        result.standardError,
        contains('Changed paths must be valid UTF-8.'),
      );
      expect(result.standardError, isNot(contains('FormatException')));
      expect(result.standardError, isNot(contains('Unhandled exception')));
    });
  });
}
