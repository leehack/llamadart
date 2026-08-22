#!/usr/bin/env dart

import 'dart:convert';
import 'dart:io';

enum HighRiskSurface {
  structuredOutput,
  backendRuntime,
  artifactConsumer,
  releaseAutomation,
  regressionPolicy,
}

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

class HighRiskPrState {
  const HighRiskPrState({
    required this.headSha,
    required this.baseSha,
    required this.behind,
    required this.ahead,
    required this.unresolvedThreads,
    required this.authorLogin,
    required this.reviews,
  });

  final String headSha;
  final String baseSha;
  final int behind;
  final int ahead;
  final int unresolvedThreads;
  final String authorLogin;
  final List<HighRiskReview> reviews;
}

class HighRiskReview {
  const HighRiskReview({
    required this.id,
    required this.authorLogin,
    required this.commitSha,
    required this.state,
    required this.body,
  });

  final int id;
  final String authorLogin;
  final String commitSha;
  final String state;
  final String body;
}

class HighRiskContractResult {
  const HighRiskContractResult({
    required this.assessment,
    required this.errors,
  });

  final HighRiskAssessment assessment;
  final List<String> errors;

  bool get isValid => errors.isEmpty;
}

const _evidencePrefix = '.github/high-risk-evidence/';
final _taskReference = RegExp(
  r'^(?:codex://(?:threads|tasks)/[A-Za-z0-9_./-]{20,}|https://github\.com/[^/]+/[^/]+/(?:issues|pull)/[0-9]+(?:#[A-Za-z0-9_.-]+)?)$',
);

