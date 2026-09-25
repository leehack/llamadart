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
  final consoles = <String>[];
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
    if (name == 'xcodebuild_output.log') consoles.add(text);
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
  final stderrLogs = [
    for (final f in files)
      if (p.basename(f.path) == 'stderr.log' &&
          f.lengthSync() <= 8 * 1024 * 1024)
        f.path,
  ];
  final consoleLogs = [
    for (final console in consoles)
      ?boundConsoleNativeLog(console, candidates.values.single),
  ];
  String? nativeLog;
  if (stderrLogs.length + consoleLogs.length == 1) {
    nativeLog = stderrLogs.isNotEmpty
        ? stderrLogs.single
        : (File(
            p.join(output.path, 'native.log'),
          )..writeAsStringSync(consoleLogs.single, flush: true)).path;
  }
  final package = p.join(repository, 'packages/llamadart_validation');
  final resolved = await execute(
    Platform.resolvedExecutable,
    const ['pub', 'get'],
    directory: package,
    timeout: const Duration(minutes: 3),
  );
  if (resolved.code != 0) {
    throw StateError(
      'dart pub get in packages/llamadart_validation exited ${resolved.code}',
    );
  }
  final generated = await execute(
    Platform.resolvedExecutable,
    [
      'run',
      'bin/report.dart',
      output.path,
      if (nativeLog != null) ...['--native-log', nativeLog],
    ],
    directory: package,
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
      const [
        'source_commit',
        'source_dirty',
        'hook_sha256',
        'native_tag',
        'litert_tag',
        'bridge_tag',
      ].every(
        (key) =>
            bundle.containsKey(key) &&
            (manifest['environment'] as Map?)?[key] == bundle[key],
      ) &&
      (plan.firebase ||
          (manifest['environment'] as Map?)?['runtime_bundle_sha256'] ==
              plan.json['bundle_sha256']) &&
      canonical(manifest['profile']) == canonical(profile);
}

/// The native log an iOS XCTest run printed to [console] between its first
/// and last validation record, or null unless those records are exactly
/// [journal]'s lines. Lines outside that window belong to no proven run.
String? boundConsoleNativeLog(String console, String journal) {
  const prefix = 'LLAMADART_VALIDATION ';
  final lines = const LineSplitter().convert(console);
  final records = <String>[];
  final native = <String>[];
  var pending = <String>[];
  for (final line in lines) {
    final index = line.indexOf(prefix);
    if (index < 0) {
      if (records.isNotEmpty) pending.add(line);
      continue;
    }
    records.add(line.substring(index + prefix.length));
    native.addAll(pending);
    pending = [];
  }
  final expected = const LineSplitter()
      .convert(journal)
      .where((line) => line.trim().isNotEmpty)
      .toList();
  if (records.isEmpty ||
      records.length != expected.length ||
      Iterable.generate(records.length).any((i) => records[i] != expected[i])) {
    return null;
  }
  return native.map((line) => '$line\n').join();
}
