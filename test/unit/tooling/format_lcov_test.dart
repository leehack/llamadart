@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:coverage/coverage.dart';
import 'package:test/test.dart';

import '../../../tool/testing/format_lcov.dart' as format_lcov;

const _packageName = 'format_lcov_fixture';

class _Fixture {
  _Fixture(this.root, this.libDir, this.coverageDir);

  final String root;
  final String libDir;
  final String coverageDir;

  format_lcov.FormatLcovOptions options({
    required bool checkIgnore,
    String? input,
    String? output,
  }) {
    return format_lcov.FormatLcovOptions(
      input: input ?? coverageDir,
      output: output,
      reportOn: [libDir],
      checkIgnore: checkIgnore,
      packagePath: root,
    );
  }
}

void _write(String path, String contents) {
  File(path)
    ..createSync(recursive: true)
    ..writeAsStringSync(contents);
}

void _writeCoverageJson(String path, List<Map<String, Object?>> entries) {
  _write(path, jsonEncode({'type': 'CodeCoverage', 'coverage': entries}));
}

_Fixture _fixture() {
  final temp = Directory.systemTemp.createTempSync('format_lcov_test');
  addTearDown(() => temp.deleteSync(recursive: true));
  final root = temp.resolveSymbolicLinksSync();
  final libDir = '$root/lib';
  final coverageDir = '$root/coverage/test';

  _write('$root/pubspec.yaml', 'name: $_packageName\n');
  _write(
    '$root/.dart_tool/package_config.json',
    jsonEncode({
      'configVersion': 2,
      'packages': [
        {'name': _packageName, 'rootUri': '../', 'packageUri': 'lib/'},
      ],
    }),
  );

  _write(
    '$libDir/kept.dart',
    [
      'int one() => 1;',
      'int two() => 2;',
      'int ignored() => 3; // coverage:ignore-line',
      'int four() => 4;',
    ].join('\n'),
  );
  _write(
    '$libDir/whole_file_ignored.dart',
    ['// coverage:ignore-file', 'int five() => 5;'].join('\n'),
  );
  _write('$root/tool/outside_report_on.dart', 'int six() => 6;\n');

  _writeCoverageJson('$coverageDir/a.json', [
    {
      'source': 'package:$_packageName/kept.dart',
      'hits': [1, 1, 2, 0, 3, 0, 4, 7],
    },
    {
      'source': 'package:$_packageName/whole_file_ignored.dart',
      'hits': [2, 9],
    },
  ]);
  _writeCoverageJson('$coverageDir/b.json', [
    {
      'source': 'package:$_packageName/kept.dart',
      'hits': [1, 2, 2, 0],
    },
    {
      'source': 'file://$root/tool/outside_report_on.dart',
      'hits': [1, 3],
    },
  ]);
  _writeCoverageJson('$coverageDir/nested/c.json', [
    {
      'source': 'package:$_packageName/kept.dart',
      'hits': [4, 5],
    },
  ]);
  _write('$coverageDir/not_coverage.json', jsonEncode({'hello': 1}));
  _write('$coverageDir/notes.txt', 'not json');

  return _Fixture(root, libDir, coverageDir);
}

/// Discovers the fixture's coverage JSON independently of the code under test,
/// so a discovery bug cannot cancel out on both sides of the comparison.
Iterable<File> _inputFiles(String dir) => Directory(dir)
    .listSync(recursive: true)
    .whereType<File>()
    .where((entity) => entity.path.endsWith('.json'));

Future<String> _referenceLcov(
  _Fixture fixture, {
  required bool checkIgnore,
}) async {
  final hitmap = await HitMap.parseFiles(
    _inputFiles(fixture.coverageDir),
    checkIgnoredLines: checkIgnore,
    packagePath: fixture.root,
  );
  final resolver = await Resolver.create(packagePath: fixture.root);
  return hitmap.formatLcov(resolver, reportOn: [fixture.libDir]);
}

