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
    required this.number,
    required this.headRepository,
    required this.headSha,
    required this.baseSha,
    required this.behind,
    required this.ahead,
    required this.unresolvedThreads,
    required this.authorLogin,
    required this.prBodyDigest,
    required this.reviews,
  });

  final int number;
  final String headRepository;
  final String headSha;
  final String baseSha;
  final int behind;
  final int ahead;
  final int unresolvedThreads;
  final String authorLogin;
  final String prBodyDigest;
  final List<HighRiskReview> reviews;
}

class HighRiskReview {
  const HighRiskReview({
    required this.id,
    required this.authorLogin,
    required this.authorAssociation,
    required this.commitSha,
    required this.state,
    required this.body,
  });

  final int id;
  final String authorLogin;
  final String authorAssociation;
  final String commitSha;
  final String state;
  final String body;
}

class HighRiskCiRun {
  const HighRiskCiRun({
    required this.id,
    required this.runAttempt,
    required this.headSha,
    required this.event,
    required this.path,
    required this.status,
    required this.conclusion,
    required this.pullRequests,
  });

  final int id;
  final int runAttempt;
  final String headSha;
  final String event;
  final String path;
  final String status;
  final String? conclusion;
  final List<HighRiskCiPullRequest> pullRequests;
}

class HighRiskCiPullRequest {
  const HighRiskCiPullRequest({
    required this.number,
    required this.headSha,
    required this.baseSha,
    required this.headRepository,
  });

