#!/usr/bin/env dart

import 'dart:convert';
import 'dart:io';

/// Regression-sensitive production and governance surfaces.
enum HighRiskSurface {
  structuredOutput,
  backendRuntime,
  artifactConsumer,
  releaseAutomation,
  regressionPolicy,
}

/// Result of classifying changed repository paths.
class HighRiskAssessment {
  const HighRiskAssessment({
    required this.changedFiles,
    required this.surfaces,
  });

  /// Normalized, non-empty paths inspected by the classifier.
  final List<String> changedFiles;

  /// High-risk surfaces reached by the changed paths.
  final Set<HighRiskSurface> surfaces;

  /// Whether the change requires the high-risk pre-merge review.
  bool get isHighRisk => surfaces.isNotEmpty;
}

/// Classifies changed repository paths without reading or executing PR code.
HighRiskAssessment assessHighRiskFiles(Iterable<String> files) {
  final changedFiles = files
      .map((path) => path.trim())
      .where((path) => path.isNotEmpty)
      .toList(growable: false);
  final surfaces = <HighRiskSurface>{};

  for (final path in changedFiles) {
    if (_isStructuredOutput(path)) {
      surfaces.add(HighRiskSurface.structuredOutput);
    }
    if (_isBackendRuntime(path)) {
      surfaces.add(HighRiskSurface.backendRuntime);
    }
    if (_isArtifactConsumer(path)) {
      surfaces.add(HighRiskSurface.artifactConsumer);
    }
    if (_isReleaseAutomation(path)) {
      surfaces.add(HighRiskSurface.releaseAutomation);
    }
    if (_isRegressionPolicy(path)) {
      surfaces.add(HighRiskSurface.regressionPolicy);
    }
  }

  return HighRiskAssessment(changedFiles: changedFiles, surfaces: surfaces);
}

bool _isStructuredOutput(String path) {
  return path == 'lib/llamadart.dart' ||
      path.startsWith('lib/src/core/template/') ||
      path.startsWith('lib/src/core/grammar/') ||
      path.startsWith('lib/src/core/models/tools/') ||
      path.contains('/chat_template') ||
      path.contains('/structured_output') ||
      path.endsWith('/tool_choice.dart') ||
      path.endsWith('/completion_chunk.dart') ||
      _isStructuredOutputEvidence(path) ||
      (path.startsWith('tool/testing/') &&
          (path.contains('template') ||
              path.contains('grammar') ||
              path.contains('structured')));
}

bool _isStructuredOutputEvidence(String path) {
  return path ==
          'test/integration/core/grammar/'
              'generated_tool_schema_grammar_test.dart' ||
      path == 'tool/testing/run_llama_cpp_chat_tests.sh' ||
      path == 'tool/testing/prepare_llama_cpp_source.sh' ||
      path == 'tool/testing/llama_cpp_templates.ref' ||
      path == 'test/e2e/template/llama_cpp_chat_tests_e2e_test.dart' ||
      path.startsWith('test/integration/core/template/') ||
      path.startsWith('test/fixtures/templates/') ||
      path.startsWith('test/unit/core/template/');
}

bool _isBackendRuntime(String path) {
  return path == 'lib/llamadart.dart' ||
      path.startsWith('lib/src/backends/') ||
      path.startsWith('lib/src/core/engine/') ||
      path.startsWith('lib/src/core/models/') ||
      path.startsWith('lib/src/core/speech/') ||
      path.startsWith('lib/src/platform/') ||
      path == 'lib/src/core/cache_policy.dart' ||
      path.contains('/capabilit');
}

bool _isArtifactConsumer(String path) {
  return path == 'pubspec.yaml' ||
      path == 'pubspec.lock' ||
      path.startsWith('hook/') ||
      path.startsWith('lib/src/hook/') ||
      path.startsWith('tool/native/') ||
      path == 'tool/testing/check_webgpu_bridge_tag.dart' ||
      path == 'scripts/check_native_link_deps.sh' ||
      path == 'scripts/fetch_webgpu_bridge_assets.sh' ||
      path == 'scripts/build_chat_app_web.sh' ||
      path == 'scripts/validate_chat_app_web_build.sh' ||
      path == 'scripts/verify_chat_app_web_deployment.sh' ||
      path == 'example/chat_app/web/index.html' ||
      path.startsWith('packages/llamadart_llama_cpp_flutter/') ||
      path.startsWith('packages/llamadart_litert_lm_flutter/');
}

bool _isReleaseAutomation(String path) {
  if (path.startsWith('tool/release/') ||
      path.startsWith('scripts/release/') ||
      path == 'tool/testing/verify_release_docs_versions.dart') {
    return true;
  }
  if (!path.startsWith('.github/workflows/')) return false;
  final name = path.split('/').last;
  return name.contains('publish') ||
      name.contains('release') ||
      name.contains('deploy') ||
      name.contains('sync') ||
      name == 'docs_version_cut.yml';
}

bool _isRegressionPolicy(String path) {
  return path == 'AGENTS.md' ||
      path == '.github/CODEOWNERS' ||
      path == '.github/pull_request_template.md' ||
      path.startsWith('.github/workflows/') ||
      path == 'doc/testing_matrix.md' ||
      path == 'tool/testing/test_matrix.dart' ||
      path == 'tool/testing/classify_high_risk_changes.dart' ||
      path == 'test/unit/tooling/test_matrix_test.dart' ||
      path == 'test/unit/tooling/classify_high_risk_changes_test.dart';
}

/// Formats the contributor-facing classification result.
String formatHighRiskAssessment(HighRiskAssessment assessment) {
  if (!assessment.isHighRisk) {
    return 'Classification: standard\n';
  }
  final surfaces = assessment.surfaces.map((surface) => surface.name).toList()
    ..sort();
  return 'Classification: high-risk\n'
      'Surfaces: ${surfaces.join(', ')}\n'
      'Required matrix: '
      'dart run tool/testing/test_matrix.dart --tier high-risk\n';
}

String _usage() => '''Usage:
  git diff --name-only <base>...HEAD | \\
    dart run tool/testing/classify_high_risk_changes.dart

The command reads one changed repository path per line from standard input.
''';

Future<List<String>> _readPaths() async {
  return stdin
      .transform(const SystemEncoding().decoder)
      .transform(const LineSplitter())
      .toList();
}

Future<void> main(List<String> args) async {
  if (args.length == 1 && (args.single == '--help' || args.single == '-h')) {
    stdout.write(_usage());
    return;
  }
  if (args.isNotEmpty) {
    stderr.write(_usage());
    exitCode = 64;
    return;
  }

  final paths = await _readPaths();
  if (paths.isEmpty) {
    stderr.write('No changed paths were provided.\n${_usage()}');
    exitCode = 64;
    return;
  }
  stdout.write(formatHighRiskAssessment(assessHighRiskFiles(paths)));
}
