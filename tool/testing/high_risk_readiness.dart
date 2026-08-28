#!/usr/bin/env dart

import 'dart:convert';
import 'dart:io';

import 'classify_high_risk_changes.dart';

/// Overall decision reached by the repository-local evaluator.
enum ReadinessDecision {
  rejected,
  unverifiedPrerequisites,
  standardRiskDiagnostic,
}

/// Stable failure classification emitted by the evaluator.
enum ReadinessFailureClassification {
  none,
  schemaViolation,
  repositoryMismatch,
  prMismatch,
  headMismatch,
  baseMismatch,
  authorMismatch,
  classificationMismatch,
  changedFilesMismatch,
  selfApprovalProhibited,
  retiredQaProfileProhibited,
  unresolvedReviewThreads,
  knownP1Regressions,
  missingAudit,
  auditRejected,
  missingRequiredMatrixRow,
  matrixRowFailed,
  missingStructuredOutputEvidence,
  missingTestPath,
  nonTestPathCited,
  unchangedEvidencePath,
  deletedEvidencePath,
  renamedEvidencePath,
  externalPrerequisitesUnavailable,
  gitExecutionError,
  invalidInput,
}

/// Git change kind used to bind evidence to the exact candidate diff.
enum RepositoryChangeKind {
  added,
  modified,
  deleted,
  renamed,
  copied,
  typeChanged,
  unmerged,
  unknown,
}

/// One path in the exact base-to-head repository inventory.
class RepositoryChange {
  const RepositoryChange({
    required this.path,
    required this.kind,
    this.previousPath,
  });

  final String path;
  final RepositoryChangeKind kind;
  final String? previousPath;

  Map<String, Object?> toJson() => <String, Object?>{
    'path': path,
    'status': kind.name,
    if (previousPath != null) 'previous_path': previousPath,
  };
}

/// Exact pull-request state supplied independently from the evidence payload.
class PullRequestContext {
  const PullRequestContext({
    required this.repository,
    required this.prNumber,
    required this.headSha,
    required this.baseSha,
    required this.author,
  });

  final String repository;
  final int prNumber;
  final String headSha;
  final String baseSha;
  final String author;
}

/// Read-only repository operations needed by the evaluator.
abstract interface class RepositoryStateReader {
  Future<bool> commitExists(String sha, {String? workingDirectory});

  Future<bool> isAncestor(
    String ancestor,
    String descendant, {
    String? workingDirectory,
  });

  Future<List<RepositoryChange>> changedFiles(
    String baseSha,
    String headSha, {
    String? workingDirectory,
  });

  Future<bool> pathIsRegularFileAt(
    String headSha,
    String path, {
    String? workingDirectory,
  });
}

/// Function signature for non-shell Git command execution.
typedef GitRunner =
    Future<ProcessResult> Function(
      List<String> args, {
      String? workingDirectory,
    });

Future<ProcessResult> _defaultGitRunner(
  List<String> args, {
  String? workingDirectory,
}) => Process.run(
  'git',
  args,
  workingDirectory: workingDirectory,
  stdoutEncoding: utf8,
  stderrEncoding: utf8,
);

/// Repository state reader backed by direct, non-shell Git invocations.
class GitRepositoryStateReader implements RepositoryStateReader {
  const GitRepositoryStateReader({this.gitRunner = _defaultGitRunner});

  final GitRunner gitRunner;

  @override
  Future<bool> commitExists(String sha, {String? workingDirectory}) async {
    final result = await gitRunner(<String>[
      'cat-file',
      '-e',
      '$sha^{commit}',
    ], workingDirectory: workingDirectory);
    return result.exitCode == 0;
  }

  @override
  Future<bool> isAncestor(
    String ancestor,
    String descendant, {
    String? workingDirectory,
  }) async {
    final result = await gitRunner(<String>[
      'merge-base',
      '--is-ancestor',
      ancestor,
      descendant,
    ], workingDirectory: workingDirectory);
    if (result.exitCode == 0) return true;
    if (result.exitCode == 1) return false;
    throw StateError('git merge-base failed with exit ${result.exitCode}');
  }

  @override
  Future<List<RepositoryChange>> changedFiles(
    String baseSha,
    String headSha, {
    String? workingDirectory,
  }) async {
    final result = await gitRunner(<String>[
      'diff',
      '--name-status',
      '-z',
      '--find-renames',
      '--no-ext-diff',
      '--no-textconv',
      '$baseSha...$headSha',
    ], workingDirectory: workingDirectory);
    if (result.exitCode != 0) {
      throw StateError('git diff failed with exit ${result.exitCode}');
    }
    if (result.stdout is! String) {
      throw StateError('git diff did not return text output');
    }
    return parseGitNameStatus(result.stdout as String);
  }

  @override
  Future<bool> pathIsRegularFileAt(
    String headSha,
    String path, {
    String? workingDirectory,
  }) async {
    final result = await gitRunner(<String>[
      'ls-tree',
      '-z',
      '--full-tree',
      headSha,
      '--',
      ':(top,literal)$path',
    ], workingDirectory: workingDirectory);
    if (result.exitCode != 0) {
      throw StateError('git ls-tree failed with exit ${result.exitCode}');
    }
    if (result.stdout is! String) {
      throw StateError('git ls-tree did not return text output');
    }
    final output = result.stdout as String;
    if (output.isEmpty) return false;
    if (!output.endsWith('\u0000')) {
      throw const FormatException('Malformed git ls-tree output.');
    }
    final records = output.substring(0, output.length - 1).split('\u0000');
    if (records.length != 1) return false;
    final separator = records.single.indexOf('\t');
    if (separator < 0) {
      throw const FormatException('Malformed git ls-tree record.');
    }
    final metadata = records.single.substring(0, separator);
    final actualPath = records.single.substring(separator + 1);
    return actualPath == path &&
        RegExp(r'^(100644|100755) blob [0-9a-f]+$').hasMatch(metadata);
  }
}

