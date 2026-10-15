@TestOn('vm')
library;

import 'dart:io';

import 'package:llamadart/src/hook/native_release_pins.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';

import '../../../tool/testing/verify_release_docs_versions.dart';

const _llamaCpp = 'llamadart_llama_cpp_flutter';
const _liteRtLm = 'llamadart_litert_lm_flutter';
const _stableDiffusion = 'llamadart_stable_diffusion_flutter';

const _swiftVariables = <String, String>{
  _llamaCpp: 'llamaCppTag',
  _liteRtLm: 'liteRtLmTag',
  _stableDiffusion: 'stableDiffusionTag',
};

const _acceptedPins = <String, Set<String>>{
  _llamaCpp: {'v1.0.0', 'v1.0.0-earlier'},
  _liteRtLm: {'v2.0.0'},
  _stableDiffusion: {'v3.0.0'},
};

String _pubspec(String version, {String? core}) {
  final buffer = StringBuffer()
    ..writeln('name: companion')
    ..writeln('version: $version')
    ..writeln('dependencies:')
    ..writeln('  flutter:')
    ..writeln('    sdk: flutter');
  if (core != null) buffer.writeln('  llamadart: $core');
  return buffer.toString();
}

/// Writes every companion's pubspec, constraining core to [core], and SwiftPM
/// pin under [root]; [pubspecs] and [pins] replace them per package.
void _writeCompanions(
  Directory root, {
  String core = "'>=0.13.0 <0.14.0'",
  Map<String, String> pubspecs = const {},
  Map<String, String> pins = const {},
}) {
  for (final companion in companionSwiftPins) {
    final package = companion.package;
    final pin = pins[package] ?? _acceptedPins[package]!.first;
    File('${root.path}/${companion.pubspecPath}')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(pubspecs[package] ?? _pubspec('0.0.1', core: core));
    File('${root.path}/${companion.swiftPackagePath}')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('let ${_swiftVariables[package]} = "$pin"\n');
  }
}

Directory _tempRoot() {
  final root = Directory.systemTemp.createTempSync('companion_core_');
  addTearDown(() => root.deleteSync(recursive: true));
  return root;
}

void _git(Directory root, List<String> arguments) {
  final result = Process.runSync('git', [
    '-C',
    root.path,
    '-c',
    'user.name=Test',
    '-c',
    'user.email=test@example.com',
    '-c',
    'commit.gpgsign=false',
    '-c',
    'tag.gpgsign=false',
    ...arguments,
  ]);
  expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
}

/// Commits the companions [_writeCompanions] lays out and tags the commit.
void _commitAndTag(Directory root, List<String> tags) {
  _git(root, ['add', '-A']);
  _git(root, ['commit', '--quiet', '--allow-empty', '-m', tags.join(' ')]);
  for (final tag in tags) {
    _git(root, ['tag', tag]);
  }
}

Directory _gitRepo() {
  final root = _tempRoot();
  _git(root, ['init', '--quiet']);
  return root;
}

List<String> _cliContractProblems(String source) {
  final problems = <String>[];
  final always = RegExp(
    r'errors\.addAll\(\s*checkCompanionCoreConstraints\(\s*'
    r'Directory\.current,\s*coreVersion,?\s*\),?\s*\);',
  ).allMatches(source).toList();
  final strict = RegExp(
    r'if \(releasePrep\) \{\s*errors\.addAll\(\s*'
    r'checkPublishedCompanionPins\(\s*Directory\.current,\s*coreVersion,?\s*'
    r'\),?\s*\);\s*\}',
  ).allMatches(source).toList();
  if (always.length != 1) {
    problems.add('expected one unconditional core-constraint check');
  }
  if (strict.length != 1) {
    problems.add('expected one release-prep published-pin check');
  }
  final errorGuard = source.indexOf('if (errors.isNotEmpty) {');
  if (always.length == 1 &&
      strict.length == 1 &&
      !(always.single.start < strict.single.start &&
          strict.single.start < errorGuard)) {
    problems.add('both checks must run before success can be reported');
  }
  return problems;
}