void main() {
  test(
    'shared resolver output matches the pinned formatter, check-ignore on',
    () async {
      final fixture = _fixture();
      final actual = await format_lcov.formatLcovReport(
        fixture.options(checkIgnore: true),
      );

      expect(actual, await _referenceLcov(fixture, checkIgnore: true));
      expect(actual, contains('SF:${fixture.libDir}/kept.dart'));
      expect(actual, isNot(contains('whole_file_ignored.dart')));
      expect(actual, isNot(contains('outside_report_on.dart')));
      expect(actual, contains('DA:1,3'));
      expect(actual, contains('DA:2,0'));
      expect(actual, isNot(contains('DA:3,')));
      expect(actual, contains('DA:4,12'));
      expect(actual, contains('LF:3'));
      expect(actual, contains('LH:2'));
    },
  );

  test(
    'shared resolver output matches the pinned formatter, check-ignore off',
    () async {
      final fixture = _fixture();
      final actual = await format_lcov.formatLcovReport(
        fixture.options(checkIgnore: false),
      );

      expect(actual, await _referenceLcov(fixture, checkIgnore: false));
      expect(actual, contains('DA:3,0'));
      expect(actual, contains('SF:${fixture.libDir}/whole_file_ignored.dart'));
    },
  );

  test('a single coverage JSON file is accepted as input', () async {
    final fixture = _fixture();
    final actual = await format_lcov.formatLcovReport(
      fixture.options(
        checkIgnore: true,
        input: '${fixture.coverageDir}/a.json',
      ),
    );

    expect(actual, contains('DA:1,1'));
    expect(actual, contains('DA:4,7'));
    expect(actual, isNot(contains('DA:3,')));
  });

  test('the CI command line parses to the CI semantics', () {
    final options = format_lcov.parseFormatLcovArgs([
      '--lcov',
      '--in=coverage/test',
      '--out=coverage/lcov.info',
      '--report-on=lib',
      '--check-ignore',
    ]);

    expect(options.input, 'coverage/test');
    expect(options.output, 'coverage/lcov.info');
    expect(options.reportOn, ['lib']);
    expect(options.checkIgnore, isTrue);
    expect(options.packagePath, '.');
  });

  test('--out=stdout means stdout, and unreported flags are rejected', () {
    expect(
      format_lcov.parseFormatLcovArgs([
        '--lcov',
        '--in=x',
        '--out=stdout',
      ]).output,
      isNull,
    );
    expect(
      () => format_lcov.parseFormatLcovArgs(['--lcov', '--in=x', '-j', '4']),
      throwsA(isA<format_lcov.FormatLcovUsageException>()),
    );
    expect(
      () => format_lcov.parseFormatLcovArgs(['--in=x']),
      throwsA(isA<format_lcov.FormatLcovUsageException>()),
    );
    expect(
      () => format_lcov.parseFormatLcovArgs(['--lcov']),
      throwsA(isA<format_lcov.FormatLcovUsageException>()),
    );
  });

  test(
    'main writes the report to --out, creating parent directories',
    () async {
      final fixture = _fixture();
      addTearDown(() => exitCode = 0);
      final output = '${fixture.root}/out/nested/lcov.info';

      await format_lcov.main([
        '--lcov',
        '--in=${fixture.coverageDir}',
        '--out=$output',
        '--report-on=${fixture.libDir}',
        '--check-ignore',
        '--package=${fixture.root}',
      ]);

      expect(exitCode, 0);
      expect(
        File(output).readAsStringSync(),
        await format_lcov.formatLcovReport(fixture.options(checkIgnore: true)),
      );
    },
  );

  test('main rewrites an existing output file in full', () async {
    final fixture = _fixture();
    addTearDown(() => exitCode = 0);
    final output = '${fixture.root}/lcov.info';
    _write(output, 'stale' * 5000);

    await format_lcov.main([
      '--lcov',
      '--in=${fixture.coverageDir}',
      '--out=$output',
      '--report-on=${fixture.libDir}',
      '--check-ignore',
      '--package=${fixture.root}',
    ]);

    expect(exitCode, 0);
    expect(File(output).readAsStringSync(), isNot(contains('stale')));
  });

  test(
    'main exits 64 for a bad command line and 66 for a missing input',
    () async {
      final fixture = _fixture();
      addTearDown(() => exitCode = 0);

      await format_lcov.main([
        '--lcov',
        '--in=${fixture.coverageDir}',
        '-j',
        '4',
      ]);
      expect(exitCode, 64);

      exitCode = 0;
      await format_lcov.main(['--lcov', '--in=${fixture.root}/absent']);
      expect(exitCode, 66);
    },
  );
}