/// Parses NUL-delimited `git diff --name-status -z --find-renames` output.
List<RepositoryChange> parseGitNameStatus(String output) {
  if (output.isEmpty) return const <RepositoryChange>[];
  if (!output.endsWith('\u0000')) {
    throw const FormatException(
      'Git name-status output is not NUL-terminated.',
    );
  }
  final fields = output.substring(0, output.length - 1).split('\u0000');
  final changes = <RepositoryChange>[];
  var offset = 0;
  while (offset < fields.length) {
    final status = fields[offset++];
    final scoredStatus = RegExp(r'^([RC])(\d{1,3})$').firstMatch(status);
    final code = scoredStatus?.group(1) ?? status;
    if (scoredStatus != null && int.parse(scoredStatus.group(2)!) > 100) {
      throw FormatException('Invalid Git similarity score: $status');
    }
    if (scoredStatus == null && !RegExp(r'^[A-Z]$').hasMatch(status)) {
      throw FormatException('Malformed Git change status: $status');
    }
    if (code == 'R' || code == 'C') {
      if (offset + 1 >= fields.length ||
          fields[offset].isEmpty ||
          fields[offset + 1].isEmpty) {
        throw FormatException('Malformed Git $status name-status record.');
      }
      changes.add(
        RepositoryChange(
          path: fields[offset + 1],
          previousPath: fields[offset],
          kind: code == 'R'
              ? RepositoryChangeKind.renamed
              : RepositoryChangeKind.copied,
        ),
      );
      offset += 2;
      continue;
    }
    if (offset >= fields.length || fields[offset].isEmpty) {
      throw FormatException('Malformed Git $status name-status record.');
    }
    final kind = switch (code) {
      'A' => RepositoryChangeKind.added,
      'M' => RepositoryChangeKind.modified,
      'D' => RepositoryChangeKind.deleted,
      'T' => RepositoryChangeKind.typeChanged,
      'U' => RepositoryChangeKind.unmerged,
      _ => RepositoryChangeKind.unknown,
    };
    changes.add(RepositoryChange(path: fields[offset++], kind: kind));
  }
  return changes;
}

/// Strictly decodes a JSON object, rejecting duplicate object keys.
Map<String, dynamic> decodeStrictJsonObject(String source) {
  _DuplicateKeyScanner(source).scan();
  final decoded = jsonDecode(source);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Evidence JSON must be an object.');
  }
  return decoded;
}

class _DuplicateKeyScanner {
  _DuplicateKeyScanner(this.source);

  final String source;
  var _offset = 0;

  void scan() {
    _skipWhitespace();
    _scanValue();
    _skipWhitespace();
    if (_offset != source.length) {
      throw FormatException(
        'Unexpected trailing JSON content.',
        source,
        _offset,
      );
    }
  }

  void _scanValue() {
    _skipWhitespace();
    if (_offset >= source.length) {
      throw FormatException('Unexpected end of JSON.', source, _offset);
    }
    switch (source.codeUnitAt(_offset)) {
      case 0x7b:
        _scanObject();
      case 0x5b:
        _scanArray();
      case 0x22:
        _scanString();
      default:
        _scanPrimitive();
    }
  }

  void _scanObject() {
    _offset++;
    _skipWhitespace();
    final keys = <String>{};
    if (_consume(0x7d)) return;
    while (true) {
      _skipWhitespace();
      if (_offset >= source.length || source.codeUnitAt(_offset) != 0x22) {
        throw FormatException('Expected JSON object key.', source, _offset);
      }
      final key = _scanString();
      if (!keys.add(key)) {
        throw FormatException(
          'Duplicate JSON object key "$key".',
          source,
          _offset,
        );
      }
      _skipWhitespace();
      if (!_consume(0x3a)) {
        throw FormatException(
          'Expected colon after object key.',
          source,
          _offset,
        );
      }
      _scanValue();
      _skipWhitespace();
      if (_consume(0x7d)) return;
      if (!_consume(0x2c)) {
        throw FormatException(
          'Expected comma in JSON object.',
          source,
          _offset,
        );
      }
    }
  }

  void _scanArray() {
    _offset++;
    _skipWhitespace();
    if (_consume(0x5d)) return;
    while (true) {
      _scanValue();
      _skipWhitespace();
      if (_consume(0x5d)) return;
      if (!_consume(0x2c)) {
        throw FormatException('Expected comma in JSON array.', source, _offset);
      }
    }
  }

  String _scanString() {
    final start = _offset;
    _offset++;
    var escaped = false;
    while (_offset < source.length) {
      final unit = source.codeUnitAt(_offset++);
      if (escaped) {
        escaped = false;
      } else if (unit == 0x5c) {
        escaped = true;
      } else if (unit == 0x22) {
        return jsonDecode(source.substring(start, _offset)) as String;
      }
    }
    throw FormatException('Unterminated JSON string.', source, start);
  }

  void _scanPrimitive() {
    final start = _offset;
    while (_offset < source.length) {
      final unit = source.codeUnitAt(_offset);
      if (unit == 0x2c || unit == 0x5d || unit == 0x7d || _isWhitespace(unit)) {
        break;
      }
      _offset++;
    }
    if (_offset == start) {
      throw FormatException('Expected JSON value.', source, _offset);
    }
  }

  bool _consume(int unit) {
    if (_offset < source.length && source.codeUnitAt(_offset) == unit) {
      _offset++;
      return true;
    }
    return false;
  }

  void _skipWhitespace() {
    while (_offset < source.length &&
        _isWhitespace(source.codeUnitAt(_offset))) {
      _offset++;
    }
  }

  static bool _isWhitespace(int unit) =>
      unit == 0x20 || unit == 0x09 || unit == 0x0a || unit == 0x0d;
}