  final int number;
  final String headSha;
  final String baseSha;
  final String headRepository;
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

HighRiskAssessment assessHighRiskFiles(
  Iterable<String> files, {
  Set<String> protectedEvidencePaths = const {},
  Set<String> compiledGrammarTests = const {},
  Set<String> structuredOutputParityDependencies = const {},
}) {
  final normalized = files
      .map((file) => file)
      .where((file) => file.isNotEmpty)
      .toList(growable: false);
  final surfaces = <HighRiskSurface>{};

  for (final path in normalized) {
    if (path == 'lib/llamadart.dart' ||
        path.startsWith('lib/src/core/template/') ||
        path.startsWith('lib/src/core/grammar/') ||
        path.startsWith('lib/src/core/engine/') ||
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
        path == 'lib/src/core/cache_policy.dart' ||
        path == 'test/unit/core/cache_policy_test.dart' ||
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
        path == '.github/high-risk-policy.json' ||
        path == '.github/workflows/high_risk_regression_gate.yml' ||
        path.startsWith(_evidencePrefix) ||
        path == 'AGENTS.md' ||
        path == 'doc/testing_matrix.md' ||
        path == 'tool/testing/test_matrix.dart' ||
        path == 'tool/testing/enforce_high_risk_pr_contract.dart' ||
        path == 'tool/testing/check_high_risk_pr_contract.dart' ||
        path == 'test/unit/tooling/high_risk_pr_contract_test.dart' ||
        path == 'test/unit/tooling/trusted_high_risk_contract_test.dart' ||
        path == 'test/unit/core/cache_policy_test.dart') {
      surfaces.add(HighRiskSurface.regressionPolicy);
    }
    if (_isGateScript(path)) {
      surfaces.add(HighRiskSurface.regressionPolicy);
    }
    if (_isProtectedEvidencePath(path, protectedEvidencePaths)) {
      surfaces.add(HighRiskSurface.regressionPolicy);
    }
    if (_isProtectedEvidencePath(path, structuredOutputParityDependencies)) {
      surfaces
        ..add(HighRiskSurface.structuredOutput)
        ..add(HighRiskSurface.regressionPolicy);
    }
    if (_isProtectedEvidencePath(path, compiledGrammarTests)) {
      surfaces
        ..add(HighRiskSurface.structuredOutput)
        ..add(HighRiskSurface.regressionPolicy);
    }
  }

  return HighRiskAssessment(changedFiles: normalized, surfaces: surfaces);
}

bool _isProtectedEvidencePath(String path, Set<String> protectedPaths) {
  return protectedPaths.any(
    (protected) => protected.endsWith('/')
        ? path.startsWith(protected)
        : path == protected,
  );
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
  Map<String, String> verifiedUpstreamCommits = const {},
  Set<String> compiledGrammarTests = const {},
  Set<String> protectedEvidencePaths = const {},
  Set<String> baselineEvidencePaths = const {},
  Set<String> structuredOutputParityDependencies = const {},
  Set<String>? proposedCompiledGrammarTests,
  Set<String>? proposedStructuredOutputParityDependencies,
  List<HighRiskCiRun> ciRuns = const [],
  Map<String, dynamic>? trustedUpstreamParityEvidence,
}) {
  final assessment = assessHighRiskFiles(
    changedFiles,
    protectedEvidencePaths: protectedEvidencePaths,
    compiledGrammarTests: compiledGrammarTests,
    structuredOutputParityDependencies: structuredOutputParityDependencies,
  );
  final errors = <String>[];
  final fields = _parseEvidenceFields(body, errors);

  if (assessment.changedFiles.contains('.github/high-risk-policy.json')) {
    if (proposedCompiledGrammarTests == null ||
        proposedStructuredOutputParityDependencies == null) {
      errors.add(
        'Policy edits require the exact proposed policy as untrusted data.',
      );
    } else {
      final removedGrammarTests = compiledGrammarTests.difference(
        proposedCompiledGrammarTests,
      );
      final removedParityDependencies = structuredOutputParityDependencies
          .difference(proposedStructuredOutputParityDependencies);
      if (removedGrammarTests.isNotEmpty ||
          removedParityDependencies.isNotEmpty) {
        errors.add(
          'High-risk policy edits must preserve every trusted compiled-grammar '
          'test and structured-output parity dependency.',
        );
      }
    }
  }

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
  final latestCi = selectLatestExactHeadCiRun(ciRuns, state);
  if (latestCi == null ||
      latestCi.status != 'completed' ||
      latestCi.conclusion != 'success') {
    errors.add('The latest exact-head CI run must succeed.');
  }
  if (deletedFiles.any(
    (path) =>
        _isProtectedEvidencePath(path, protectedEvidencePaths) ||
        _isProtectedEvidencePath(path, structuredOutputParityDependencies),
  )) {
    errors.add(
      'Trusted policy or evidence paths cannot be deleted or renamed.',
    );
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
      'trusted repository reviewer other than the PR author, attesting the '
      'QA task, head, base, PR-body digest, and PASS verdict.',
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
    final proposedEvidencePaths = _evidenceTestPaths(evidence);
    if (baselineEvidencePaths.difference(proposedEvidencePaths).isNotEmpty) {
      errors.add(
        'A proposed evidence manifest must preserve every durable test path '
        'referenced by its trusted-base version.',
      );
    }
    _validateEvidenceManifest(
      evidence,
      assessment: assessment,
      deletedFiles: deletedFiles.toSet(),
      headSha: state.headSha,
      implementationTask: implementationTask,
      qaTask: qaTask,
      verifiedUpstreamCommits: verifiedUpstreamCommits,
      compiledGrammarTests: compiledGrammarTests,
      structuredOutputParityDependencies: structuredOutputParityDependencies,
      trustedUpstreamParityEvidence: trustedUpstreamParityEvidence,
      errors: errors,
    );
  }

  return HighRiskContractResult(assessment: assessment, errors: errors);
}

HighRiskCiRun? selectLatestExactHeadCiRun(
  Iterable<HighRiskCiRun> runs,
  HighRiskPrState state,
) {
  final matching = runs
      .where(
        (run) =>
            run.headSha == state.headSha &&
            run.event == 'pull_request' &&
            run.path == '.github/workflows/ci.yml' &&
            run.pullRequests.any(
              (pullRequest) =>
                  pullRequest.number == state.number &&
                  pullRequest.headSha == state.headSha &&
                  pullRequest.baseSha == state.baseSha &&
                  pullRequest.headRepository == state.headRepository,
            ),
      )
      .toList();
  if (matching.isEmpty) return null;
  matching.sort((left, right) {
    final id = left.id.compareTo(right.id);
    if (id != 0) return id;
    return left.runAttempt.compareTo(right.runAttempt);
  });
  return matching.last;
}

Set<String> _evidenceTestPaths(Map<String, dynamic> evidence) {
  final paths = <String>{};
  void collect(Object? value) {
    if (value is List) paths.addAll(value.whereType<String>());
  }

  final production = evidence['productionEvidence'];
  if (production is Map<String, dynamic>) {
    for (final key in const [
      'positiveTests',
      'negativeTests',
      'adversarialTests',
      'deletionSensitivityTests',
    ]) {
      collect(production[key]);
    }
  }
  final structured = evidence['structuredOutput'];
  if (structured is Map<String, dynamic>) {
    for (final key in const [
      'compiledAcceptanceTests',
      'compiledRejectionTests',
      'schemaDirectedTypeTests',
      'partialFinalStreamingTests',
      'toolChoiceThinkingTests',
      'upstreamParityTests',
    ]) {
      collect(structured[key]);
    }
  }
  return paths;
}

