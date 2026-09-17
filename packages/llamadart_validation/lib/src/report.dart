import 'dart:convert';
import 'dart:math' as math;

import 'manifest.dart';
import 'placement.dart';

/// Validates the event journal and produces all report formats from one source.
class ValidationReport {
  ValidationReport._(
    this.manifest,
    this.cases,
    this.problems,
    this.finished,
    this.cleanupPassed,
    this.placement,
  );

  final Map<String, dynamic> manifest;
  final List<Map<String, dynamic>> cases;
  final List<String> problems;
  final bool finished;
  final bool cleanupPassed;
  final Map<String, dynamic> placement;

  /// Truncated, duplicate and missing records cannot become passing reports.
  factory ValidationReport.parse(String jsonl, {String? nativeLog}) {
    final problems = <String>[];
    final events = <Map<String, dynamic>>[];
    var lineNumber = 0;
    for (final line in const LineSplitter().convert(jsonl)) {
      lineNumber++;
      if (line.trim().isEmpty) continue;
      try {
        events.add(jsonDecode(line) as Map<String, dynamic>);
      } catch (_) {
        problems.add('Invalid JSON event at line $lineNumber');
      }
    }
    final manifests = events.where((e) => e['type'] == 'manifest').toList();
    if (manifests.length != 1) problems.add('Expected exactly one manifest');
    final manifest = manifests.isEmpty ? <String, dynamic>{} : manifests.first;
    if (manifest['schema_version'] != 1) {
      problems.add('Unsupported result schema');
    }
    if (manifest['profile_hash'] != jsonHash(manifest['profile'])) {
      problems.add('Profile hash does not match the manifest');
    }
    if (manifest['config_hash'] != jsonHash(manifest['effective_config'])) {
      problems.add('Effective configuration hash does not match');
    }
    ValidationProfile? profile;
    try {
      profile = ValidationProfile.fromJson(
        manifest['profile'] as Map<String, dynamic>,
      );
    } catch (_) {
      problems.add('Invalid validation profile');
    }
    final inventory = manifest['case_ids'];
    final declared = inventory is List
        ? inventory.whereType<String>().toList()
        : <String>[];
    if (inventory is! List || declared.length != inventory.length) {
      problems.add('Malformed case inventory');
    }
    if (profile != null) {
      if (canonicalJson(inventory) != canonicalJson(profile.caseIds)) {
        problems.add('Case inventory does not match the profile');
      }
      if (canonicalJson(manifest['effective_config']) !=
          canonicalJson(profile.effectiveConfig)) {
        problems.add('Effective configuration does not match the profile');
      }
      if (manifest['accelerator_evidence_required'] !=
          profile.requiresAcceleratorProof) {
        problems.add(
          'Accelerator evidence requirement does not match the profile',
        );
      }
    }
    final expected = profile?.caseIds ?? declared;
    var sequence = 0;
    for (var index = 0; index < events.length; index++) {
      final event = events[index];
      if (event['type'] == 'manifest') {
        if (index != 0) problems.add('Manifest must be first');
        continue;
      }
      if (![
        'case_start',
        'case',
        'cleanup',
        'run_end',
      ].contains(event['type'])) {
        problems.add('Unknown event type');
      }
      if (event['sequence'] != sequence++) {
        problems.add('Event sequence mismatch');
      }
      if (event['type'] == 'run_end' && index != events.length - 1) {
        problems.add('Records follow run end');
      }
    }
    if (expected.isEmpty || expected.toSet().length != expected.length) {
      problems.add('Invalid mandatory case inventory');
    }
    final records = <String, Map<String, dynamic>>{};
    for (final event in events.where((e) => e['type'] == 'case')) {
      final id = event['case_id'];
      if (id is! String || !expected.contains(id)) {
        problems.add('Unexpected case record: $id');
        continue;
      }
      if (records.containsKey(id)) {
        problems.add('Duplicate terminal record: $id');
      }
      if (!const [
        'PASS',
        'FAIL',
        'ERROR',
        'NOT_RUN',
        'UNSUPPORTED',
      ].contains(event['status'])) {
        problems.add('Invalid terminal status: $id');
      }
      records.putIfAbsent(id, () => event);
    }
    for (final id in expected) {
      if (!records.containsKey(id)) {
        problems.add('Missing mandatory case: $id');
        records[id] = {
          'type': 'case',
          'case_id': id,
          'status': 'NOT_RUN',
          'reason': 'missing terminal record after crash/interruption',
        };
      }
    }
    final endings = events.where((e) => e['type'] == 'run_end').toList();
    final finished =
        endings.length == 1 && endings.single['cancelled'] == false;
    if (!finished) problems.add('Run did not complete normally');
    final cleanups = events.where((e) => e['type'] == 'cleanup').toList();
    final cleanup = cleanups.length == 1 && cleanups.single['status'] == 'PASS';
    if (!cleanup) problems.add('Engine cleanup did not complete');
    return ValidationReport._(
      manifest,
      [for (final id in expected) records[id]!],
      problems,
      finished,
      cleanup,
      inspectPlacement(manifest, [
        for (final id in expected) records[id]!,
      ], nativeLog),
    );
  }