/// Structured evaluation result. Its JSON shape is the canonical schema root.
class HighRiskReadinessResult {
  const HighRiskReadinessResult({
    required this.evidence,
    required this.evaluatedAt,
    required this.changedFiles,
    required this.decision,
    required this.failureClassification,
    required this.message,
  });

  static const schema = 'llamadart.high-risk-readiness-evidence';
  static const schemaVersion = '1.0.0';

  final Map<String, Object?> evidence;
  final DateTime evaluatedAt;
  final List<RepositoryChange> changedFiles;
  final ReadinessDecision decision;
  final ReadinessFailureClassification failureClassification;
  final String message;

  /// Repository-local evaluation never represents operational merge readiness.
  bool get isReady => false;

  Map<String, Object?> toJson() => <String, Object?>{
    ...evidence,
    'evaluation': <String, Object?>{
      'evaluated_at': evaluatedAt.toUtc().toIso8601String(),
      'changed_files': changedFiles.map((change) => change.toJson()).toList(),
      'decision': decision.name,
      'failure_classification': failureClassification.name,
      'message': message,
      'external_prerequisites': const <String, Object?>{
        'app_installed': false,
        'protected_environment_configured': false,
        'independent_auditor_authenticated': false,
        'ruleset_enforced': false,
        'diagnostic_message':
            'No repository-local input can authenticate the dedicated GitHub App, protected environment, independent auditor, or conditional ruleset. See doc/high_risk_pre_merge_readiness.md.',
      },
    },
  };

  String toFormattedJson() =>
      const JsonEncoder.withIndent('  ').convert(toJson());
}

/// Evaluates evidence against an independently supplied PR context and Git tree.
class HighRiskReadinessEvaluator {
  const HighRiskReadinessEvaluator({
    this.repositoryState = const GitRepositoryStateReader(),
    this.clock = _defaultClock,
  });

  final RepositoryStateReader repositoryState;
  final DateTime Function() clock;

  static DateTime _defaultClock() => DateTime.now();
  static const _zeroSha = '0000000000000000000000000000000000000000';
  static const _rootKeys = <String>{
    'schema',
    'schema_version',
    'timestamp',
    'correlation_id',
    'repository',
    'pr_number',
    'expected_pr_head_sha',
    'current_base_sha',
    'pr_author',
    'classification',
    'surfaces',
    'required_matrix_row_ids',
    'matrix_row_evidence',
    'independent_audit',
    'structured_output_evidence',
    'affected_test_paths',
    'evaluation',
  };
  static const _auditKeys = <String>{
    'auditor_identity',
    'audit_kind',
    'audit_head_sha',
    'audit_base_sha',
    'decision',
    'unresolved_review_threads',
    'known_pr_caused_p1_regressions',
    'summary',
  };
  static const _matrixKeys = <String>{
    'row_id',
    'result',
    'command',
    'evidence_notes',
  };
  static const _knownMatrixRows = <String>{
    'high-risk-exact-head-independent-qa',
    'structured-output-adversarial',
  };
  static const _structuredKeys = <String>{'coverage', 'families'};
  static const _coverageAxes = <String>{
    'compiled_grammar_acceptance',
    'compiled_grammar_rejection',
    'schema_reconstruction',
    'streaming_rollback',
    'tool_choice_thinking',
    'upstream_parity',
  };
  static const _familyKeys = <String>{
    'family',
    'status',
    'evidence_test_paths',
    'rationale',
  };
  static const _knownCompiledGrammarTests = <String>{
    'test/integration/core/grammar/generated_tool_schema_grammar_test.dart',
    'test/e2e/template/specialized_tool_grammar_validation_e2e_test.dart',
  };

