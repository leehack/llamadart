import 'dart:convert';
import 'dart:io';

/// Lanes that split root test files across CI jobs, each mapped to the
/// weights it is balanced by.
const Map<String, String> testShardLanes = {
  'linux-vm': 'linux-vm',
  'chrome': 'chrome',
  'macos': 'macos',
  'windows-tooling': 'windows',
  'windows-runtime': 'windows',
};

/// Timing sources in the weights file.
const List<String> weightLanes = ['linux-vm', 'chrome', 'macos', 'windows'];

/// Suites `windows-tooling` runs and `windows-runtime` does not. On Windows a
/// tooling suite's `dart run` child cannot replace `.dart_tool/lib` DLLs that
/// native suites in the same test process hold open.
const List<String> windowsToolingPaths = [
  'test/unit/tooling/',
  'test/unit/hook/',
  'test/unit/test_structure/',
  'test/unit/web_setup/',
  'test/unit/public_entrypoints_test.dart',
  'test/unit/public_entrypoints_web_test.dart',
];

const String weightsPath = 'tool/ci/test_shard_weights.json';

// Paths reach the workflow as shell words, so anything else is rejected.
final RegExp _safeTestPath = RegExp(r'^test/[A-Za-z0-9_./-]+_test\.dart$');

/// Every `*_test.dart` file under `test/`, as sorted `/`-separated paths.
List<String> rootTestFiles([String root = '.']) {
  final files = [
    for (final entity in Directory(
      '$root/test',
    ).listSync(recursive: true, followLinks: false))
      if (entity is File && entity.path.endsWith('_test.dart'))
        entity.path
            .substring(root.length + 1)
            .replaceAll(Platform.pathSeparator, '/'),
  ]..sort();
  for (final file in files) {
    if (!_safeTestPath.hasMatch(file) || file.split('/').contains('..')) {
      throw FormatException('Unsupported test file path: $file');
    }
  }
  return files;
}

/// The files of [files] that [lane] runs.
List<String> laneFiles(String lane, List<String> files) => switch (lane) {
  'windows-tooling' => [
    for (final file in files)
      if (windowsToolingPaths.any(file.startsWith)) file,
  ],
  'windows-runtime' => [
    for (final file in files)
      if (!windowsToolingPaths.any(file.startsWith)) file,
  ],
  _ => files,
};

/// Splits [files] into [count] shards with about equal summed [weights].
///
/// Longest first, each onto the lightest shard, ties to the lower index, so
/// the result is deterministic and every file lands in exactly one shard.
/// Files without a measured weight count as the median measured weight.
List<List<String>> partitionTests(
  List<String> files,
  Map<String, int> weights,
  int count,
) {
  if (count < 1) throw ArgumentError.value(count, 'count');
  final known = weights.values.toList()..sort();
  final fallback = known.isEmpty ? 1 : known[known.length ~/ 2];
  int weightOf(String file) => weights[file] ?? fallback;
  final ordered = [...files]
    ..sort((a, b) {
      final byWeight = weightOf(b).compareTo(weightOf(a));
      return byWeight != 0 ? byWeight : a.compareTo(b);
    });
  final shards = List.generate(count, (_) => <String>[]);
  final loads = List.filled(count, 0);
  for (final file in ordered) {
    var lightest = 0;
    for (var i = 1; i < count; i++) {
      if (loads[i] < loads[lightest]) lightest = i;
    }
    shards[lightest].add(file);
    loads[lightest] += weightOf(file);
  }
  for (final shard in shards) {
    shard.sort();
  }
  return shards;
}

