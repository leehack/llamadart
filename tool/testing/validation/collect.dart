import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'process.dart';
import 'remote.dart';

/// Normalizes pulled journals or complete console records, then re-runs the
/// shared report validator. Provider results alone never prove Dart assertions.
Future<bool> assessCollectedRun(
  String repository,
  RemotePlan plan,
  Directory run, {
  CommandExecutor execute = executeCommand,
}) async {
  final source = Directory(p.join(run.path, 'remote-results'));
  if (!source.existsSync()) return false;
  final xcresults = source
      .listSync(recursive: true, followLinks: false)
      .whereType<Directory>()
      .where((d) => d.path.endsWith('.xcresult'))
      .toList();
  for (var i = 0; i < xcresults.length; i++) {
    if (!Platform.isMacOS) continue;
    final output = Directory(p.join(run.path, 'xctest-attachments-$i'));
    if (!output.existsSync()) {
      await execute('xcrun', [
        'xcresulttool',
        'export',
        'attachments',
        '--path',
        xcresults[i].path,
        '--output-path',
        output.path,
      ], timeout: const Duration(minutes: 2));
    }
  }
  final files = <File>[];
  for (final dir in [
    source,
    ...run.listSync().whereType<Directory>().where(
      (d) => p.basename(d.path).startsWith('xctest-attachments-'),
    ),
  ]) {
    files.addAll(
      dir.listSync(recursive: true, followLinks: false).whereType<File>(),
    );
  }
  final candidates = <String, String>{};
  for (final file in files) {
    if (file.lengthSync() > 16 * 1024 * 1024) continue;
    final name = p.basename(file.path).toLowerCase();
    if (!(name.endsWith('.jsonl') ||
        name.endsWith('.log') ||
        name.endsWith('.txt'))) {
      continue;
    }
    String text;
    try {
      text = file.readAsStringSync();
    } catch (_) {
      continue;
    }
    if (!name.endsWith('.jsonl')) {
      final lines = <String>[];
      for (final line in const LineSplitter().convert(text)) {
        const prefix = 'LLAMADART_VALIDATION ';
        final index = line.indexOf(prefix);
        if (index >= 0) lines.add(line.substring(index + prefix.length));
      }
      text = lines.join('\n');
    }
    final lines = const LineSplitter()
        .convert(text)
        .where((s) => s.trim().isNotEmpty)
        .toList();
    if (lines.isEmpty) continue;
    try {
      final first = jsonDecode(lines.first) as Map;
      if (first['type'] != 'manifest' ||
          (first['profile'] as Map?)?['id'] != plan.profile) {
        continue;
      }
      final canonical = '${lines.join('\n')}\n';
      candidates[sha256.convert(utf8.encode(canonical)).toString()] = canonical;
    } catch (_) {
      continue;
    }
  }
  // Conflicting pull/log evidence or multiple executions require reconciliation.
  if (candidates.length != 1) return false;
  final output = Directory(p.join(run.path, 'report'))
    ..createSync(recursive: true);
  File(
    p.join(output.path, 'events.jsonl'),
  ).writeAsStringSync(candidates.values.single, flush: true);
  final nativeLogs = files
      .where(
        (f) =>
            p.basename(f.path) == 'stderr.log' &&
            f.lengthSync() <= 8 * 1024 * 1024,
      )
      .toList();
  final generated = await execute(
    Platform.resolvedExecutable,
    [
      'run',
      'bin/report.dart',
      output.path,
      if (nativeLogs.length == 1) ...['--native-log', nativeLogs.single.path],
    ],
    directory: p.join(repository, 'packages/llamadart_validation'),
    timeout: const Duration(minutes: 3),
  );
  final resultFile = File(p.join(output.path, 'results.json'));
  if (!resultFile.existsSync()) return false;
  final result = jsonDecode(resultFile.readAsStringSync()) as Map;
  final manifest = result['manifest'] as Map;
  final bundle =
      jsonDecode(
            File(
              p.join(plan.bundle, 'bundle-manifest.json'),
            ).readAsStringSync(),
          )
          as Map;
  final profile = jsonDecode(
    File(
      p.join(
        plan.bundle,
        plan.firebase ? 'profile.json' : 'assets/profiles/${plan.profile}.json',
      ),
    ).readAsStringSync(),
  );
  String canonical(Object? value) {
    Object? sort(Object? value) => value is Map
        ? {
            for (final key in (value.keys.cast<String>().toList()..sort()))
              key: sort(value[key]),
          }
        : value is List
        ? value.map(sort).toList()
        : value;
    return jsonEncode(sort(value));
  }

  return generated.code == 0 &&
      (result['summary'] as Map)['qualified'] == true &&
      (manifest['environment'] as Map?)?['source_commit'] ==
          bundle['source_commit'] &&
      canonical(manifest['profile']) == canonical(profile);
}