  Future<HighRiskReadinessResult> evaluate({
    required Map<String, dynamic> evidence,
    required PullRequestContext context,
    String? workingDirectory,
  }) async {
    final evaluatedAt = clock().toUtc();
    final shapeError = _validateShape(evidence);
    final contextError = _validateContext(context);
    final outputEvidence = _safeOutputEvidence(
      evidence,
      context,
      evaluatedAt,
      preserveEvidence: shapeError == null && contextError == null,
    );

    HighRiskReadinessResult reject(
      ReadinessFailureClassification failure,
      String message, {
      List<RepositoryChange> changedFiles = const <RepositoryChange>[],
    }) => HighRiskReadinessResult(
      evidence: outputEvidence,
      evaluatedAt: evaluatedAt,
      changedFiles: changedFiles,
      decision: ReadinessDecision.rejected,
      failureClassification: failure,
      message: message,
    );

    if (shapeError != null) {
      return reject(ReadinessFailureClassification.schemaViolation, shapeError);
    }
    if (contextError != null) {
      return reject(ReadinessFailureClassification.invalidInput, contextError);
    }
    if (evidence['repository'] != context.repository) {
      return reject(
        ReadinessFailureClassification.repositoryMismatch,
        'Evidence repository does not match the independently supplied repository.',
      );
    }
    if (evidence['pr_number'] != context.prNumber) {
      return reject(
        ReadinessFailureClassification.prMismatch,
        'Evidence PR number does not match the independently supplied PR number.',
      );
    }
    if (evidence['expected_pr_head_sha'] != context.headSha) {
      return reject(
        ReadinessFailureClassification.headMismatch,
        'Evidence head SHA does not match the independently observed PR head.',
      );
    }
    if (evidence['current_base_sha'] != context.baseSha) {
      return reject(
        ReadinessFailureClassification.baseMismatch,
        'Evidence base SHA does not match the independently observed PR base.',
      );
    }
    if ((evidence['pr_author'] as String).toLowerCase() !=
        context.author.toLowerCase()) {
      return reject(
        ReadinessFailureClassification.authorMismatch,
        'Evidence PR author does not match the independently observed PR author.',
      );
    }

    late final List<RepositoryChange> changedFiles;
    try {
      if (!await repositoryState.commitExists(
            context.baseSha,
            workingDirectory: workingDirectory,
          ) ||
          !await repositoryState.commitExists(
            context.headSha,
            workingDirectory: workingDirectory,
          )) {
        return reject(
          ReadinessFailureClassification.gitExecutionError,
          'The exact base and head commits must both exist in the local object database.',
        );
      }
      if (!await repositoryState.isAncestor(
        context.baseSha,
        context.headSha,
        workingDirectory: workingDirectory,
      )) {
        return reject(
          ReadinessFailureClassification.baseMismatch,
          'The independently observed base is not an ancestor of the PR head.',
        );
      }
      changedFiles = await repositoryState.changedFiles(
        context.baseSha,
        context.headSha,
        workingDirectory: workingDirectory,
      );
    } on Object {
      return reject(
        ReadinessFailureClassification.gitExecutionError,
        'Git could not build the exact base-to-head changed-file inventory.',
      );
    }
    if (changedFiles.isEmpty) {
      return reject(
        ReadinessFailureClassification.changedFilesMismatch,
        'The exact base-to-head changed-file inventory is empty.',
      );
    }
    if (changedFiles.any((change) => !_isValidRepositoryChange(change)) ||
        changedFiles.map((change) => change.path).toSet().length !=
            changedFiles.length) {
      return reject(
        ReadinessFailureClassification.changedFilesMismatch,
        'The exact inventory contains a malformed or duplicate repository change.',
      );
    }
    if (changedFiles.any(
      (change) =>
          change.kind == RepositoryChangeKind.unknown ||
          change.kind == RepositoryChangeKind.unmerged,
    )) {
      return reject(
        ReadinessFailureClassification.changedFilesMismatch,
        'The exact inventory contains an unsupported or unmerged change status.',
        changedFiles: changedFiles,
      );
    }

    final classificationPaths = <String>[
      for (final change in changedFiles) ...<String>[
        change.path,
        if (change.previousPath != null) change.previousPath!,
      ],
    ];
    final assessment = assessHighRiskFiles(classificationPaths);
    final declaredClassification = evidence['classification'] as String;
    if (assessment.isHighRisk != (declaredClassification == 'high-risk')) {
      return reject(
        ReadinessFailureClassification.classificationMismatch,
        'Declared classification does not match the exact changed-file inventory.',
        changedFiles: changedFiles,
      );
    }
    if (!assessment.isHighRisk) {
      final standardError = _validateStandardEvidence(evidence);
      if (standardError != null) {
        return reject(
          ReadinessFailureClassification.schemaViolation,
          standardError,
          changedFiles: changedFiles,
        );
      }
      return HighRiskReadinessResult(
        evidence: outputEvidence,
        evaluatedAt: evaluatedAt,
        changedFiles: changedFiles,
        decision: ReadinessDecision.standardRiskDiagnostic,
        failureClassification: ReadinessFailureClassification.none,
        message:
            'The exact diff is standard risk. This diagnostic is not an operational required-check qualification.',
      );
    }

    final declaredSurfaces = (evidence['surfaces'] as List<dynamic>)
        .cast<String>()
        .toSet();
    final actualSurfaces = assessment.surfaces
        .map((surface) => surface.name)
        .toSet();
    if (!_sameSet(declaredSurfaces, actualSurfaces)) {
      return reject(
        ReadinessFailureClassification.classificationMismatch,
        'Declared surfaces must exactly match classified surfaces: ${_sorted(actualSurfaces).join(', ')}.',
        changedFiles: changedFiles,
      );
    }

    const baselineRow = 'high-risk-exact-head-independent-qa';
    const structuredRow = 'structured-output-adversarial';
    final requiredRows = <String>{baselineRow};
    if (actualSurfaces.contains(HighRiskSurface.structuredOutput.name)) {
      requiredRows.add(structuredRow);
    }
    final declaredRows = (evidence['required_matrix_row_ids'] as List<dynamic>)
        .cast<String>()
        .toSet();
    if (!_sameSet(declaredRows, requiredRows)) {
      return reject(
        ReadinessFailureClassification.missingRequiredMatrixRow,
        'Required matrix rows must exactly match: ${_sorted(requiredRows).join(', ')}.',
        changedFiles: changedFiles,
      );
    }
    final matrixEvidence =
        evidence['matrix_row_evidence'] as Map<String, dynamic>;
    if (!_sameSet(matrixEvidence.keys.toSet(), requiredRows)) {
      return reject(
        ReadinessFailureClassification.missingRequiredMatrixRow,
        'Matrix evidence keys must exactly match required matrix row IDs.',
        changedFiles: changedFiles,
      );
    }
    for (final rowId in requiredRows) {
      final row = matrixEvidence[rowId] as Map<String, dynamic>;
      if (row['row_id'] != rowId || row['result'] != 'pass') {
        return reject(
          ReadinessFailureClassification.matrixRowFailed,
          'Required matrix row "$rowId" must identify itself and report pass.',
          changedFiles: changedFiles,
        );
      }
    }

    final audit = evidence['independent_audit'] as Map<String, dynamic>?;
    if (audit == null) {
      return reject(
        ReadinessFailureClassification.missingAudit,
        'High-risk changes require an independent audit object.',
        changedFiles: changedFiles,
      );
    }
    final auditor = audit['auditor_identity'] as String;
    if (auditor.toLowerCase() == context.author.toLowerCase()) {
      return reject(
        ReadinessFailureClassification.selfApprovalProhibited,
        'The independent auditor cannot be the PR author.',
        changedFiles: changedFiles,
      );
    }
    if (_isRetiredQaIdentity(auditor)) {
      return reject(
        ReadinessFailureClassification.retiredQaProfileProhibited,
        'The standalone qa identity is retired and cannot supply an audit.',
        changedFiles: changedFiles,
      );
    }
    if (audit['audit_head_sha'] != context.headSha) {
      return reject(
        ReadinessFailureClassification.headMismatch,
        'The audit is not bound to the exact PR head.',
        changedFiles: changedFiles,
      );
    }
    if (audit['audit_base_sha'] != context.baseSha) {
      return reject(
        ReadinessFailureClassification.baseMismatch,
        'The audit is not bound to the exact PR base.',
        changedFiles: changedFiles,
      );
    }
    if (audit['decision'] != 'accepted') {
      return reject(
        ReadinessFailureClassification.auditRejected,
        'The independent audit decision is not accepted.',
        changedFiles: changedFiles,
      );
    }
    if ((audit['unresolved_review_threads'] as int) != 0) {
      return reject(
        ReadinessFailureClassification.unresolvedReviewThreads,
        'Unresolved review threads remain.',
        changedFiles: changedFiles,
      );
    }
    if ((audit['known_pr_caused_p1_regressions'] as int) != 0) {
      return reject(
        ReadinessFailureClassification.knownP1Regressions,
        'Known PR-caused P1 regressions remain.',
        changedFiles: changedFiles,
      );
    }

    final changedByPath = <String, RepositoryChange>{
      for (final change in changedFiles) change.path: change,
    };
    final renamedPreviousPaths = <String>{
      for (final change in changedFiles)
        if (change.kind == RepositoryChangeKind.renamed) change.previousPath!,
    };
    final affectedPaths = (evidence['affected_test_paths'] as List<dynamic>)
        .cast<String>();
    if (affectedPaths.isEmpty) {
      return reject(
        ReadinessFailureClassification.missingTestPath,
        'High-risk evidence must cite at least one changed production test.',
        changedFiles: changedFiles,
      );
    }
    for (final path in affectedPaths) {
      late final (ReadinessFailureClassification, String)? pathFailure;
      try {
        pathFailure = await _validateEvidencePath(
          path,
          context.headSha,
          changedByPath,
          renamedPreviousPaths,
          workingDirectory: workingDirectory,
        );
      } on Object {
        return reject(
          ReadinessFailureClassification.gitExecutionError,
          'Git could not verify an evidence path in the exact candidate tree.',
          changedFiles: changedFiles,
        );
      }
      if (pathFailure != null) {
        return reject(
          pathFailure.$1,
          pathFailure.$2,
          changedFiles: changedFiles,
        );
      }
    }

    if (actualSurfaces.contains(HighRiskSurface.structuredOutput.name)) {
      final structured =
          evidence['structured_output_evidence'] as Map<String, dynamic>?;
      if (structured == null) {
        return reject(
          ReadinessFailureClassification.missingStructuredOutputEvidence,
          'Structured-output changes require structured evidence.',
          changedFiles: changedFiles,
        );
      }
      final coverage = structured['coverage'] as Map<String, dynamic>;
      for (final axis in _coverageAxes) {
        final paths = (coverage[axis] as List<dynamic>).cast<String>();
        for (final path in paths) {
          if (!affectedPaths.contains(path)) {
            return reject(
              ReadinessFailureClassification.unchangedEvidencePath,
              'Structured-output axis "$axis" cites a path outside affected_test_paths: $path.',
              changedFiles: changedFiles,
            );
          }
        }
      }
      for (final axis in const <String>{
        'compiled_grammar_acceptance',
        'compiled_grammar_rejection',
      }) {
        final paths = (coverage[axis] as List<dynamic>).cast<String>().toSet();
        if (paths.intersection(_knownCompiledGrammarTests).isEmpty) {
          return reject(
            ReadinessFailureClassification.missingStructuredOutputEvidence,
            'Structured-output axis "$axis" must cite a changed compiled production grammar test.',
            changedFiles: changedFiles,
          );
        }
      }
      final families = (structured['families'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      for (final family in families) {
        for (final path
            in (family['evidence_test_paths'] as List<dynamic>)
                .cast<String>()) {
          if (!affectedPaths.contains(path)) {
            return reject(
              ReadinessFailureClassification.unchangedEvidencePath,
              'Family evidence cites a path outside affected_test_paths: $path.',
              changedFiles: changedFiles,
            );
          }
        }
      }
    } else if (evidence['structured_output_evidence'] != null) {
      return reject(
        ReadinessFailureClassification.schemaViolation,
        'Non-structured changes must not declare structured_output_evidence.',
        changedFiles: changedFiles,
      );
    }

    return HighRiskReadinessResult(
      evidence: outputEvidence,
      evaluatedAt: evaluatedAt,
      changedFiles: changedFiles,
      decision: ReadinessDecision.unverifiedPrerequisites,
      failureClassification:
          ReadinessFailureClassification.externalPrerequisitesUnavailable,
      message:
          'Repository-local evidence is internally consistent, but auditor authentication, GitHub App publication, protected-environment provenance, and ruleset enforcement are not available. This is not operational merge readiness.',
    );
  }

  Future<(ReadinessFailureClassification, String)?> _validateEvidencePath(
    String path,
    String headSha,
    Map<String, RepositoryChange> changedByPath,
    Set<String> previousPaths, {
    String? workingDirectory,
  }) async {
    if (!_isProductionTestPath(path)) {
      return (
        ReadinessFailureClassification.nonTestPathCited,
        'Evidence path is not a repository-relative production test: $path.',
      );
    }
    if (previousPaths.contains(path)) {
      return (
        ReadinessFailureClassification.renamedEvidencePath,
        'Evidence cites the old side of a rename: $path.',
      );
    }
    final change = changedByPath[path];
    if (change == null) {
      return (
        ReadinessFailureClassification.unchangedEvidencePath,
        'Evidence path is not changed in the exact base-to-head inventory: $path.',
      );
    }
    if (change.kind == RepositoryChangeKind.deleted) {
      return (
        ReadinessFailureClassification.deletedEvidencePath,
        'Evidence path is deleted in the candidate: $path.',
      );
    }
    if (!await repositoryState.pathIsRegularFileAt(
      headSha,
      path,
      workingDirectory: workingDirectory,
    )) {
      return (
        ReadinessFailureClassification.missingTestPath,
        'Evidence path is not a regular file in the exact candidate tree: $path.',
      );
    }
    return null;
  }

  static String? _validateContext(PullRequestContext context) {
    if (!_isRepository(context.repository)) {
      return 'Independently supplied repository must use owner/repository form.';
    }
    if (context.prNumber < 1) {
      return 'Independently supplied PR number must be positive.';
    }
    if (!_isSha(context.headSha) || !_isSha(context.baseSha)) {
      return 'Independently supplied head and base must be nonzero lowercase SHA-1 values.';
    }
    if (!_isGitHubLogin(context.author)) {
      return 'Independently supplied PR author is invalid.';
    }
    return null;
  }

  static String? _validateShape(Map<String, dynamic> evidence) {
    final rootError = _exactKeys(evidence, _rootKeys, 'evidence');
    if (rootError != null) return rootError;
    if (evidence['schema'] != HighRiskReadinessResult.schema ||
        evidence['schema_version'] != HighRiskReadinessResult.schemaVersion) {
      return 'Unsupported evidence schema or schema_version.';
    }
    if (!_isUtcTimestamp(evidence['timestamp'])) {
      return 'timestamp must be a valid RFC 3339 UTC string.';
    }
    if (!_isIdentifier(evidence['correlation_id'])) {
      return 'correlation_id has an invalid type or form.';
    }
    if (!_isRepository(evidence['repository'])) {
      return 'repository must use owner/repository form.';
    }
    if (evidence['pr_number'] is! int || (evidence['pr_number'] as int) < 1) {
      return 'pr_number must be a positive integer.';
    }
    for (final field in ['expected_pr_head_sha', 'current_base_sha']) {
      if (!_isSha(evidence[field])) {
        return '$field must be a nonzero lowercase SHA-1.';
      }
    }
    if (!_isGitHubLogin(evidence['pr_author'])) return 'pr_author is invalid.';
    if (evidence['classification'] != 'standard' &&
        evidence['classification'] != 'high-risk') {
      return 'classification must be standard or high-risk.';
    }
    if (evidence['evaluation'] != null) {
      return 'Input evidence must set evaluation to null; decisions are evaluator-owned.';
    }
    final surfacesError = _stringList(
      evidence['surfaces'],
      'surfaces',
      allowed: HighRiskSurface.values.map((surface) => surface.name).toSet(),
    );
    if (surfacesError != null) return surfacesError;
    final rowsError = _stringList(
      evidence['required_matrix_row_ids'],
      'required_matrix_row_ids',
      allowed: _knownMatrixRows,
    );
    if (rowsError != null) return rowsError;
    final testsError = _stringList(
      evidence['affected_test_paths'],
      'affected_test_paths',
    );
    if (testsError != null) return testsError;

    final matrix = evidence['matrix_row_evidence'];
    if (matrix is! Map<String, dynamic>) {
      return 'matrix_row_evidence must be an object.';
    }
    for (final entry in matrix.entries) {
      if (!_knownMatrixRows.contains(entry.key)) {
        return 'matrix_row_evidence contains unknown row "${entry.key}".';
      }
      final row = entry.value;
      if (row is! Map<String, dynamic>) {
        return 'Matrix row ${entry.key} must be an object.';
      }
      final error = _exactKeys(row, _matrixKeys, 'matrix row ${entry.key}');
      if (error != null) return error;
      if (!_knownMatrixRows.contains(row['row_id']) ||
          !const {'pass', 'fail', 'notApplicable'}.contains(row['result']) ||
          !_isNonEmptyString(row['command']) ||
          !_isNonEmptyString(row['evidence_notes'])) {
        return 'Matrix row ${entry.key} has invalid field types or values.';
      }
    }

    final audit = evidence['independent_audit'];
    if (audit != null) {
      if (audit is! Map<String, dynamic>) {
        return 'independent_audit must be an object or null.';
      }
      final error = _exactKeys(audit, _auditKeys, 'independent_audit');
      if (error != null) return error;
      if (!_isIdentifier(audit['auditor_identity']) ||
          !const {
            'operator-owned',
            'codex-adversarial',
          }.contains(audit['audit_kind']) ||
          !_isSha(audit['audit_head_sha']) ||
          !_isSha(audit['audit_base_sha']) ||
          !const {
            'accepted',
            'rejected',
            'blocked',
          }.contains(audit['decision']) ||
          audit['unresolved_review_threads'] is! int ||
          (audit['unresolved_review_threads'] as int) < 0 ||
          audit['known_pr_caused_p1_regressions'] is! int ||
          (audit['known_pr_caused_p1_regressions'] as int) < 0 ||
          !_isNonEmptyString(audit['summary'])) {
        return 'independent_audit has invalid field types or values.';
      }
    }

    final structured = evidence['structured_output_evidence'];
    if (structured != null) {
      if (structured is! Map<String, dynamic>) {
        return 'structured_output_evidence must be an object or null.';
      }
      final error = _exactKeys(
        structured,
        _structuredKeys,
        'structured_output_evidence',
      );
      if (error != null) return error;
      final coverage = structured['coverage'];
      if (coverage is! Map<String, dynamic>) {
        return 'structured coverage must be an object.';
      }
      final coverageError = _exactKeys(
        coverage,
        _coverageAxes,
        'structured coverage',
      );
      if (coverageError != null) return coverageError;
      for (final axis in _coverageAxes) {
        final axisError = _stringList(
          coverage[axis],
          'coverage.$axis',
          requireNonEmpty: true,
        );
        if (axisError != null) return axisError;
      }
      final families = structured['families'];
      if (families is! List || families.isEmpty) {
        return 'structured families must be a non-empty list.';
      }
      final familyNames = <String>{};
      for (final value in families) {
        if (value is! Map<String, dynamic>) {
          return 'Each structured family must be an object.';
        }
        final familyError = _exactKeys(value, _familyKeys, 'structured family');
        if (familyError != null) return familyError;
        final family = value['family'];
        if (!_isIdentifier(family) || !familyNames.add(family as String)) {
          return 'Structured family names must be valid and unique.';
        }
        if (!const {'tested', 'unavailable'}.contains(value['status']) ||
            !_isNonEmptyString(value['rationale'])) {
          return 'Structured family status or rationale is invalid.';
        }
        final pathsError = _stringList(
          value['evidence_test_paths'],
          'family.evidence_test_paths',
          requireNonEmpty: true,
        );
        if (pathsError != null) return pathsError;
      }
    }
    return null;
  }

  static String? _validateStandardEvidence(Map<String, dynamic> evidence) {
    if ((evidence['surfaces'] as List<dynamic>).isNotEmpty ||
        (evidence['required_matrix_row_ids'] as List<dynamic>).isNotEmpty ||
        (evidence['matrix_row_evidence'] as Map<String, dynamic>).isNotEmpty ||
        evidence['independent_audit'] != null ||
        evidence['structured_output_evidence'] != null ||
        (evidence['affected_test_paths'] as List<dynamic>).isNotEmpty) {
      return 'Standard-risk evidence must not contain high-risk claims.';
    }
    return null;
  }

  static Map<String, Object?> _safeOutputEvidence(
    Map<String, dynamic> evidence,
    PullRequestContext context,
    DateTime now, {
    required bool preserveEvidence,
  }) {
    if (!preserveEvidence) {
      return <String, Object?>{
        'schema': HighRiskReadinessResult.schema,
        'schema_version': HighRiskReadinessResult.schemaVersion,
        'timestamp': now.toIso8601String(),
        'correlation_id': 'invalid-input',
        'repository': _isRepository(context.repository)
            ? context.repository
            : 'invalid/invalid',
        'pr_number': context.prNumber > 0 ? context.prNumber : 1,
        'expected_pr_head_sha': _isSha(context.headSha)
            ? context.headSha
            : 'ffffffffffffffffffffffffffffffffffffffff',
        'current_base_sha': _isSha(context.baseSha)
            ? context.baseSha
            : 'ffffffffffffffffffffffffffffffffffffffff',
        'pr_author': _isGitHubLogin(context.author)
            ? context.author
            : 'invalid-author',
        'classification': 'standard',
        'surfaces': const <String>[],
        'required_matrix_row_ids': const <String>[],
        'matrix_row_evidence': const <String, Object?>{},
        'independent_audit': null,
        'structured_output_evidence': null,
        'affected_test_paths': const <String>[],
      };
    }
    Object? safe(String key, Object? fallback) => evidence[key] ?? fallback;
    return <String, Object?>{
      'schema': HighRiskReadinessResult.schema,
      'schema_version': HighRiskReadinessResult.schemaVersion,
      'timestamp': _isUtcTimestamp(evidence['timestamp'])
          ? evidence['timestamp']
          : now.toIso8601String(),
      'correlation_id': _isIdentifier(evidence['correlation_id'])
          ? evidence['correlation_id']
          : 'invalid-input',
      'repository': _isRepository(evidence['repository'])
          ? evidence['repository']
          : context.repository,
      'pr_number':
          evidence['pr_number'] is int && (evidence['pr_number'] as int) > 0
          ? evidence['pr_number']
          : context.prNumber,
      'expected_pr_head_sha': _isSha(evidence['expected_pr_head_sha'])
          ? evidence['expected_pr_head_sha']
          : context.headSha,
      'current_base_sha': _isSha(evidence['current_base_sha'])
          ? evidence['current_base_sha']
          : context.baseSha,
      'pr_author': _isGitHubLogin(evidence['pr_author'])
          ? evidence['pr_author']
          : context.author,
      'classification':
          const {'standard', 'high-risk'}.contains(evidence['classification'])
          ? evidence['classification']
          : 'standard',
      'surfaces': safe('surfaces', const <String>[]),
      'required_matrix_row_ids': safe(
        'required_matrix_row_ids',
        const <String>[],
      ),
      'matrix_row_evidence': safe(
        'matrix_row_evidence',
        const <String, Object?>{},
      ),
      'independent_audit': evidence['independent_audit'],
      'structured_output_evidence': evidence['structured_output_evidence'],
      'affected_test_paths': safe('affected_test_paths', const <String>[]),
    };
  }

  static String? _exactKeys(
    Map<String, dynamic> value,
    Set<String> expected,
    String label,
  ) {
    final actual = value.keys.toSet();
    final missing = expected.difference(actual);
    final unknown = actual.difference(expected);
    if (missing.isNotEmpty) {
      return '$label is missing keys: ${_sorted(missing).join(', ')}.';
    }
    if (unknown.isNotEmpty) {
      return '$label has unknown keys: ${_sorted(unknown).join(', ')}.';
    }
    return null;
  }

  static String? _stringList(
    Object? value,
    String label, {
    Set<String>? allowed,
    bool requireNonEmpty = false,
  }) {
    if (value is! List) return '$label must be a list.';
    if (requireNonEmpty && value.isEmpty) return '$label must not be empty.';
    final strings = <String>[];
    for (final item in value) {
      if (!_isNonEmptyString(item)) {
        return '$label must contain only non-empty strings.';
      }
      strings.add(item as String);
      if (allowed != null && !allowed.contains(item)) {
        return '$label contains unknown value "$item".';
      }
    }
    if (strings.toSet().length != strings.length) {
      return '$label must not contain duplicates.';
    }
    return null;
  }

  static bool _isSha(Object? value) =>
      value is String &&
      value != _zeroSha &&
      RegExp(r'^[0-9a-f]{40}$').hasMatch(value);

  static bool _isRepository(Object? value) =>
      value is String &&
      RegExp(r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$').hasMatch(value);

  static bool _isGitHubLogin(Object? value) =>
      value is String &&
      RegExp(r'^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$').hasMatch(value) &&
      !value.endsWith('-') &&
      !value.contains('--');

  static bool _isIdentifier(Object? value) =>
      value is String &&
      RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:@-]{0,127}$').hasMatch(value);

  static bool _isNonEmptyString(Object? value) =>
      value is String && value.trim().isNotEmpty && value == value.trim();

  static bool _isUtcTimestamp(Object? value) {
    if (value is! String) {
      return false;
    }
    final match = RegExp(
      r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,6})?Z$',
    ).firstMatch(value);
    final parsed = DateTime.tryParse(value);
    if (match == null || parsed == null || !parsed.isUtc) return false;
    return parsed.year == int.parse(match.group(1)!) &&
        parsed.month == int.parse(match.group(2)!) &&
        parsed.day == int.parse(match.group(3)!) &&
        parsed.hour == int.parse(match.group(4)!) &&
        parsed.minute == int.parse(match.group(5)!) &&
        parsed.second == int.parse(match.group(6)!);
  }

