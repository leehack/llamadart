#!/usr/bin/env dart

import 'dart:convert';
import 'dart:io';

/// Regression-sensitive production surfaces that require extra pre-merge proof.
enum HighRiskSurface {
  structuredOutput,
  backendRuntime,
  artifactConsumer,
  releaseAutomation,
  regressionPolicy,
}

/// Result of classifying the files changed by a pull request.
class HighRiskAssessment {
  const HighRiskAssessment({
    required this.changedFiles,
    required this.surfaces,
  });

  final List<String> changedFiles;
  final Set<HighRiskSurface> surfaces;

  bool get isHighRisk => surfaces.isNotEmpty;

  bool get isStructuredOutput =>
      surfaces.contains(HighRiskSurface.structuredOutput);
}

/// Inputs that bind PR-body evidence to the current GitHub state.
class HighRiskPrState {
  const HighRiskPrState({
    required this.headSha,
    required this.baseSha,
    required this.behind,
    required this.ahead,
    required this.unresolvedThreads,
  });

  final String headSha;
  final String baseSha;
  final int behind;
  final int ahead;
  final int unresolvedThreads;
}

/// Validation result for a high-risk PR contract.
class HighRiskContractResult {
  const HighRiskContractResult({
    required this.assessment,
    required this.errors,
  });

  final HighRiskAssessment assessment;
  final List<String> errors;

  bool get isValid => errors.isEmpty;
}

/// Classifies only production and release-policy paths, not tests alone.
HighRiskAssessment assessHighRiskFiles(Iterable<String> files) {
  final normalized = files
      .map((file) => file.trim().replaceAll('\\', '/'))
      .where((file) => file.isNotEmpty)
      .toList(growable: false);
  final surfaces = <HighRiskSurface>{};

  for (final path in normalized) {
    if (path.startsWith('lib/src/core/template/') ||
        path.startsWith('lib/src/core/grammar/') ||
        path == 'lib/src/core/engine/chat_completion_stream_parser.dart' ||
        path == 'lib/src/core/engine/chat_template_renderer.dart' ||
        path.contains('/chat_template')) {
      surfaces.add(HighRiskSurface.structuredOutput);
    }
    if (path.startsWith('lib/src/backends/') ||
        path.startsWith('lib/src/core/engine/') ||
        path.startsWith('lib/src/core/speech/') ||
        path == 'lib/src/core/models/chat/content_part.dart') {
      surfaces.add(HighRiskSurface.backendRuntime);
    }
    if (path == 'hook/build.dart' ||
        path.startsWith('tool/native/') ||
        path == 'scripts/fetch_webgpu_bridge_assets.sh' ||
        path == 'scripts/build_chat_app_web.sh' ||
        path == 'scripts/validate_chat_app_web_build.sh' ||
        path == 'scripts/verify_chat_app_web_deployment.sh' ||
        path.startsWith('packages/llamadart_llama_cpp_flutter/') ||
        path.startsWith('packages/llamadart_litert_lm_flutter/')) {
      surfaces.add(HighRiskSurface.artifactConsumer);
    }
    if (_isReleaseWorkflow(path) ||
        path.startsWith('tool/release/') ||
        path.startsWith('scripts/release/')) {
      surfaces.add(HighRiskSurface.releaseAutomation);
    }
    if (path == '.github/pull_request_template.md' ||
        path == '.github/CODEOWNERS' ||
        path == '.github/workflows/high_risk_regression_gate.yml' ||
        path == 'AGENTS.md' ||
        path == 'doc/testing_matrix.md' ||
        path == 'tool/testing/test_matrix.dart' ||
        path == 'tool/testing/check_high_risk_pr_contract.dart') {
      surfaces.add(HighRiskSurface.regressionPolicy);
    }
  }

  return HighRiskAssessment(changedFiles: normalized, surfaces: surfaces);
}

bool _isReleaseWorkflow(String path) {
  if (!path.startsWith('.github/workflows/')) return false;
  final name = path.split('/').last;
  return name.contains('publish') ||
      name.contains('release') ||
      name.contains('deploy') ||
      name.contains('sync');
}