/// Per-suite wall time in milliseconds from `native_test_timing.dart`
/// summaries: from the suite's first start (its load) to its last end or, if
/// later, to the next suite's start, which adds the coverage collection a
/// `-j 1` VM run spends between suites. A suite in several summaries, such as
/// several runs' artifacts, gets its mean time.
Map<String, int> suiteWeights(Iterable<Map<String, dynamic>> summaries) {
  final times = <String, List<int>>{};
  for (final summary in summaries) {
    final paths = {
      for (final suite in (summary['suites'] as List).cast<Map>())
        suite['id'] as int: suite['path'] as String,
    };
    final spans = <int, (int, int)>{};
    for (final test in (summary['tests'] as List).cast<Map>()) {
      final start = test['startMs'] as int;
      final end = start + ((test['durationMs'] as int?) ?? 0);
      final id = test['suiteId'] as int;
      final (first, last) = spans[id] ?? (start, end);
      spans[id] = (start < first ? start : first, end > last ? end : last);
    }
    final starts = spans.values.map((span) => span.$1).toList()..sort();
    final elapsed = summary['reporterElapsedMs'] as int? ?? 0;
    for (final MapEntry(key: id, value: (first, last)) in spans.entries) {
      final path = paths[id]!;
      if (!_safeTestPath.hasMatch(path)) continue;
      final next = starts.firstWhere(
        (start) => start > first,
        orElse: () => elapsed,
      );
      (times[path] ??= []).add((next > last ? next : last) - first);
    }
  }
  return {
    for (final MapEntry(key: path, value: runs) in times.entries)
      path: runs.reduce((a, b) => a + b) ~/ runs.length,
  };
}

Map<String, Map<String, int>> readWeights([String file = weightsPath]) {
  final decoded = jsonDecode(File(file).readAsStringSync()) as Map;
  return {
    for (final MapEntry(:key, :value) in decoded.entries)
      key as String: (value as Map).cast<String, int>(),
  };
}

const String _usage =
    '''
Usage:
  dart tool/ci/test_shards.dart <lane> <shard> <shards>
      Prints the test files of 1-based <shard> of <shards> for <lane>, and
      writes them as `files` to \$GITHUB_OUTPUT when that is set.
      Lanes: linux-vm, chrome, macos, windows-tooling, windows-runtime.
  dart tool/ci/test_shards.dart weights <source> <timing.json>...
      Replaces <source>'s weights in $weightsPath with the suite times of
      native_test_timing.dart summaries, such as one lane's CI artifacts.
      Sources: linux-vm, chrome, macos, windows.''';

void main(List<String> arguments) {
  if (arguments.length >= 3 && arguments.first == 'weights') {
    final lane = arguments[1];
    if (!weightLanes.contains(lane)) return _fail('Unknown lane: $lane');
    final summaries = [
      for (final file in arguments.skip(2))
        jsonDecode(File(file).readAsStringSync()) as Map<String, dynamic>,
    ];
    final all = File(weightsPath).existsSync()
        ? readWeights()
        : <String, Map<String, int>>{};
    final measured = suiteWeights(summaries);
    // A file the lane did not run (platform-skipped) costs nothing there.
    all[lane] = {
      for (final file in {
        ...rootTestFiles(),
        ...measured.keys,
      }.toList()..sort())
        file: measured[file] ?? 0,
    };
    File(weightsPath).writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert({for (final lane in weightLanes) lane: all[lane] ?? <String, int>{}})}\n',
    );
    return;
  }
  if (arguments.length != 3) return _fail(_usage);
  final [lane, shardText, countText] = arguments;
  final shard = int.tryParse(shardText);
  final count = int.tryParse(countText);
  if (!testShardLanes.containsKey(lane) ||
      count == null ||
      shard == null ||
      shard < 1 ||
      shard > count) {
    return _fail(_usage);
  }
  final files = partitionTests(
    laneFiles(lane, rootTestFiles()),
    readWeights()[testShardLanes[lane]] ?? const {},
    count,
  )[shard - 1];
  if (files.isEmpty) return _fail('Shard $shard of $count has no test files.');
  stdout.writeln(files.join('\n'));
  final output = Platform.environment['GITHUB_OUTPUT'];
  if (output != null && output.isNotEmpty) {
    File(
      output,
    ).writeAsStringSync('files=${files.join(' ')}\n', mode: FileMode.append);
  }
}

void _fail(String message) {
  stderr.writeln(message);
  exitCode = 64;
}