  /// True only for complete mandatory functional obligations.
  bool get assertionsPassed =>
      problems.isEmpty &&
      cases.isNotEmpty &&
      // The current catalog has no allowed unsupported exemptions. A producer
      // cannot grant itself one through an expected_unsupported event field.
      cases.every((e) => e['status'] == 'PASS');

  /// Public selector values alone never qualify an accelerator.
  bool get acceleratorVerified => placement['verified'] == true;

  /// Missing or uncommitted build identity preserves results but cannot qualify.
  List<String> get provenanceProblems {
    final environment = manifest['environment'] is Map
        ? manifest['environment'] as Map
        : const {};
    final runtime = manifest['profile'] is Map
        ? (manifest['profile'] as Map)['runtime']
        : null;
    final tag = environment[runtime == 'litert' ? 'litert_tag' : 'native_tag'];
    return [
      if (!RegExp(
        r'^[a-f0-9]{40}$',
      ).hasMatch('${environment['source_commit']}'))
        'Source commit is missing or unknown',
      if (environment['source_dirty'] != false)
        'Build source is dirty or its cleanliness is unknown',
      if (!RegExp(r'^[a-f0-9]{64}$').hasMatch('${environment['hook_sha256']}'))
        'Native hook identity is missing or unknown',
      if (tag is! String || tag.isEmpty || tag == 'unknown')
        'Runtime artifact pin is missing or unknown',
      if (environment['web'] == true &&
          (environment['bridge_tag'] == null ||
              environment['bridge_tag'] == 'unknown'))
        'Web runtime artifact pin is missing or unknown',
    ];
  }

  /// Overall qualification requires correctness, backend proof and provenance.
  bool get qualified =>
      assertionsPassed && acceleratorVerified && provenanceProblems.isEmpty;

  Map<String, dynamic> toJson() => {
    'schema_version': 1,
    'manifest': manifest,
    'cases': cases,
    'summary': {
      'qualified': qualified,
      'assertions_passed': assertionsPassed,
      'accelerator_verified': acceleratorVerified,
      'accelerator_evidence': placement,
      'provenance_complete': provenanceProblems.isEmpty,
      'provenance_problems': provenanceProblems,
      'expected': cases.length,
      for (final status in ['PASS', 'FAIL', 'ERROR', 'NOT_RUN', 'UNSUPPORTED'])
        status: cases.where((c) => c['status'] == status).length,
      'problems': problems,
    },
  };

  /// A failing integrity case preserves crash/collection failures in JUnit.
  String toJUnit() {
    final errors =
        cases.where((c) => c['status'] == 'ERROR').length + (qualified ? 0 : 1);
    final xml = StringBuffer(
      '<testsuite name="llamadart-validation" tests="${cases.length + (qualified ? 0 : 1)}" failures="${cases.where((c) => c['status'] == 'FAIL').length}" errors="$errors">',
    );
    for (final record in cases) {
      xml.write(
        '<testcase name="${_escape(record['case_id'])}" time="${((record['elapsed_ms'] as num? ?? 0) / 1000)}">',
      );
      final status = record['status'];
      final content = _escape(jsonEncode(record));
      if (status == 'FAIL') {
        xml.write('<failure message="assertion failed">$content</failure>');
      }
      if (status == 'ERROR') {
        xml.write('<error message="runtime error">$content</error>');
      }
      if (status == 'NOT_RUN' || status == 'UNSUPPORTED') {
        xml.write('<skipped message="$content"/>');
      }
      xml.write('<system-out>$content</system-out></testcase>');
    }
    if (!qualified) {
      xml.write(
        '<testcase name="run-integrity"><error>${_escape([...problems, ...provenanceProblems, if (!assertionsPassed) 'Mandatory assertions incomplete or failed', if (!acceleratorVerified) 'Accelerator execution not verified'].join('; '))}</error></testcase>',
      );
    }
    xml.write('</testsuite>');
    return xml.toString();
  }

  /// Measured repetitions only; warm-ups are excluded from comparisons.
  List<Map<String, dynamic>> get samples => cases
      .where((c) => c['benchmark'] == true && c['warmup'] == false)
      .toList();

