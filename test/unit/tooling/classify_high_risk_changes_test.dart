@TestOn('vm')
library;

import 'dart:convert';

import 'package:test/test.dart';

import '../../../tool/testing/classify_high_risk_changes.dart';

Future<HighRiskCliResult> runClassifier(List<int> input) =>
    classifyHighRiskInput(Stream.value(input));

void main() {
  group('assessHighRiskFiles', () {
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

    test('classifies release and regression-policy changes', () {
      final assessment = assessHighRiskFiles([
        '.github/workflows/release_on_prep_merge.yml',
        '.github/pull_request_template.md',
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