void _validateEvidenceManifest(
  Map<String, dynamic> evidence, {
  required HighRiskAssessment assessment,
  required Set<String> deletedFiles,
  required String headSha,
  required String? implementationTask,
  required String? qaTask,
  required Map<String, String> verifiedUpstreamCommits,
  required Set<String> compiledGrammarTests,
  required Set<String> structuredOutputParityDependencies,
  required Map<String, dynamic>? trustedUpstreamParityEvidence,
  required List<String> errors,
}) {
  if (evidence['schema'] != 1) errors.add('Evidence schema must be 1.');
  if (evidence['knownPrCausedP1Regressions'] != 0) {
    errors.add('Manifest must report zero known PR-caused P1 regressions.');
  }
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
    allowEmpty:
        !assessment.isStructuredOutput ||
        !assessment.changedFiles.any((path) => path.startsWith('lib/')),
  );
  final familyEvidence = evidence['affectedFamilyEvidence'];
  if (affectedFamilies.isEmpty) {
    if (familyEvidence is! Map<String, dynamic> || familyEvidence.isNotEmpty) {
      errors.add(
        'Empty affectedFamilies requires affectedFamilyEvidence to be an exactly empty object.',
      );
    }
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
          'repository',
          'pinned',
          'current',
        }).isNotEmpty ||
        !upstream.keys.toSet().containsAll(const {
          'repository',
          'pinned',
          'current',
        })) {
      errors.add(
        'upstreamRefs must contain exactly repository, pinned, and current roles.',
      );
    } else {
      final repository = upstream['repository'];
      final pinned = upstream['pinned'];
      final current = upstream['current'];
      if (repository != 'ggml-org/llama.cpp') {
        errors.add('upstreamRefs.repository must be ggml-org/llama.cpp.');
      } else if (pinned is! String ||
          current is! String ||
          !concreteRef.hasMatch(pinned) ||
          !concreteRef.hasMatch(current) ||
          pinned == current) {
        errors.add(
          'Pinned and current upstream refs must be distinct concrete tags or commits.',
        );
      } else if (verifiedUpstreamCommits.keys.toSet().difference(const {
            'pinned',
            'current',
          }).isNotEmpty ||
          !verifiedUpstreamCommits.keys.toSet().containsAll(const {
            'pinned',
            'current',
          })) {
        errors.add(
          'Trusted workflow must supply exactly the pinned and current canonical upstream commits.',
        );
      } else if (verifiedUpstreamCommits['pinned'] ==
          verifiedUpstreamCommits['current']) {
        errors.add(
          'Pinned and current upstream refs must resolve to distinct canonical commits.',
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
      if (paths.any((path) => !compiledGrammarTests.contains(path))) {
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
    final parityTests = _validateTestPaths(
      structured['upstreamParityTests'],
      'structuredOutput.upstreamParityTests',
      changed,
      deletedFiles,
      errors,
    );
    if (parityTests.any(
      (path) =>
          !_isProtectedEvidencePath(path, structuredOutputParityDependencies),
    )) {
      errors.add(
        'structuredOutput.upstreamParityTests must reference trusted '
        'structured-output parity dependencies.',
      );
    }
    _validateTrustedUpstreamParityEvidence(
      trustedUpstreamParityEvidence,
      headSha: headSha,
      canonicalRefs: verifiedUpstreamCommits,
      errors: errors,
    );
    final coverage = _stringSet(
      structured['requiredCoverage'],
      'structuredOutput.requiredCoverage',
      errors,
    );
    const required = {
      'unknown-field',
      'missing-field',
      'mismatched-type',
      'wrong-type',
      'malformed-output',
      'escaped-name',
      'quoted-name',
      'schema-exact',
      'delimiter',
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

void _validateTrustedUpstreamParityEvidence(
  Map<String, dynamic>? evidence, {
  required String? headSha,
  required Map<String, String> canonicalRefs,
  required List<String> errors,
}) {
  if (evidence == null) {
    errors.add(
      'Structured-output changes require independently reproduced trusted-base upstream parity evidence.',
    );
    return;
  }
  final expected = <String, dynamic>{
    'schema': 1,
    'headSha': headSha,
    'result': 'PASS',
    'source': 'trusted-default-branch',
    'command': './tool/testing/run_template_parity_suites.sh',
    'canonicalUpstreamCommits': canonicalRefs,
  };
  if (jsonEncode(_canonicalJson(evidence)) !=
      jsonEncode(_canonicalJson(expected))) {
    errors.add(
      'Trusted-base upstream parity evidence must exactly bind the head, canonical refs, command, and PASS result.',
    );
  }
}

Object? _canonicalJson(Object? value) {
  if (value is List) return value.map(_canonicalJson).toList(growable: false);
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _canonicalJson(value[key])};
  }
  return value;
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
  if (value is! List || value.any((item) => item is! String)) {
    errors.add('$label must be a string array.');
    return const [];
  }
  final paths = value.cast<String>();
  if (paths.isEmpty ||
      paths.toSet().length != paths.length ||
      paths.any((path) => path.isEmpty || path.trim() != path)) {
    errors.add(
      '$label must contain unique non-empty paths with exact spelling.',
    );
  }
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
  return paths.toList(growable: false);
}

bool _hasIndependentQaAttestation(HighRiskPrState state, String qaTask) {
  final requiredLines = <String>{
    'High-risk QA task: $qaTask',
    'Head: ${state.headSha}',
    'Base: ${state.baseSha}',
    'PR body SHA-256: ${state.prBodyDigest}',
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
        const {
          'OWNER',
          'MEMBER',
          'COLLABORATOR',
        }.contains(review.authorAssociation) &&
        review.commitSha == state.headSha &&
        review.authorLogin.isNotEmpty &&
        review.authorLogin.toLowerCase() != state.authorLogin.toLowerCase() &&
        lines.containsAll(requiredLines);
  });
}

Map<String, String> _parseEvidenceFields(String body, List<String> errors) {
  final fields = <String, String>{};
  final pattern = RegExp(r'^-\s+\*\*([^*]+):\*\*\s*(.*?)\s*$');
  final openingFence = RegExp(r'^ {0,3}(`{3,}|~{3,})(.*)$');
  final closingFence = RegExp(r'^ {0,3}(`{3,}|~{3,})[ \t]*$');
  var inHtmlComment = false;
  String? fenceCharacter;
  var fenceLength = 0;
  for (final rawLine in body.split(RegExp(r'\r?\n'))) {
    if (fenceCharacter != null) {
      final match = closingFence.firstMatch(rawLine);
      if (match != null) {
        final marker = match.group(1)!;
        if (marker[0] == fenceCharacter && marker.length >= fenceLength) {
          fenceCharacter = null;
          fenceLength = 0;
        }
      }
      continue;
    }
    if (!inHtmlComment) {
      final match = openingFence.firstMatch(rawLine);
      if (match != null) {
        final marker = match.group(1)!;
        final info = match.group(2)!;
        if (marker[0] != '`' || !info.contains('`')) {
          fenceCharacter = marker[0];
          fenceLength = marker.length;
          continue;
        }
      }
    }

    final visible = StringBuffer();
    var offset = 0;
    while (offset < rawLine.length) {
      if (inHtmlComment) {
        final end = rawLine.indexOf('-->', offset);
        if (end == -1) {
          offset = rawLine.length;
        } else {
          inHtmlComment = false;
          offset = end + 3;
        }
      } else {
        final start = rawLine.indexOf('<!--', offset);
        if (start == -1) {
          visible.write(rawLine.substring(offset));
          offset = rawLine.length;
        } else {
          visible.write(rawLine.substring(offset, start));
          visible.write(' ');
          inHtmlComment = true;
          offset = start + 4;
        }
      }
    }
    final match = pattern.firstMatch(visible.toString());
    if (match == null) continue;
    final label = match.group(1)!.trim();
    if (fields.containsKey(label)) {
      errors.add('PR body contains duplicate evidence field: $label.');
      continue;
    }
    fields[label] = match.group(2)!.trim();
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
    '--behind <n> --ahead <n> --unresolved-threads <n> --reviews <json> '
    '--pr-body-digest <sha256> --verified-upstream-commits <json> '
    '--compiled-grammar-policy <json> --protected-evidence-paths <paths.txt> '
    '--baseline-evidence-paths <paths.txt> --ci-runs <json> '
    '[--trusted-upstream-parity-evidence <json>]',
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
    'pr-body-digest',
    'verified-upstream-commits',
    'compiled-grammar-policy',
    'protected-evidence-paths',
    'baseline-evidence-paths',
    'ci-runs',
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
    number: pullRequest['number'] as int,
    headRepository:
        ((pullRequest['head'] as Map<String, dynamic>)['repo']
                as Map<String, dynamic>)['full_name']
            as String,
    headSha: options['head-sha']!,
    baseSha: options['base-sha']!,
    behind: int.parse(options['behind']!),
    ahead: int.parse(options['ahead']!),
    unresolvedThreads: int.parse(options['unresolved-threads']!),
    authorLogin: pullRequest['user'] is Map<String, dynamic>
        ? ((pullRequest['user'] as Map<String, dynamic>)['login'] as String? ??
              '')
        : '',
    prBodyDigest: options['pr-body-digest']!,
    reviews: _decodeReviews(
      jsonDecode(await File(options['reviews']!).readAsString()),
    ),
  );
  final policy = _decodeHighRiskPolicy(
    jsonDecode(await File(options['compiled-grammar-policy']!).readAsString()),
  );
  final proposedPolicy = options['proposed-policy'] == null
      ? null
      : _decodeHighRiskPolicy(
          jsonDecode(await File(options['proposed-policy']!).readAsString()),
        );
  final result = validateHighRiskContract(
    changedFiles: await File(options['changed-files']!).readAsLines(),
    deletedFiles: await File(options['deleted-files']!).readAsLines(),
    body: pullRequest['body'] is String ? pullRequest['body'] as String : '',
    state: state,
    evidence: evidence,
    evidencePath: options['evidence-path'],
    verifiedUpstreamCommits: _decodeVerifiedUpstreamCommits(
      jsonDecode(
        await File(options['verified-upstream-commits']!).readAsString(),
      ),
    ),
    compiledGrammarTests: policy.compiledGrammarTests,
    protectedEvidencePaths: (await File(
      options['protected-evidence-paths']!,
    ).readAsLines()).toSet(),
    baselineEvidencePaths: (await File(
      options['baseline-evidence-paths']!,
    ).readAsLines()).where((path) => path.isNotEmpty).toSet(),
    structuredOutputParityDependencies:
        policy.structuredOutputParityDependencies,
    proposedCompiledGrammarTests: proposedPolicy?.compiledGrammarTests,
    proposedStructuredOutputParityDependencies:
        proposedPolicy?.structuredOutputParityDependencies,
    ciRuns: _decodeCiRuns(
      jsonDecode(await File(options['ci-runs']!).readAsString()),
    ),
    trustedUpstreamParityEvidence:
        options['trusted-upstream-parity-evidence'] == null
        ? null
        : jsonDecode(
                await File(
                  options['trusted-upstream-parity-evidence']!,
                ).readAsString(),
              )
              as Map<String, dynamic>,
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
    ..writeln('- PR body SHA-256: `${state.prBodyDigest}`')
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
        final authorAssociation = item['author_association'];
        final commitSha = item['commit_id'];
        final state = item['state'];
        final body = item['body'];
        if (id is! int ||
            author is! String ||
            authorAssociation is! String ||
            commitSha is! String ||
            state is! String ||
            (body != null && body is! String)) {
          _usage('Review fields are malformed.');
        }
        return HighRiskReview(
          id: id,
          authorLogin: author,
          authorAssociation: authorAssociation,
          commitSha: commitSha,
          state: state,
          body: body as String? ?? '',
        );
      })
      .toList(growable: false);
}

Map<String, String> _decodeVerifiedUpstreamCommits(Object? value) {
  if (value is! Map<String, dynamic>) {
    _usage('Verified upstream commits must be an object.');
  }
  if (value.isEmpty) return const {};
  if (value.keys.toSet().difference(const {'pinned', 'current'}).isNotEmpty ||
      !value.keys.toSet().containsAll(const {'pinned', 'current'}) ||
      value.values.any(
        (item) => item is! String || !RegExp(r'^[0-9a-f]{40}$').hasMatch(item),
      )) {
    _usage(
      'Verified upstream commits must contain canonical pinned/current SHAs.',
    );
  }
  return value.cast<String, String>();
}

final class _HighRiskPolicy {
  const _HighRiskPolicy({
    required this.compiledGrammarTests,
    required this.structuredOutputParityDependencies,
  });

  final Set<String> compiledGrammarTests;
  final Set<String> structuredOutputParityDependencies;
}

_HighRiskPolicy _decodeHighRiskPolicy(Object? value) {
  if (value is! Map<String, dynamic> ||
      value['schema'] != 1 ||
      value.keys.toSet().difference(const {
        'schema',
        'compiledGrammarTests',
        'structuredOutputParityDependencies',
      }).isNotEmpty ||
      value['compiledGrammarTests'] is! List ||
      (value['compiledGrammarTests'] as List).any((item) => item is! String) ||
      value['structuredOutputParityDependencies'] is! List ||
      (value['structuredOutputParityDependencies'] as List).any(
        (item) => item is! String,
      )) {
    _usage('Compiled grammar policy is malformed.');
  }
  final paths = (value['compiledGrammarTests'] as List).cast<String>();
  if (paths.isEmpty ||
      paths.toSet().length != paths.length ||
      paths.any(
        (path) =>
            path.isEmpty ||
            path.trim() != path ||
            !path.startsWith('test/') ||
            !path.endsWith('_test.dart'),
      )) {
    _usage('Compiled grammar policy requires unique test paths.');
  }
  final parityDependencies =
      (value['structuredOutputParityDependencies'] as List).cast<String>();
  if (parityDependencies.isEmpty ||
      parityDependencies.toSet().length != parityDependencies.length ||
      parityDependencies.any((path) => path.isEmpty || path.trim() != path)) {
    _usage('Structured-output parity dependencies must be unique exact paths.');
  }
  return _HighRiskPolicy(
    compiledGrammarTests: paths.toSet(),
    structuredOutputParityDependencies: parityDependencies.toSet(),
  );
}

List<HighRiskCiRun> _decodeCiRuns(Object? value) {
  if (value is! Map<String, dynamic> || value['workflow_runs'] is! List) {
    _usage('CI runs payload must contain workflow_runs.');
  }
  return (value['workflow_runs'] as List)
      .map((item) {
        if (item is! Map<String, dynamic>) {
          _usage('Every CI run must be an object.');
        }
        if (item['id'] is! int ||
            item['run_attempt'] is! int ||
            item['head_sha'] is! String ||
            item['event'] is! String ||
            item['path'] is! String ||
            item['status'] is! String ||
            (item['conclusion'] != null && item['conclusion'] is! String)) {
          _usage('CI run fields are malformed.');
        }
        return HighRiskCiRun(
          id: item['id'] as int,
          runAttempt: item['run_attempt'] as int,
          headSha: item['head_sha'] as String,
          event: item['event'] as String,
          path: item['path'] as String,
          status: item['status'] as String,
          conclusion: item['conclusion'] as String?,
          pullRequests: _decodeCiRunPullRequests(item['pull_requests']),
        );
      })
      .toList(growable: false);
}

List<HighRiskCiPullRequest> _decodeCiRunPullRequests(Object? value) {
  if (value is! List) _usage('CI run pull_requests must be a list.');
  return value
      .map((item) {
        if (item is! Map<String, dynamic> ||
            item['number'] is! int ||
            item['head'] is! Map<String, dynamic> ||
            item['base'] is! Map<String, dynamic>) {
          _usage('CI run pull request association is malformed.');
        }
        final head = item['head'] as Map<String, dynamic>;
        final base = item['base'] as Map<String, dynamic>;
        final repo = head['repo'];
        final repoUrl = repo is Map<String, dynamic> ? repo['url'] : null;
        final uri = repoUrl is String ? Uri.tryParse(repoUrl) : null;
        final segments = uri?.pathSegments
            .where((part) => part.isNotEmpty)
            .toList();
        if (head['sha'] is! String ||
            base['sha'] is! String ||
            segments == null ||
            segments.length < 3 ||
            segments[segments.length - 3] != 'repos') {
          _usage('CI run pull request association is malformed.');
        }
        return HighRiskCiPullRequest(
          number: item['number'] as int,
          headSha: head['sha'] as String,
          baseSha: base['sha'] as String,
          headRepository:
              '${segments[segments.length - 2]}/${segments[segments.length - 1]}',
        );
      })
      .toList(growable: false);
}