  static bool _isProductionTestPath(String path) {
    if (path.startsWith('/') ||
        path.contains('\\') ||
        path.contains('*') ||
        path.contains('?') ||
        path.contains('[') ||
        path.contains(']') ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(path) ||
        path
            .split('/')
            .any((part) => part.isEmpty || part == '.' || part == '..')) {
      return false;
    }
    return path.startsWith('test/') && path.endsWith('_test.dart');
  }

  static bool _isValidRepositoryChange(RepositoryChange change) {
    if (change.path.isEmpty || change.path.contains('\u0000')) return false;
    final hasSource = change.previousPath != null;
    if (change.kind == RepositoryChangeKind.renamed ||
        change.kind == RepositoryChangeKind.copied) {
      return hasSource &&
          change.previousPath!.isNotEmpty &&
          !change.previousPath!.contains('\u0000') &&
          change.previousPath != change.path;
    }
    return !hasSource;
  }

  static bool _isRetiredQaIdentity(String identity) => RegExp(
    r'^(qa|qa[-_]agent|qa[-_]profile|qa[-_]task)$',
    caseSensitive: false,
  ).hasMatch(identity);

  static bool _sameSet<T>(Set<T> left, Set<T> right) =>
      left.length == right.length && left.containsAll(right);

  static List<String> _sorted(Iterable<String> values) =>
      values.toList()..sort();
}

