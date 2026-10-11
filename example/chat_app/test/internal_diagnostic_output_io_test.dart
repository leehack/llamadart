@t.TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:llamadart_validation/llamadart_validation.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart' as t;

import 'package:llamadart_chat_example/validation/internal_diagnostic_output.dart';

void check(String name, Future<void> Function(Directory) run) {
  t.test(name, () async {
    final root = Directory.systemTemp.createTempSync('a6-internal-io-');
    try {
      await run(root);
    } finally {
      root.deleteSync(recursive: true);
    }
  });
}

void expect(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> rejects(Future<void> Function() action) async {
  var rejected = false;
  try {
    await action();
  } catch (_) {
    rejected = true;
  }
  expect(rejected, 'Expected rejection');
}

Map<String, dynamic> clone(Map<String, dynamic> m) =>
    jsonDecode(jsonEncode(m)) as Map<String, dynamic>;

void main() {
  final asset = File('test/cpu-profile.json');
  // Historical exact CPU lock is intentionally separate from model execution.
  final profile = ValidationProfile.fromJson(
    jsonDecode(asset.readAsStringSync()) as Map<String, dynamic>,
  );
  final source = List.filled(40, 'a').join();
  final hook = List.filled(64, 'b').join();
  final binding = <String, dynamic>{
    'run_id': 'attempt-01234567',
    'profile_hash': jsonHash(profile.toJson()),
    'model_sha256': profile.modelHash,
    'model_bytes': profile.model['bytes'],
    'source_snapshot_sha256': hook,
    'source_commit': source,
    'source_dirty': true,
    'hook_sha256': hook,
    'litert_tag': 'v0.18.0',
    'expected_case_ids': profile.caseIds,
  };
  final manifest = <String, dynamic>{
    'type': 'manifest',
    'schema_version': 2,
    'run_id': binding['run_id'],
    'profile': profile.toJson(),
    'profile_hash': binding['profile_hash'],
    'effective_config': profile.effectiveConfig,
    'config_hash': jsonHash(profile.effectiveConfig),
    'environment': {
      'source_snapshot_sha256': hook,
      'source_commit': source,
      'source_dirty': true,
      'hook_sha256': hook,
      'litert_tag': 'v0.18.0',
    },
    'preparation': {
      'verified': true,
      'sha256': profile.modelHash,
      'bytes': profile.model['bytes'],
    },
    'case_ids': profile.caseIds,
    'catalog': profile.catalog,
    'catalog_hash': jsonHash(profile.catalog),
    'accelerator_evidence_required': profile.requiresAcceleratorProof,
  };
  Future<void> complete(InternalDiagnosticOutput o, {bool fail = false}) async {
    await o.emit(manifest);
    var seq = 0;
    for (final id in profile.caseIds) {
      await o.emit({
        'type': 'case',
        'sequence': seq++,
        'case_id': id,
        'case_version': validationCase(id).version,
        'fixture_hash': jsonHash(profile.caseFixtures(id)),
        'status': fail && id == profile.caseIds.first ? 'FAIL' : 'PASS',
      });
    }
    await o.emit({'type': 'cleanup', 'sequence': seq++, 'status': 'PASS'});
    await o.emit({'type': 'run_end', 'sequence': seq++, 'cancelled': false});
  }

  Map<String, dynamic> seal(InternalDiagnosticOutput o) =>
      jsonDecode(
            File(
              p.join(o.directory.path, 'diagnostic-seal.json'),
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  check('complete FAIL is sealed unchanged, optional preparation absent', (
    root,
  ) async {
    final o = InternalDiagnosticOutput.open(root, binding);
    await complete(o, fail: true);
    final r = o.finish();
    final s = seal(o);
    expect(
      !r.assertionsPassed &&
          s['complete'] == true &&
          s['assertions_passed'] == false,
      'Functional FAIL must survive',
    );
    expect(
      (s['files'] as Map).length == 6 &&
          !(s['files'] as Map).containsKey('diagnostic-seal.json'),
      'Payload-only inventory',
    );
    expect(
      (s['binding'] as Map)['source_dirty'] == true,
      'Dirty historical scope retained',
    );
    for (final entry in (s['files'] as Map).entries) {
      final bytes = File(
        p.join(o.directory.path, entry.key as String),
      ).readAsBytesSync();
      expect(
        bytes.length == entry.value['bytes'] &&
            sha256.convert(bytes).toString() == entry.value['sha256'],
        'Inventory binds actual bytes',
      );
    }
    await rejects(() => o.emit({'type': 'case'}));
    await rejects(() async {
      o.finish();
    });
  });
  check('passing synthetic journal and preparation retained', (root) async {
    final o = InternalDiagnosticOutput.open(root, binding);
    await o.emitPreparation({'stage': 'checksum', 'bytes': 1});
    await complete(o);
    expect(o.finish().assertionsPassed, 'Synthetic report intact');
    expect((seal(o)['files'] as Map).length == 7, 'Preparation inventoried');
  });
  check('partial preparation failure stays incomplete', (root) async {
    final o = InternalDiagnosticOutput.open(root, binding);
    await o.emitPreparation({'stage': 'checksum'});
    await o.emit({'type': 'preparation_error', 'message': 'failed'});
    expect(
      !o.finish().assertionsPassed && seal(o)['complete'] == false,
      'Partial never complete',
    );
  });
  for (final key in [
    'run_id',
    'profile_hash',
    'model_sha256',
    'model_bytes',
    'source_commit',
    'source_snapshot_sha256',
    'source_dirty',
    'hook_sha256',
    'litert_tag',
    'expected_case_ids',
  ]) {
    check('actual manifest rejects changed $key', (root) async {
      final b = clone(binding);
      if (key == 'run_id') {
        b[key] = 'different';
      } else if (key == 'model_bytes') {
        b[key] = (b[key] as int) + 1;
      } else if (key == 'source_dirty') {
        b[key] = false;
      } else if (key == 'expected_case_ids') {
        b[key] = ['foreign'];
      } else if (key == 'litert_tag') {
        b[key] = 'v0.17.0';
      } else {
        b[key] = List.filled(key == 'source_commit' ? 40 : 64, 'c').join();
      }
      final o = InternalDiagnosticOutput.open(root, b);
      await rejects(() => o.emit(manifest));
      expect(
        !File(p.join(o.directory.path, 'manifest.json')).existsSync(),
        'No mismatched manifest persisted',
      );
    });
  }
  for (final id in ['', '..', '../escape', 'a/b', 'a\\b', 'a\n', 'a' * 81]) {
    check('invalid run id ${jsonEncode(id)}', (root) async {
      await rejects(() async {
        InternalDiagnosticOutput.open(root, {...binding, 'run_id': id});
      });
    });
  }
  check('duplicate case binding rejected', (root) async {
    await rejects(() async {
      InternalDiagnosticOutput.open(root, {
        ...binding,
        'expected_case_ids': ['C01.load', 'C01.load'],
      });
    });
  });
  check('fresh run required', (root) async {
    InternalDiagnosticOutput.open(root, binding);
    await rejects(() async {
      InternalDiagnosticOutput.open(root, binding);
    });
  });
  check('parent link never followed', (root) async {
    final outside = Directory(p.join(root.path, 'outside'))..createSync();
    Link(p.join(root.path, 'validation')).createSync(outside.path);
    await rejects(() async {
      InternalDiagnosticOutput.open(root, binding);
    });
    expect(outside.listSync().isEmpty, 'No outside writes');
  });
  check('output link inserted after admission rejected', (root) async {
    final o = InternalDiagnosticOutput.open(root, binding);
    final outside = File(p.join(root.path, 'victim'))
      ..writeAsStringSync('keep');
    Link(p.join(o.directory.path, 'events.jsonl')).createSync(outside.path);
    await rejects(() => o.emit(manifest));
    expect(outside.readAsStringSync() == 'keep', 'Target unchanged');
  });
  check('ancestor replacement rejected before next write', (root) async {
    final o = InternalDiagnosticOutput.open(root, binding);
    final parent = o.directory.parent;
    parent.renameSync('${parent.path}-old');
    final outside = Directory(p.join(root.path, 'outside'))..createSync();
    Link(parent.path).createSync(outside.path);
    await rejects(() => o.emit(manifest));
    expect(outside.listSync().isEmpty, 'No escape');
  });
  check('unexpected child entry rejected', (root) async {
    final o = InternalDiagnosticOutput.open(root, binding);
    Directory(p.join(o.directory.path, 'other')).createSync();
    await rejects(() => o.emit(manifest));
  });
  check('oversize event writes zero bytes', (root) async {
    final o = InternalDiagnosticOutput.open(root, binding);
    await rejects(
      () => o.emit({'text': 'x' * InternalDiagnosticOutput.recordLimit}),
    );
    expect(o.directory.listSync().isEmpty, 'No oversized write');
  });
  check('preparation and journal cumulative caps', (root) async {
    final o = InternalDiagnosticOutput.open(root, binding);
    for (var i = 0; i < 4; i++) {
      await o.emitPreparation({'data': 'x' * 60000});
    }
    await rejects(() => o.emitPreparation({'data': 'x' * 60000}));
    expect(
      File(p.join(o.directory.path, 'preparation.jsonl')).lengthSync() <=
          InternalDiagnosticOutput.preparationLimit,
      'Preparation bounded',
    );
    for (var i = 0; i < 34; i++) {
      await o.emit({'data': 'x' * 60000});
    }
    await rejects(() => o.emit({'data': 'x' * 60000}));
    expect(
      File(p.join(o.directory.path, 'events.jsonl')).lengthSync() <=
          InternalDiagnosticOutput.fileLimit,
      'Journal bounded',
    );
  });
  check('duplicate manifest rejected', (root) async {
    final o = InternalDiagnosticOutput.open(root, binding);
    await o.emit(manifest);
    await rejects(() => o.emit(manifest));
  });

  check('missing and unknown identity fields rejected', (root) async {
    for (final key in binding.keys) {
      final b = clone(binding)..remove(key);
      await rejects(() async {
        InternalDiagnosticOutput.open(root, b);
      });
    }
    await rejects(() async {
      InternalDiagnosticOutput.open(root, {...binding, 'foreign': 'extra'});
    });
  });
  check('support symlink and relative support rejected', (root) async {
    final link = Link(p.join(root.path, 'link'))..createSync(root.path);
    await rejects(() async {
      InternalDiagnosticOutput.open(Directory(link.path), binding);
    });
    await rejects(() async {
      InternalDiagnosticOutput.open(Directory('.'), binding);
    });
  });
  check('unverified actual preparation fails identity', (root) async {
    final o = InternalDiagnosticOutput.open(root, binding);
    final m = clone(manifest);
    (m['preparation'] as Map)['verified'] = false;
    await rejects(() => o.emit(m));
    expect(o.directory.listSync().isEmpty, 'No unverified manifest');
  });
  check('missing terminal cases or run end stay incomplete', (root) async {
    final o = InternalDiagnosticOutput.open(root, binding);
    await o.emit(manifest);
    expect(
      !o.finish().assertionsPassed && seal(o)['complete'] == false,
      'Missing cases cannot be sealed complete',
    );
  });
  check('aggregate payload budget excludes oversized existing payload', (
    root,
  ) async {
    final o = InternalDiagnosticOutput.open(root, binding);
    for (final n in [
      'events.jsonl',
      'results.json',
      'junit.xml',
      'samples.csv',
    ]) {
      File(
        p.join(o.directory.path, n),
      ).writeAsBytesSync(List.filled(InternalDiagnosticOutput.fileLimit, 120));
    }
    await rejects(() => o.emitPreparation({'stage': 'ready'}));
    expect(
      !File(p.join(o.directory.path, 'preparation.jsonl')).existsSync(),
      'No aggregate overflow',
    );
  });
  check('input binding is snapshotted and exposed immutable', (root) async {
    final b = clone(binding);
    final o = InternalDiagnosticOutput.open(root, b);
    (b['expected_case_ids'] as List).clear();
    b['source_commit'] = 'changed';
    await complete(o);
    expect(
      o.finish().assertionsPassed,
      'Caller mutation cannot change admission',
    );
    await rejects(() async {
      (o.binding['expected_case_ids'] as List).clear();
    });
  });
}
