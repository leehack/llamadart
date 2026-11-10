@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

import '../../../tool/release/pub_content_limits.dart';
import '../../support/dart_script_snapshot.dart';

const _packages = <String, String>{
  'llamadart': '.',
  'llamadart_llama_cpp_flutter': 'packages/llamadart_llama_cpp_flutter',
  'llamadart_litert_lm_flutter': 'packages/llamadart_litert_lm_flutter',
  'llamadart_stable_diffusion_flutter':
      'packages/llamadart_stable_diffusion_flutter',
};

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('pub-content-'));
  tearDown(() => root.deleteSync(recursive: true));

  void write(String path, int bytes) {
    File('${root.path}/$path')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('a' * bytes);
  }

  test('matches the limit pub.dev enforces', () {
    expect(pubContentLimitBytes, 262144);
  });

  test('accepts a file at the limit and fails one byte over', () {
    write('CHANGELOG.md', pubContentLimitBytes);
    write(
      'packages/llamadart_litert_lm_flutter/README.md',
      1 + pubContentLimitBytes,
    );

    final result = checkPubContentLimits(root, _packages);
    expect(result.errors, [
      'packages/llamadart_litert_lm_flutter/README.md is 262145 bytes; pub.dev '
          'rejects llamadart_litert_lm_flutter when it exceeds 262144 bytes. '
          'Shorten it before publishing (the core CHANGELOG.md moves its '
          'oldest releases, verbatim, to doc/changelog_archive.md).',
    ]);
    expect(result.warnings, [
      'CHANGELOG.md is 262144 bytes, within 10% of the 262144-byte limit '
          'pub.dev applies when publishing llamadart.',
    ]);
  });

  test('warns only above 90% of the limit', () {
    write('README.md', pubContentWarningBytes);
    write('LICENSE', pubContentWarningBytes + 1);

    final result = checkPubContentLimits(root, {'llamadart': '.'});
    expect(result.errors, isEmpty);
    expect(result.warnings, [startsWith('LICENSE is 235930 bytes')]);
  });

  test('counts UTF-8 bytes, not characters', () {
    // 131073 two-byte characters: under the limit in characters, over in bytes.
    File('${root.path}/CHANGELOG.md').writeAsStringSync('é' * 131073);

    expect(checkPubContentLimits(root, {'llamadart': '.'}).errors, [
      startsWith('CHANGELOG.md is 262146 bytes'),
    ]);
  });

  test('checks the example file pub.dev shows, in its priority order', () {
    write('packages/demo/example/README.md', 300000);
    write('packages/demo/example/lib/demo_example.dart', 10);
    expect(pubContentFiles(root, 'packages/demo', 'demo'), [
      'packages/demo/example/lib/demo_example.dart',
    ]);
    expect(
      checkPubContentLimits(root, {'demo': 'packages/demo'}).errors,
      isEmpty,
    );

    File(
      '${root.path}/packages/demo/example/lib/demo_example.dart',
    ).deleteSync();
    expect(pubContentFiles(root, 'packages/demo', 'demo'), [
      'packages/demo/example/README.md',
    ]);
    expect(
      checkPubContentLimits(root, {'demo': 'packages/demo'}).errors.single,
      startsWith('packages/demo/example/README.md is 300000 bytes'),
    );
  });

  test('follows pub.dev\'s full example priority order', () {
    // pub-dev's `exampleFileCandidates`, highest priority first.
    const candidates = [
      'example/example.md',
      'example/lib/main.dart',
      'example/main.dart',
      'example/lib/demo.dart',
      'example/demo.dart',
      'example/lib/demo_example.dart',
      'example/demo_example.dart',
      'example/lib/example.dart',
      'example/example.dart',
      'example/README.md',
    ];
    for (final candidate in candidates) {
      write(candidate, 1);
    }
    for (final candidate in candidates) {
      expect(pubContentFiles(root, '.', 'demo'), [candidate]);
      File('${root.path}/$candidate').deleteSync();
    }
    expect(pubContentFiles(root, '.', 'demo'), isEmpty);
  });

  test('keeps the repository\'s published content under the limit', () {
    final result = checkPubContentLimits(Directory.current, _packages);
    expect(result.errors, isEmpty);
    expect(result.warnings, isEmpty);
    expect(pubContentFiles(Directory.current, '.', 'llamadart'), [
      'README.md',
      'CHANGELOG.md',
      'LICENSE',
      'example/README.md',
    ]);
  });

  group('verify_release_docs_versions.dart', () {
    final packages = File('.dart_tool/package_config.json').absolute.path;
    late String verifier;
    setUpAll(
      () async => verifier = await compileDartScript(
        'tool/testing/verify_release_docs_versions.dart',
      ),
    );

    ProcessResult verify({required bool releasePrep}) {
      for (final MapEntry(key: name, value: path) in _packages.entries) {
        File('${root.path}/$path/pubspec.yaml')
          ..parent.createSync(recursive: true)
          ..writeAsStringSync('name: $name\nversion: 0.14.0\n');
      }
      write('website/docs/changelog/recent-releases.md', 10);
      return Process.runSync(Platform.resolvedExecutable, <String>[
        '--packages=$packages',
        verifier,
        if (releasePrep) '--release-prep',
      ], workingDirectory: root.path);
    }

    for (final releasePrep in [false, true]) {
      test('fails an oversized changelog (releasePrep: $releasePrep)', () {
        write('CHANGELOG.md', pubContentLimitBytes + 1);
        final result = verify(releasePrep: releasePrep);
        expect(result.exitCode, 1);
        expect(
          result.stderr,
          contains('- CHANGELOG.md is 262145 bytes; pub.dev rejects llamadart'),
        );
      });
    }

    for (final MapEntry(key: name, value: path) in _packages.entries.skip(1)) {
      test('fails an oversized $name README', () {
        write('$path/README.md', pubContentLimitBytes + 1);
        final result = verify(releasePrep: false);
        expect(result.exitCode, 1);
        expect(
          result.stderr,
          contains('- $path/README.md is 262145 bytes; pub.dev rejects $name'),
        );
      });
    }

    test('passes a changelog under the limit', () {
      write('CHANGELOG.md', pubContentLimitBytes);
      final result = verify(releasePrep: false);
      expect(result.stderr, isNot(contains('pub.dev rejects')));
      expect(
        result.stdout,
        contains('Warning: CHANGELOG.md is 262144 bytes, within 10%'),
      );
    });
  });
}