/// Validates the machine-readable evidence block in the PR template.
HighRiskContractResult validateHighRiskContract({
  required Iterable<String> changedFiles,
  required String body,
  required HighRiskPrState state,
}) {
  final assessment = assessHighRiskFiles(changedFiles);
  final errors = <String>[];
  final fields = _parseEvidenceFields(body);

  if (!assessment.isHighRisk) {
    final classification = fields['High-risk classification'];
    if (classification != null && classification != 'standard') {
      errors.add(
        'Non-high-risk changes must use "standard" when the optional '
        'classification field is filled.',
      );
    }
    return HighRiskContractResult(assessment: assessment, errors: errors);
  }

  _expectExact(fields, errors, 'High-risk classification', 'high-risk');
  _expectExact(fields, errors, 'Exact head SHA', state.headSha);
  _expectExact(fields, errors, 'Current base SHA', state.baseSha);
  _expectExact(
    fields,
    errors,
    'Current base distance',
    '${state.behind} behind / ${state.ahead} ahead',
  );
  _expectExact(fields, errors, 'Independent QA verdict', 'PASS');
  _expectExact(fields, errors, 'Known PR-caused P1 regressions', '0');
  _expectExact(
    fields,
    errors,
    'Unresolved review threads',
    state.unresolvedThreads.toString(),
  );
  if (state.unresolvedThreads != 0) {
    errors.add('High-risk PRs cannot pass with unresolved review threads.');
  }

  final implementationTask = _requireDetail(
    fields,
    errors,
    'Implementation task',
  );
  final qaTask = _requireDetail(fields, errors, 'Independent blocking QA task');
  if (implementationTask != null &&
      qaTask != null &&
      implementationTask.toLowerCase() == qaTask.toLowerCase()) {
    errors.add(
      'Independent blocking QA task must differ from the implementation task.',
    );
  }

  _requirePassEvidence(
    fields,
    errors,
    'Production call sites inspected',
    const ['production'],
  );
  _requirePassEvidence(
    fields,
    errors,
    'Positive production-path evidence',
    const ['production', 'pass'],
  );
  _requirePassEvidence(
    fields,
    errors,
    'Negative/adversarial production-path evidence',
    const ['production', 'adversarial'],
  );
  _requirePassEvidence(
    fields,
    errors,
    'Deletion/bypass/miswire sensitivity',
    const ['delete', 'bypass', 'miswire'],
  );
  _requireRuntimeEvidence(fields, errors);

  final hasDurableTests = assessment.changedFiles.any(
    (path) => path.startsWith('test/') && path.endsWith('_test.dart'),
  );
  if (!hasDurableTests) {
    errors.add(
      'High-risk production or policy changes require a durable *_test.dart '
      'change on the same PR.',
    );
  }

  if (assessment.isStructuredOutput) {
    final hasTemplateTests = assessment.changedFiles.any(
      (path) =>
          (path.startsWith('test/unit/core/template/') ||
              path.startsWith('test/integration/core/template/')) &&
          path.endsWith('_test.dart'),
    );
    if (!hasTemplateTests) {
      errors.add(
        'Structured-output changes require durable production-path template '
        'tests under test/unit/core/template or test/integration/core/template.',
      );
    }
    _validateStructuredOutputEvidence(fields, errors);
  }

  return HighRiskContractResult(assessment: assessment, errors: errors);
}

void _validateStructuredOutputEvidence(
  Map<String, String> fields,
  List<String> errors,
) {
  _requirePassEvidence(
    fields,
    errors,
    'Compiled grammar valid upstream emissions',
    const ['compiled', 'upstream'],
  );
  _requirePassEvidence(
    fields,
    errors,
    'Compiled grammar rejection matrix',
    const ['compiled', 'unknown', 'missing', 'wrong-type', 'malformed'],
  );
  _requirePassEvidence(
    fields,
    errors,
    'Schema-directed types and empty values',
    const ['string', 'number', 'boolean', 'null', 'object', 'array', 'empty'],
  );
  _requirePassEvidence(
    fields,
    errors,
    'Partial/final streaming and rollback',
    const ['partial', 'final', 'rollback'],
  );
  _requirePassEvidence(
    fields,
    errors,
    'Tool choice and thinking prefixes',
    const ['auto', 'required', 'none', 'thinking'],
  );
  _requirePassEvidence(
    fields,
    errors,
    'Pinned/current upstream template/parser parity',
    const ['pinned', 'current', 'upstream', 'run_template_parity_suites.sh'],
  );
  _requireAffectedFormatEvidence(fields, errors);
}

Map<String, String> _parseEvidenceFields(String body) {
  final fields = <String, String>{};
  final pattern = RegExp(
    r'^\s*-\s*\*\*([^*]+):\*\*\s*(.*?)\s*$',
    multiLine: true,
  );
  for (final match in pattern.allMatches(body)) {
    fields[match.group(1)!.trim()] = match.group(2)!.trim();
  }
  return fields;
}

void _expectExact(
  Map<String, String> fields,
  List<String> errors,
  String label,
  String expected,
) {
  final actual = fields[label];
  if (actual != expected) {
    errors.add('$label must be exactly "$expected"; found "${actual ?? ''}".');
  }
}

String? _requireDetail(
  Map<String, String> fields,
  List<String> errors,
  String label,
) {
  final value = fields[label]?.trim();
  if (value == null ||
      value.length < 5 ||
      value.toLowerCase().startsWith('n/a')) {
    errors.add('$label requires a concrete identifier or evidence reference.');
    return null;
  }
  return value;
}

void _requirePassEvidence(
  Map<String, String> fields,
  List<String> errors,
  String label,
  List<String> requiredTerms,
) {
  final value = fields[label] ?? '';
  final lower = value.toLowerCase();
  if (!lower.startsWith('pass:')) {
    errors.add('$label must start with "PASS:" and cite exact evidence.');
    return;
  }
  for (final term in requiredTerms) {
    if (!lower.contains(term)) {
      errors.add('$label evidence must mention "$term".');
    }
  }
}

