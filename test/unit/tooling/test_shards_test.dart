@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../../tool/ci/test_shards.dart';

void main() {
  group('partitionTests', () {
    test('puts every file in exactly one shard, balanced by weight', () {
      final files = [for (var i = 0; i < 9; i++) 'test/f${i}_test.dart'];
      final weights = {
        'test/f0_test.dart': 90,
        'test/f1_test.dart': 60,
        'test/f2_test.dart': 50,
        'test/f3_test.dart': 40,
        'test/f4_test.dart': 30,
        'test/f5_test.dart': 20,
        'test/f6_test.dart': 10,
      };
      final shards = partitionTests(files, weights, 3);

      expect(shards.expand((shard) => shard).toList()..sort(), files);
      // The unmeasured f7 and f8 weigh the median measured weight, 40.
      expect(shards, [
        ['test/f0_test.dart', 'test/f8_test.dart'],
        [
          'test/f1_test.dart',
          'test/f5_test.dart',
          'test/f6_test.dart',
          'test/f7_test.dart',
        ],
        ['test/f2_test.dart', 'test/f3_test.dart', 'test/f4_test.dart'],
      ]);
    });

    test('is independent of input order and works without weights', () {
      final files = [for (var i = 0; i < 7; i++) 'test/g${i}_test.dart'];
      final shards = partitionTests(files.reversed.toList(), const {}, 2);

      expect(shards, partitionTests(files, const {}, 2));
      expect(shards.map((shard) => shard.length), [4, 3]);
    });

    test('rejects a shard count below one', () {
      expect(() => partitionTests(const [], const {}, 0), throwsArgumentError);
    });
  });

  test('suiteWeights spans each suite from first start to last end', () {
    final weights = suiteWeights([
      {
        'suites': [
          {'id': 0, 'path': 'test/a_test.dart'},
          {'id': 1, 'path': 'test/b_test.dart'},
          {'id': 2, 'path': '<external-or-loading-suite>'},
        ],
        'tests': [
          {'suiteId': 0, 'startMs': 10, 'durationMs': 5},
          {'suiteId': 0, 'startMs': 12, 'durationMs': 20},
          {'suiteId': 1, 'startMs': 40, 'durationMs': null},
          {'suiteId': 2, 'startMs': 0, 'durationMs': 9},
        ],
      },
    ]);

    expect(weights, {'test/a_test.dart': 22, 'test/b_test.dart': 0});
  });

  group('rootTestFiles', () {
    late Directory root;
    setUp(() => root = Directory.systemTemp.createTempSync('test-shards-'));
    tearDown(() => root.deleteSync(recursive: true));

    void touch(String path) =>
        (File('${root.path}/$path')..createSync(recursive: true));

    test('lists every *_test.dart under test/, sorted', () {
      touch('test/unit/b_test.dart');
      touch('test/a_test.dart');
      touch('test/support/helper.dart');
      touch('tool/c_test.dart');

      expect(rootTestFiles(root.path), [
        'test/a_test.dart',
        'test/unit/b_test.dart',
      ]);
    });

    test('rejects a path the workflow could not pass as one word', () {
      touch(r'test/a $(x)_test.dart');

      expect(() => rootTestFiles(root.path), throwsFormatException);
    });
  });

  test('the weights file has an entry for every lane', () {
    expect(readWeights().keys, testShardLanes);
  });

  group('command line', () {
    Future<ProcessResult> run(
      List<String> arguments, {
      Map<String, String> environment = const {},
    }) => Process.run(Platform.resolvedExecutable, [
      'tool/ci/test_shards.dart',
      ...arguments,
    ], environment: environment);

    test('writes one shard to stdout and GITHUB_OUTPUT', () async {
      final scratch = Directory.systemTemp.createTempSync('test-shards-out-');
      addTearDown(() => scratch.deleteSync(recursive: true));
      final output = File('${scratch.path}/output')..createSync();

      final result = await run(
        ['windows', '2', '3'],
        environment: {'GITHUB_OUTPUT': output.path},
      );

      expect(result.exitCode, 0, reason: '${result.stderr}');
      final expected = partitionTests(
        rootTestFiles(),
        readWeights()['windows']!,
        3,
      )[1];
      expect(LineSplitter.split('${result.stdout}'), expected);
      expect(output.readAsStringSync(), 'files=${expected.join(' ')}\n');
    });

    for (final arguments in [
      ['unknown', '1', '2'],
      ['macos', '0', '2'],
      ['macos', '3', '2'],
      ['macos', '1'],
    ]) {
      test('rejects ${arguments.join(' ')}', () async {
        final result = await run(arguments);

        expect(result.exitCode, 64);
        expect(result.stdout, isEmpty);
      });
    }
  });
}