String _usage() =>
    '''Usage: dart run tool/testing/high_risk_readiness.dart [options]

Required:
  --evidence <path>       Evidence JSON file, or - for stdin.
  --repository <owner/repo>
  --pr-number <number>
  --head-sha <sha>        Independently observed exact PR head.
  --base-sha <sha>        Independently observed exact PR base.
  --pr-author <login>     Independently observed PR author.

Other:
  --schema                Print the canonical schema.
  -h, --help              Show this help.

The CLI derives changed files and candidate-tree path existence from Git. It
never accepts App credentials or emits operational readiness.
''';

Future<void> main(List<String> args) async {
  if (args.contains('--help') || args.contains('-h')) {
    stdout.write(_usage());
    return;
  }
  if (args.length == 1 && args.single == '--schema') {
    final file = File('tool/testing/high_risk_readiness_evidence.schema.json');
    if (!file.existsSync()) {
      stderr.writeln('Schema file not found.');
      exitCode = 66;
      return;
    }
    stdout.write(file.readAsStringSync());
    return;
  }

  final values = <String, String>{};
  const valuedOptions = <String>{
    '--evidence',
    '--repository',
    '--pr-number',
    '--head-sha',
    '--base-sha',
    '--pr-author',
  };
  for (var i = 0; i < args.length; i++) {
    final option = args[i];
    if (!valuedOptions.contains(option) ||
        i + 1 >= args.length ||
        values.containsKey(option)) {
      stderr.writeln('Unknown, duplicate, or valueless option: $option');
      stdout.write(_usage());
      exitCode = 64;
      return;
    }
    values[option] = args[++i];
  }
  if (!values.keys.toSet().containsAll(valuedOptions)) {
    stderr.writeln('All required options must be supplied.');
    stdout.write(_usage());
    exitCode = 64;
    return;
  }

  final prNumber = int.tryParse(values['--pr-number']!);
  if (prNumber == null || prNumber < 1) {
    stderr.writeln('--pr-number must be a positive integer.');
    exitCode = 64;
    return;
  }
  late final String source;
  try {
    source = values['--evidence'] == '-'
        ? await stdin.transform(utf8.decoder).join()
        : await File(values['--evidence']!).readAsString();
  } on Object catch (error) {
    stderr.writeln('Could not read evidence: $error');
    exitCode = 66;
    return;
  }
  late final Map<String, dynamic> evidence;
  try {
    evidence = decodeStrictJsonObject(source);
  } on Object catch (error) {
    stderr.writeln('Invalid evidence JSON: $error');
    exitCode = 65;
    return;
  }

  final result = await const HighRiskReadinessEvaluator().evaluate(
    evidence: evidence,
    context: PullRequestContext(
      repository: values['--repository']!,
      prNumber: prNumber,
      headSha: values['--head-sha']!,
      baseSha: values['--base-sha']!,
      author: values['--pr-author']!,
    ),
  );
  stdout.writeln(result.toFormattedJson());
  exitCode = switch (result.decision) {
    ReadinessDecision.standardRiskDiagnostic => 0,
    ReadinessDecision.rejected => 1,
    ReadinessDecision.unverifiedPrerequisites => 2,
  };
}