HighRiskAssessment assessHighRiskFiles(Iterable<String> files) {
  final normalized = files
      .map((file) => file)
      .where((file) => file.isNotEmpty)
      .toList(growable: false);
  final surfaces = <HighRiskSurface>{};

  for (final path in normalized) {
    if (path.startsWith('lib/src/core/template/') ||
        path.startsWith('lib/src/core/grammar/') ||
        path == 'lib/src/core/engine/chat_completion_stream_parser.dart' ||
        path == 'lib/src/core/engine/chat_template_renderer.dart' ||
        path == 'lib/src/core/models/inference/tool_choice.dart' ||
        path == 'lib/src/core/models/inference/structured_output.dart' ||
        path == 'lib/src/core/models/inference/generation_params.dart' ||
        path == 'lib/src/core/models/chat/chat_message.dart' ||
        path == 'lib/src/core/models/chat/chat_template_result.dart' ||
        path == 'lib/src/core/models/chat/completion_chunk.dart' ||
        path == 'lib/src/core/models/chat/content_part.dart' ||
        path.startsWith('lib/src/core/models/tools/') ||
        (path.startsWith('lib/src/') && path.contains('/chat_template'))) {
      surfaces.add(HighRiskSurface.structuredOutput);
    }
    if (_isStructuredOutputGateScript(path)) {
      surfaces.add(HighRiskSurface.structuredOutput);
    }
    if (path == 'lib/llamadart.dart' ||
        path.startsWith('lib/src/backends/') ||
        path.startsWith('lib/src/core/engine/') ||
        path.startsWith('lib/src/core/models/') ||
        path.startsWith('lib/src/core/speech/') ||
        path.startsWith('lib/src/core/models/config/') ||
        path.startsWith('lib/src/platform/') ||
        path == 'lib/src/core/models/chat/content_part.dart' ||
        path ==
            'lib/src/core/models/download/model_download_manager_base.dart') {
      surfaces.add(HighRiskSurface.backendRuntime);
    }
    if (path == 'pubspec.yaml' ||
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
        path.startsWith('packages/llamadart_litert_lm_flutter/')) {
      surfaces.add(HighRiskSurface.artifactConsumer);
    }
    if (_isReleaseWorkflow(path) ||
        path == 'tool/testing/verify_release_docs_versions.dart' ||
        path.startsWith('tool/release/') ||
        path.startsWith('scripts/release/')) {
      surfaces.add(HighRiskSurface.releaseAutomation);
    }
    if (path.startsWith('.github/workflows/') ||
        path.startsWith('.github/actions/') ||
        path == '.github/pull_request_template.md' ||
        path == '.github/CODEOWNERS' ||
        path == '.github/workflows/high_risk_regression_gate.yml' ||
        path.startsWith(_evidencePrefix) ||
        path == 'AGENTS.md' ||
        path == 'doc/testing_matrix.md' ||
        path == 'tool/testing/test_matrix.dart' ||
        path == 'tool/testing/enforce_high_risk_pr_contract.dart' ||
        path == 'tool/testing/check_high_risk_pr_contract.dart' ||
        path == 'test/unit/tooling/high_risk_pr_contract_test.dart' ||
        path == 'test/unit/tooling/trusted_high_risk_contract_test.dart') {
      surfaces.add(HighRiskSurface.regressionPolicy);
    }
    if (_isGateScript(path)) {
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
      name.contains('sync') ||
      name == 'docs_version_cut.yml';
}

bool _isGateScript(String path) {
  return path.startsWith('tool/testing/');
}

bool _isStructuredOutputGateScript(String path) {
  if (!path.startsWith('tool/testing/')) return false;
  final name = path.split('/').last;
  return name.contains('template') ||
      name.contains('grammar') ||
      name.contains('structured');
}

HighRiskContractResult validateHighRiskContract({
  required Iterable<String> changedFiles,
  Iterable<String> deletedFiles = const [],
  required String body,
  required HighRiskPrState state,
  Map<String, dynamic>? evidence,
  String? evidencePath,
}) {
  final assessment = assessHighRiskFiles(changedFiles);
  final errors = <String>[];
  final fields = _parseEvidenceFields(body);

  if (!assessment.isHighRisk) {
    final classification = fields['High-risk classification'];
    if (classification != null && classification != 'standard') {
      errors.add('Non-high-risk changes must use "standard".');
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
  if (state.behind != 0) {
    errors.add('High-risk QA must integrate the current base before ready.');
  }
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

  final implementationTask = _requireTaskReference(
    fields,
    errors,
    'Implementation task',
  );
  final qaTask = _requireTaskReference(
    fields,
    errors,
    'Independent blocking QA task',
  );
  if (implementationTask != null && implementationTask == qaTask) {
    errors.add('Independent QA task must differ from implementation task.');
  }
  if (qaTask != null && !_hasIndependentQaAttestation(state, qaTask)) {
    errors.add(
      'Independent QA PASS requires a current-head APPROVED review from a '
      'reviewer other than the PR author, attesting the QA task, head, base, '
      'and PASS verdict.',
    );
  }
  if (state.authorLogin.isEmpty) {
    errors.add('Trusted PR metadata must include the author login.');
  }

  final manifests = assessment.changedFiles
      .where(
        (path) => path.startsWith(_evidencePrefix) && path.endsWith('.json'),
      )
      .toList();
  if (manifests.length != 1) {
    errors.add(
      'High-risk changes require exactly one changed '
      '.github/high-risk-evidence/*.json manifest.',
    );
  }
  if (evidencePath == null || evidence == null) {
    errors.add('Trusted workflow must supply the changed evidence manifest.');
  } else {
    _expectExact(fields, errors, 'Evidence manifest', evidencePath);
    if (!manifests.contains(evidencePath)) {
      errors.add('Evidence manifest must be one of the changed files.');
    }
    final issueMatch = RegExp(
      r'^\.github/high-risk-evidence/([1-9][0-9]*)\.json$',
    ).firstMatch(evidencePath);
    final expectedIssue = issueMatch == null
        ? null
        : int.parse(issueMatch.group(1)!);
    if (expectedIssue == null || evidence['issue'] != expectedIssue) {
      errors.add('Manifest issue must match its numeric evidence filename.');
    }
    _validateEvidenceManifest(
      evidence,
      assessment: assessment,
      deletedFiles: deletedFiles.toSet(),
      implementationTask: implementationTask,
      qaTask: qaTask,
      errors: errors,
    );
  }

  return HighRiskContractResult(assessment: assessment, errors: errors);
}

void _validateEvidenceManifest(
  Map<String, dynamic> evidence, {
  required HighRiskAssessment assessment,
  required Set<String> deletedFiles,
  required String? implementationTask,
  required String? qaTask,
  required List<String> errors,
}) {
  if (evidence['schema'] != 1) errors.add('Evidence schema must be 1.');
  if (evidence['implementationTask'] != implementationTask) {
    errors.add('Manifest implementationTask must match the PR body.');
  }
  if (evidence['independentQaTask'] != qaTask) {
    errors.add('Manifest independentQaTask must match the PR body.');
  }

  final surfaceNames = assessment.surfaces
      .map((surface) => surface.name)
      .toSet();
  final declaredSurfaces = _stringSet(evidence['surfaces'], 'surfaces', errors);
  if (!declaredSurfaces.containsAll(surfaceNames)) {
    errors.add('Manifest surfaces must include every classified surface.');
  }

  final changed = assessment.changedFiles.toSet();
  final production = evidence['productionEvidence'];
  if (production is! Map<String, dynamic>) {
    errors.add('Manifest productionEvidence must be an object.');
  } else {
    for (final key in const [
      'positiveTests',
      'negativeTests',
      'adversarialTests',
      'deletionSensitivityTests',
    ]) {
      _validateTestPaths(
        production[key],
        'productionEvidence.$key',
        changed,
        deletedFiles,
        errors,
      );
    }
  }

  final affectedFamilies = _stringSet(
    evidence['affectedFamilies'],
    'affectedFamilies',
    errors,
    allowEmpty: !assessment.isStructuredOutput,
  );
  final familyEvidence = evidence['affectedFamilyEvidence'];
  if (affectedFamilies.isEmpty) {
    final reason = evidence['notApplicableReason'];
    if (reason is! String || reason.trim().length < 20) {
      errors.add('Empty affectedFamilies requires a concrete N/A reason.');
    }
  } else if (familyEvidence is! Map<String, dynamic> ||
      familyEvidence.keys.toSet().difference(affectedFamilies).isNotEmpty ||
      affectedFamilies.difference(familyEvidence.keys.toSet()).isNotEmpty) {
    errors.add(
      'affectedFamilyEvidence keys must exactly equal affectedFamilies.',
    );
  } else {
    for (final family in affectedFamilies) {
      final value = familyEvidence[family];
      if (value != 'real-model' && value != 'upstream+fixture') {
        errors.add(
          'Every affected-family evidence value must be real-model or '
          'upstream+fixture; representative models are not family proof.',
        );
      }
    }
  }

  if (assessment.isStructuredOutput) {
    final upstream = evidence['upstreamRefs'];
    final concreteRef = RegExp(
      r'^(?:b[0-9]+|v[0-9]+\.[0-9]+\.[0-9]+|[0-9a-f]{7,40})$',
    );
    if (upstream is! Map<String, dynamic> ||
        upstream.keys.toSet().difference(const {
          'pinned',
          'current',
        }).isNotEmpty ||
        !upstream.keys.toSet().containsAll(const {'pinned', 'current'})) {
      errors.add('upstreamRefs must contain exactly pinned and current roles.');
    } else {
      final pinned = upstream['pinned'];
      final current = upstream['current'];
      if (pinned is! String ||
          current is! String ||
          !concreteRef.hasMatch(pinned) ||
          !concreteRef.hasMatch(current) ||
          pinned == current) {
        errors.add(
          'Pinned and current upstream refs must be distinct concrete tags or commits.',
        );
      }
    }
    final structured = evidence['structuredOutput'];
    if (structured is! Map<String, dynamic>) {
      errors.add(
        'Structured-output changes require structuredOutput evidence.',
      );
      return;
    }
    for (final key in const [
      'compiledAcceptanceTests',
      'compiledRejectionTests',
    ]) {
      final paths = _validateTestPaths(
        structured[key],
        'structuredOutput.$key',
        changed,
        deletedFiles,
        errors,
      );
      if (paths.any((path) => !_isCompiledGrammarTest(path))) {
        errors.add('$key must reference compiled grammar production tests.');
      }
    }
    for (final key in const [
      'schemaDirectedTypeTests',
      'partialFinalStreamingTests',
      'toolChoiceThinkingTests',
    ]) {
      _validateTestPaths(
        structured[key],
        'structuredOutput.$key',
        changed,
        deletedFiles,
        errors,
      );
    }
    if (structured['upstreamParityCommand'] !=
        './tool/testing/run_template_parity_suites.sh') {
      errors.add(
        'upstreamParityCommand must be '
        './tool/testing/run_template_parity_suites.sh.',
      );
    }
    final coverage = _stringSet(
      structured['requiredCoverage'],
      'structuredOutput.requiredCoverage',
      errors,
    );
    const required = {
      'unknown-field',
      'missing-field',
      'mismatched-type',
      'malformed-output',
      'string',
      'number',
      'boolean',
      'null',
      'object',
      'array',
      'zero-argument',
      'empty-container',
      'partial',
      'final',
      'rollback',
      'auto',
      'required',
      'none',
      'thinking-prefix',
    };
    if (!coverage.containsAll(required)) {
      errors.add(
        'structuredOutput.requiredCoverage is missing: '
        '${required.difference(coverage).join(', ')}.',
      );
    }
  }
}

Set<String> _stringSet(
  Object? value,
  String label,
  List<String> errors, {
  bool allowEmpty = false,
}) {
  if (value is! List || value.any((item) => item is! String)) {
    errors.add('$label must be a string array.');
    return {};
  }
  final values = value.cast<String>().map((item) => item.trim()).toList();
  final result = values.where((item) => item.isNotEmpty).toSet();
  if (result.length != values.length || (!allowEmpty && result.isEmpty)) {
    errors.add('$label must contain unique non-empty values.');
  }
  return result;
}

List<String> _validateTestPaths(
  Object? value,
  String label,
  Set<String> changed,
  Set<String> deleted,
  List<String> errors,
) {
  final paths = _stringSet(value, label, errors).toList();
  for (final path in paths) {
    if (!path.startsWith('test/') || !path.endsWith('_test.dart')) {
      errors.add('$label must reference durable Dart test files.');
    }
    if (!changed.contains(path)) {
      errors.add('$label contains a path not changed by the same PR.');
    }
    if (deleted.contains(path)) {
      errors.add('$label cannot reference a deleted or renamed-away test.');
    }
  }
  return paths;
}

bool _isCompiledGrammarTest(String path) =>
    path ==
    'test/e2e/template/specialized_tool_grammar_validation_e2e_test.dart';

bool _hasIndependentQaAttestation(HighRiskPrState state, String qaTask) {
  final requiredLines = <String>{
    'High-risk QA task: $qaTask',
    'Head: ${state.headSha}',
    'Base: ${state.baseSha}',
    'Verdict: PASS',
  };
  final latestByAuthor = <String, HighRiskReview>{};
  for (final review in state.reviews) {
    final author = review.authorLogin.toLowerCase();
    final previous = latestByAuthor[author];
    if (previous == null || review.id > previous.id) {
      latestByAuthor[author] = review;
    }
  }
  return latestByAuthor.values.any((review) {
    final lines = review.body
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .toSet();
    return review.state == 'APPROVED' &&
        review.commitSha == state.headSha &&
        review.authorLogin.isNotEmpty &&
        review.authorLogin.toLowerCase() != state.authorLogin.toLowerCase() &&
        lines.containsAll(requiredLines);
  });
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
    errors.add('$label does not match trusted live state.');
  }
}

String? _requireTaskReference(
  Map<String, String> fields,
  List<String> errors,
  String label,
) {
  final value = fields[label]?.trim();
  if (value == null || !_taskReference.hasMatch(value)) {
    errors.add(
      '$label must be a stable Codex task/thread or GitHub reference.',
    );
    return null;
  }
  return value;
}

Never _usage(String message) {
  stderr.writeln(message);
  stderr.writeln(
    'Usage: dart tool/testing/enforce_high_risk_pr_contract.dart '
    '--event <event.json> --changed-files <paths.txt> '
    '--deleted-files <paths.txt> [--evidence <manifest.json> '
    '--evidence-path <repo-path>] --base-sha <sha> --head-sha <sha> '
    '--behind <n> --ahead <n> --unresolved-threads <n> --reviews <json>',
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
    'deleted-files',
    'base-sha',
    'head-sha',
    'behind',
    'ahead',
    'unresolved-threads',
    'reviews',
  };
  final missing = required.difference(options.keys.toSet());
  if (missing.isNotEmpty) _usage('Missing options: ${missing.join(', ')}');

  final event = jsonDecode(await File(options['event']!).readAsString());
  if (event is! Map<String, dynamic>) _usage('Event root must be an object.');
  final pullRequest = event['pull_request'];
  if (pullRequest is! Map<String, dynamic>) {
    _usage('Event does not contain a pull_request object.');
  }
  Map<String, dynamic>? evidence;
  final evidenceFile = options['evidence'];
  if (evidenceFile != null) {
    final decoded = jsonDecode(await File(evidenceFile).readAsString());
    if (decoded is! Map<String, dynamic>) _usage('Evidence must be an object.');
    evidence = decoded;
  }
  final state = HighRiskPrState(
    headSha: options['head-sha']!,
    baseSha: options['base-sha']!,
    behind: int.parse(options['behind']!),
    ahead: int.parse(options['ahead']!),
    unresolvedThreads: int.parse(options['unresolved-threads']!),
    authorLogin: pullRequest['user'] is Map<String, dynamic>
        ? ((pullRequest['user'] as Map<String, dynamic>)['login'] as String? ??
              '')
        : '',
    reviews: _decodeReviews(
      jsonDecode(await File(options['reviews']!).readAsString()),
    ),
  );
  final result = validateHighRiskContract(
    changedFiles: await File(options['changed-files']!).readAsLines(),
    deletedFiles: await File(options['deleted-files']!).readAsLines(),
    body: pullRequest['body'] is String ? pullRequest['body'] as String : '',
    state: state,
    evidence: evidence,
    evidencePath: options['evidence-path'],
  );

  final names =
      result.assessment.surfaces.map((surface) => surface.name).toList()
        ..sort();
  final summary = StringBuffer()
    ..writeln('## High-risk regression contract')
    ..writeln()
    ..writeln('- High risk: `${result.assessment.isHighRisk}`')
    ..writeln('- Surfaces: `${names.join(', ')}`')
    ..writeln('- Head: `${state.headSha}`')
    ..writeln('- Base: `${state.baseSha}`')
    ..writeln('- Evidence: `${options['evidence-path'] ?? 'none'}`');
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

List<HighRiskReview> _decodeReviews(Object? value) {
  if (value is! List) _usage('Reviews must be an array.');
  return value
      .map((item) {
        if (item is! Map<String, dynamic>) {
          _usage('Every review must be an object.');
        }
        final user = item['user'];
        final author = user is Map<String, dynamic> ? user['login'] : null;
        final id = item['id'];
        final commitSha = item['commit_id'];
        final state = item['state'];
        final body = item['body'];
        if (id is! int ||
            author is! String ||
            commitSha is! String ||
            state is! String ||
            (body != null && body is! String)) {
          _usage('Review fields are malformed.');
        }
        return HighRiskReview(
          id: id,
          authorLogin: author,
          commitSha: commitSha,
          state: state,
          body: body as String? ?? '',
        );
      })
      .toList(growable: false);
}
