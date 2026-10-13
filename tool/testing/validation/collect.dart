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
  } else if (plan.target == 'firebase-android' &&
      !files.any(
        (f) => const {
          'stderr.log',
          'xcodebuild_output.log',
        }.contains(p.basename(f.path).toLowerCase()),
      )) {
    // A stderr or console capture, bound or not, always decides first; the
    // device log is read only for runs that produced neither.
    final logcats = [
      for (final f in files)
        if (p.basename(f.path) == 'logcat' && p.isWithin(source.path, f.path))
          f,
    ];
    if (logcats.length == 1 &&
        logcats.single.lengthSync() <= _logcatReadLimit) {
      final bound = await boundLogcatNativeLog(
        logcats.single
            .openRead()
            .transform(const Utf8Decoder(allowMalformed: true))
            .transform(const LineSplitter()),
        candidates.values.single,
      );
      if (bound != null) {
        nativeLog = (File(
          p.join(output.path, 'native.log'),
        )..writeAsStringSync(bound, flush: true)).path;
      }
    }
  }
  final package = p.join(repository, 'packages/llamadart_validation');
  final resolved = await execute(
    Platform.resolvedExecutable,
    const ['pub', 'get'],
    directory: package,
    timeout: const Duration(minutes: 3),
  );
  if (resolved.code != 0) {
    throw ValidationAssessmentFailure(_stepFailure('dart pub get', resolved));
  }
  final resultFile = File(p.join(output.path, 'results.json'));
  if (resultFile.existsSync()) resultFile.deleteSync();
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
  final result = resultFile.existsSync()
      ? jsonDecode(resultFile.readAsStringSync()) as Map
      : null;
  final unqualified =
      generated.code == 1 &&
      (result?['summary'] as Map?)?['qualified'] == false;
  if (result == null || (generated.code != 0 && !unqualified)) {
    throw ValidationAssessmentFailure(
      _stepFailure(
        'dart run bin/report.dart',
        generated,
        detail: result == null ? 'wrote no results.json' : null,
      ),
    );
  }
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

/// A Firebase device log covers the whole device session; a quick run is
/// about 15 MB. It is streamed, so this bounds time rather than memory.
const _logcatReadLimit = 128 * 1024 * 1024;

/// The retained app-process lines share the `stderr.log` limit.
const _nativeLogLimit = 8 * 1024 * 1024;

final _logcatLine = RegExp(
  r'^\d\d-\d\d \d\d:\d\d:\d\d\.\d{3} +(\d+) +\d+ [VDIWEF] (.*)$',
);
final _abslEpoch = RegExp(
  r'\b[IWEF]\d{4} \d\d:\d\d:(\d{9,11})\.(\d{6})\s+\d+ ',
);
final _modelDirectory = RegExp(r'/validation/models/([0-9a-f]{64})/');

/// The lines a Firebase Android run's app process logged from its test start
/// record onward, or null unless [logcat] is bound to [journal]'s run.
///
/// The device log holds every process of the device session. It is bound only
/// when the journal is an Android LiteRT GPU run, exactly one Flutter test
/// start record names the journal's profile and every other mention of a
/// shared validation test is that process naming that profile, every model
/// that process loaded came from the profile's locked SHA-256 directory, and
/// every epoch timestamp its native lines carry is at or after the journal's
/// `started_at`. The manifest is written before the first load on the same
/// device clock, so no skew is allowed. The journal records no later wall
/// time, so there is no upper bound.
Future<String?> boundLogcatNativeLog(
  Stream<String> logcat,
  String journal,
) async {
  final String profile;
  final String model;
  final int started;
  try {
    final manifest =
        jsonDecode(
              const LineSplitter()
                  .convert(journal)
                  .firstWhere((line) => line.trim().isNotEmpty),
            )
            as Map;
    final declared = manifest['profile'] as Map;
    final time = DateTime.parse(manifest['started_at'] as String);
    profile = declared['id'] as String;
    model = (declared['model'] as Map)['sha256'] as String;
    started = time.microsecondsSinceEpoch;
    if (manifest['type'] != 'manifest' ||
        (manifest['environment'] as Map)['platform'] != 'android' ||
        declared['runtime'] != 'litert' ||
        declared['backend'] != 'gpu' ||
        !time.isUtc ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(model)) {
      return null;
    }
  } catch (_) {
    return null;
  }
  const mention = 'shared validation: ';
  final start = RegExp(
    '^flutter *: \\d\\d:\\d\\d \\+0: $mention${RegExp.escape(profile)}\$',
  );
  final named = RegExp('$mention${RegExp.escape(profile)}(?:\\(|\$)');
  String? pid;
  var models = 0;
  var stamps = 0;
  var size = 0;
  final kept = StringBuffer();
  await for (final line in logcat) {
    final entry = _logcatLine.firstMatch(line);
    if (line.contains(mention)) {
      if (entry == null) return null;
      if (start.hasMatch(entry[2]!)) {
        if (pid != null) return null;
        pid = entry[1];
      } else if (entry[1] != pid || !named.hasMatch(line)) {
        return null;
      }
    }
    if (entry == null || pid == null || entry[1] != pid) continue;
    final directories = _modelDirectory.allMatches(line).toList();
    if (directories.any((match) => match[1] != model)) return null;
    if (RegExp(r'\bModel .+ loaded from ').hasMatch(line)) {
      if (directories.isEmpty) return null;
      models++;
    }
    for (final match in _abslEpoch.allMatches(line)) {
      if (int.parse(match[1]!) * 1000000 + int.parse(match[2]!) < started) {
        return null;
      }
      stamps++;
    }
    size += line.length + 1;
    if (size > _nativeLogLimit) return null;
    kept.writeln(line);
  }
  return pid == null || models == 0 || stamps == 0 ? null : kept.toString();
}

String _stepFailure(String step, CommandResult result, {String? detail}) {
  final tail = _redactedTail(result.error);
  return [
    'Validation report step `$step` in packages/llamadart_validation exited '
        '${result.code}',
    ?detail,
    if (tail.isNotEmpty) 'stderr tail:\n$tail',
  ].join('; ');
}

/// The last 20 non-blank lines of [text], at most 2000 characters, with URLs,
/// absolute paths and credential-like values replaced.
String _redactedTail(String text) {
  final lines = const LineSplitter()
      .convert(text)
      .where((line) => line.trim().isNotEmpty)
      .toList();
  var tail = lines.skip(lines.length > 20 ? lines.length - 20 : 0).join('\n');
  if (tail.length > 2000) tail = tail.substring(tail.length - 2000);
  return tail
      .replaceAll(RegExp(r'[A-Za-z][A-Za-z0-9+.-]*://\S+'), '<url>')
      .replaceAllMapped(
        RegExp(
          r'\b(bearer|token|password|secret|key)(\s*[=:]\s*|\s+)\S+',
          caseSensitive: false,
        ),
        (match) => '${match[1]}${match[2]}<redacted>',
      )
      .replaceAll(
        RegExp(r'''(?:[A-Za-z]:)?[\\/](?:[^\s\\/:"']+[\\/])+[^\s\\/:"']*'''),
        '<path>',
      );
}