  String toCsv() {
    const metrics = [
      'wall_ms',
      'ttfa_ms',
      'estimated_wall_tps',
      'native_decode_tps',
    ];
    String cell(Object? value) =>
        '"${(value ?? '').toString().replaceAll('"', '""')}"';
    return [
      ['run_id', 'case_id', 'status', ...metrics].join(','),
      for (final sample in samples)
        [
          manifest['run_id'],
          sample['case_id'],
          sample['status'],
          for (final metric in metrics)
            (sample['metrics'] as Map? ?? {})[metric],
        ].map(cell).join(','),
    ].join('\n');
  }

  /// Standalone escaped HTML with separate native and estimated throughput plots.
  String toHtml() {
    final nativeReference =
        (manifest['profile'] as Map?)?['execution_path'] == 'native_c_api';
    String chart(String metric, String title) {
      final values =
          samples
              .map((s) => (s['metrics'] as Map? ?? {})[metric])
              .whereType<num>()
              .where((n) => n.isFinite && n >= 0)
              .toList()
            ..sort();
      final max = values.isEmpty ? 1 : math.max(1, values.last);
      final stats = values.isEmpty
          ? 'Unavailable'
          : 'n=${values.length}; median ${((values[(values.length - 1) ~/ 2] + values[values.length ~/ 2]) / 2).toStringAsFixed(2)}; '
                'min ${values.first.toStringAsFixed(2)}; max ${values.last.toStringAsFixed(2)}';
      return '<section><h2>${_escape(title)}</h2><p>$stats</p>${samples.map((s) {
        final value = (s['metrics'] as Map? ?? {})[metric] as num?;
        return '<div class="sample">${_escape(s['case_id'])} · ${_escape(s['status'])}'
            '<div class="bar" style="width:${value != null && value.isFinite ? value / max * 100 : 0}%"></div>'
            '${value?.toStringAsFixed(2) ?? 'unavailable'}</div>';
      }).join()}</section>';
    }

    return '<!doctype html><html lang="en"><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        '<title>llamadart validation</title><style>'
        'body{font:16px system-ui;max-width:1100px;margin:40px auto;padding:0 20px;background:#f6f8fb;color:#18233a}'
        'table{border-collapse:collapse;width:100%}td,th{text-align:left;padding:10px;border-bottom:1px solid #ccd4df}'
        'section,details{background:white;padding:20px;margin:20px 0;border-radius:8px}'
        'pre{white-space:pre-wrap;overflow-wrap:anywhere} .bar{height:8px;background:#247a87}.sample{margin:12px 0}'
        '</style><h1>llamadart validation</h1>'
        '<p><strong>${qualified ? 'QUALIFIED' : 'INCOMPLETE / FAILED'}</strong> · ${_escape(manifest['run_id'])}</p>'
        '<p>Execution path: ${nativeReference ? 'direct native C API control (does not qualify the public Dart path)' : 'llamadart public API'}.</p>'
        '<p>Functional assertions: ${assertionsPassed ? 'passed' : 'incomplete or failed'}. '
        'Accelerator placement: ${placement['required'] != true
            ? 'not required'
            : acceleratorVerified
            ? placement['placement'] == 'npu_participation_cpu_partitions_unknown'
                  ? 'NPU participation verified; CPU partition coverage unknown'
                  : 'verified native offload'
            : 'unverified'}.</p>'
        '<p>${_escape([...problems, ...provenanceProblems].join('; '))}</p>'
        '<table><tr><th>Case</th><th>Status</th><th>Reason</th></tr>'
        '${cases.map((c) => '<tr><td>${_escape(c['case_id'])}</td><td>${_escape(c['status'])}</td><td>${_escape(c['reason'] ?? '')}</td></tr>').join()}</table>'
        '${chart('native_decode_tps', 'Native decode tokens/second')}'
        '${chart('estimated_wall_tps', 'Estimated visible-output tokens/second')}'
        '${chart('ttfa_ms', 'Time to first visible answer (ms)')}'
        '${chart('native_ttft_ms', 'Native time to first token (ms)')}'
        '<p>Each series represents one exact model/configuration/build. Failed outputs remain visible. '
        'Retokenized output counts are estimates; stream chunks are not tokens.</p>'
        '<details><summary>Complete evidence</summary><pre>${_escape(const JsonEncoder.withIndent('  ').convert(toJson()))}</pre></details></html>';
  }
}

String _escape(Object? value) => const HtmlEscape(
  HtmlEscapeMode.attribute,
).convert((value ?? '').toString());