void _requireRuntimeEvidence(Map<String, String> fields, List<String> errors) {
  final affected = fields['Affected-family real model/artifact evidence'] ?? '';
  final lower = affected.toLowerCase();
  if (lower.startsWith('pass:') && affected.length < 20) {
    errors.add(
      'Affected-family real model/artifact PASS evidence must identify the '
      'model/artifact and result.',
    );
  } else if (!lower.startsWith('pass:') &&
      (!lower.startsWith('n/a:') ||
          affected.length < 35 ||
          !(lower.contains('unavailable') &&
              (lower.contains('upstream') || lower.contains('fixture'))))) {
    errors.add(
      'Affected-family real model/artifact evidence must be PASS, or N/A with '
      'the exact unavailable family and primary upstream/durable fixture proof.',
    );
  }

  final representative = fields['Unrelated representative smoke'] ?? '';
  final representativeLower = representative.toLowerCase();
  if (!(representativeLower.startsWith('pipeline-only:') ||
          representativeLower.startsWith('n/a:')) ||
      representative.length < 15) {
    errors.add(
      'Unrelated representative smoke must be explicitly classified as '
      '"pipeline-only:" or "N/A:"; it is not affected-family validation.',
    );
  }
}

void _requireAffectedFormatEvidence(
  Map<String, String> fields,
  List<String> errors,
) {
  final value = fields['Exact affected-format evidence'] ?? '';
  final lower = value.toLowerCase();
  if (lower.startsWith('pass:')) {
    if (value.length < 20) {
      errors.add(
        'Exact affected-format PASS evidence must identify the format and '
        'result.',
      );
    }
    return;
  }
  if (!lower.startsWith('n/a:') ||
      value.length < 35 ||
      !(lower.contains('unavailable') &&
          lower.contains('upstream') &&
          lower.contains('fixture'))) {
    errors.add(
      'Exact affected-format evidence must be PASS, or N/A naming every '
      'unavailable family plus primary upstream emissions and durable fixtures.',
    );
  }
}

Never _usage(String message) {
  stderr.writeln(message);
  stderr.writeln(
    'Usage: dart run tool/testing/check_high_risk_pr_contract.dart '
    '--event <event.json> --changed-files <paths.txt> --base-sha <sha> '
    '--head-sha <sha> --behind <n> --ahead <n> '
    '--unresolved-threads <n>',
  );
  exit(64);
}

Future<void> main(List<String> args) async {
  final options = <String, String>{};
  for (var index = 0; index < args.length; index += 2) {
    if (index + 1 >= args.length || !args[index].startsWith('--')) {
      _usage('Invalid arguments.');
    }
    options[args[index].substring(2)] = args[index + 1];
  }
  const required = <String>{
    'event',
    'changed-files',
    'base-sha',
    'head-sha',
    'behind',
    'ahead',
    'unresolved-threads',
  };
  final missing = required.difference(options.keys.toSet());
  if (missing.isNotEmpty) _usage('Missing options: ${missing.join(', ')}');

  final event = jsonDecode(await File(options['event']!).readAsString());
  if (event is! Map<String, dynamic>) _usage('Event root must be an object.');
  final pullRequest = event['pull_request'];
  if (pullRequest is! Map<String, dynamic>) {
    _usage('Event does not contain a pull_request object.');
  }
  final body = pullRequest['body'];
  final changedFiles = await File(options['changed-files']!).readAsLines();
  final state = HighRiskPrState(
    headSha: options['head-sha']!,
    baseSha: options['base-sha']!,
    behind: int.parse(options['behind']!),
    ahead: int.parse(options['ahead']!),
    unresolvedThreads: int.parse(options['unresolved-threads']!),
  );
  final result = validateHighRiskContract(
    changedFiles: changedFiles,
    body: body is String ? body : '',
    state: state,
  );

  final surfaceNames =
      result.assessment.surfaces.map((surface) => surface.name).toList()
        ..sort();
  final summary = StringBuffer()
    ..writeln('## High-risk regression contract')
    ..writeln()
    ..writeln('- High risk: `${result.assessment.isHighRisk}`')
    ..writeln('- Surfaces: `${surfaceNames.join(', ')}`')
    ..writeln('- Head: `${state.headSha}`')
    ..writeln('- Current base: `${state.baseSha}`')
    ..writeln('- Distance: `${state.behind} behind / ${state.ahead} ahead`')
    ..writeln('- Unresolved review threads: `${state.unresolvedThreads}`');
  if (result.errors.isNotEmpty) {
    summary
      ..writeln()
      ..writeln('### Blocking findings');
    for (final error in result.errors) {
      summary.writeln('- $error');
    }
  }
  stdout.write(summary);
  final stepSummary = Platform.environment['GITHUB_STEP_SUMMARY'];
  if (stepSummary != null && stepSummary.isNotEmpty) {
    await File(stepSummary).writeAsString(summary.toString());
  }
  if (!result.isValid) exitCode = 1;
}