void main() {
  group('companionCoreConstraintFor', () {
    test('spans exactly the core minor', () {
      expect(
        companionCoreConstraintFor(Version.parse('0.13.2')),
        '>=0.13.0 <0.14.0',
      );
      expect(
        companionCoreConstraintFor(Version.parse('1.4.0')),
        '>=1.4.0 <1.5.0',
      );
    });
  });

  group('checkCompanionCoreConstraints', () {
    test('the checkout constrains every companion to its core minor', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      final version = RegExp(
        r'^version:\s*(\S+)',
        multiLine: true,
      ).firstMatch(pubspec)!.group(1)!;

      expect(
        checkCompanionCoreConstraints(
          Directory.current,
          Version.parse(version),
        ),
        isEmpty,
      );
    });

    test('accepts the core minor from its first or an earlier patch', () {
      for (final core in ["'>=0.13.0 <0.14.0'", "'>=0.13.2 <0.14.0'"]) {
        final root = _tempRoot();
        _writeCompanions(root, core: core);

        expect(
          checkCompanionCoreConstraints(root, Version.parse('0.13.2')),
          isEmpty,
          reason: core,
        );
      }
    });

    test('rejects a companion without a hosted core constraint', () {
      final root = _tempRoot();
      _writeCompanions(
        root,
        pubspecs: {
          _llamaCpp: _pubspec('0.0.1'),
          _liteRtLm: '${_pubspec('0.0.1')}  llamadart:\n    path: ../..\n',
        },
      );

      final errors = checkCompanionCoreConstraints(
        root,
        Version.parse('0.13.0'),
      );

      expect(errors, [
        allOf(
          contains('packages/$_llamaCpp/pubspec.yaml declares no `llamadart`'),
          contains("declare `llamadart: '>=0.13.0 <0.14.0'`"),
        ),
        allOf(
          contains('packages/$_liteRtLm/pubspec.yaml declares `llamadart` as'),
          contains("declare `llamadart: '>=0.13.0 <0.14.0'`"),
        ),
      ]);
    });

    test('rejects a window that is not exactly the core minor', () {
      for (final core in [
        "'>=0.12.0 <0.13.0'",
        "'>=0.13.0 <0.15.0'",
        "'>=0.13.0 <1.0.0'",
        "'>=0.13.3 <0.14.0'",
        "'>=0.13.0 <=0.14.0'",
        "'^0.13.0'",
        "'any'",
      ]) {
        final root = _tempRoot();
        _writeCompanions(root, core: core);

        final errors = checkCompanionCoreConstraints(
          root,
          Version.parse('0.13.2'),
        );

        expect(errors, hasLength(companionSwiftPins.length), reason: core);
        expect(
          errors.first,
          allOf(
            contains('but core is 0.13.2'),
            contains("`'>=0.13.0 <0.14.0'` for a new minor"),
            contains('Bump the companion version'),
          ),
          reason: core,
        );
      }
    });
  });

  group('checkPublishedCompanionPins', () {
    test('fails closed without core release tags', () {
      final root = _gitRepo();
      _writeCompanions(root);
      _commitAndTag(root, ['$_llamaCpp-v0.0.1']);

      expect(
        checkPublishedCompanionPins(
          root,
          Version.parse('0.13.1'),
          acceptedPins: _acceptedPins,
        ),
        [contains('No core `v*` release tags are checked out')],
      );
    });

    test('fails closed outside a git checkout', () {
      expect(
        checkPublishedCompanionPins(
          _tempRoot(),
          Version.parse('0.13.1'),
          acceptedPins: _acceptedPins,
        ),
        [contains('git tag --list v* failed')],
      );
    });

    test('passes published companions this core accepts', () {
      final root = _gitRepo();
      _writeCompanions(root, pubspecs: {_llamaCpp: _pubspec('0.0.1')});
      _commitAndTag(root, ['v0.12.0', '$_llamaCpp-v0.0.1']);
      _writeCompanions(root, pins: {_llamaCpp: 'v1.0.0-earlier'});
      _commitAndTag(root, [
        'v0.13.0',
        '$_llamaCpp-v0.0.2',
        '$_liteRtLm-v0.0.1',
        '$_stableDiffusion-v0.0.1',
      ]);

      expect(
        checkPublishedCompanionPins(
          root,
          Version.parse('0.13.1'),
          acceptedPins: _acceptedPins,
        ),
        isEmpty,
      );
    });

    test('rejects a pin moved inside the published core minor', () {
      final root = _gitRepo();
      _writeCompanions(root, pins: {_liteRtLm: 'v1.9.0'});
      _commitAndTag(root, ['v0.13.0', '$_liteRtLm-v0.0.4']);

      expect(
        checkPublishedCompanionPins(
          root,
          Version.parse('0.13.1'),
          acceptedPins: _acceptedPins,
        ),
        [
          allOf(
            startsWith(
              '$_liteRtLm-v0.0.4 published $_liteRtLm with '
              "`llamadart: '>=0.13.0 <0.14.0'`",
            ),
            contains('beside core 0.13.1'),
            contains('leehack/litert-lm-native@v1.9.0'),
            contains('this core accepts v2.0.0'),
            contains('only in a new core minor release'),
          ),
        ],
      );
    });

    test('ignores companions whose constraint excludes this core', () {
      final root = _gitRepo();
      _writeCompanions(root, pins: {_stableDiffusion: 'v0.0.9'});
      _commitAndTag(root, ['v0.13.0', '$_stableDiffusion-v0.0.1']);

      expect(
        checkPublishedCompanionPins(
          root,
          Version.parse('0.14.0'),
          acceptedPins: _acceptedPins,
        ),
        isEmpty,
      );
    });

    test('defaults to the pins the checkout core accepts', () {
      expect(coreAcceptedCompanionPins().keys.toSet(), {
        for (final companion in companionSwiftPins) companion.package,
      });
      expect(
        coreAcceptedCompanionPins()[_llamaCpp],
        containsAll(llamaCppCompatibleAppleCompanionTags.keys),
      );
      for (final companion in companionSwiftPins) {
        final pin = companion.swiftTag
            .firstMatch(File(companion.swiftPackagePath).readAsStringSync())!
            .group(1);
        expect(
          coreAcceptedCompanionPins()[companion.package],
          contains(pin),
          reason: companion.package,
        );
      }
    });
  });

  test('release docs CLI runs both checks before reporting success', () {
    final source = File(
      'tool/testing/verify_release_docs_versions.dart',
    ).readAsStringSync();

    expect(_cliContractProblems(source), isEmpty);
    for (final mutated in [
      source.replaceFirst(
        'checkCompanionCoreConstraints(Directory.current, coreVersion)',
        'checkCompanionCoreConstraints(Directory.systemTemp, coreVersion)',
      ),
      source.replaceFirst(
        'checkPublishedCompanionPins(Directory.current, coreVersion)',
        'checkPublishedCompanionPins(Directory.systemTemp, coreVersion)',
      ),
      source.replaceFirst(
        RegExp(r'if \(releasePrep\) \{\s*errors\.addAll\(\s*checkPublished'),
        'if (false) {\n        errors.addAll(\n          checkPublished',
      ),
    ]) {
      expect(_cliContractProblems(mutated), isNotEmpty);
    }
  });
}
