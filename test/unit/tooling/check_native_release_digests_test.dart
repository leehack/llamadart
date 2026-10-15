@TestOn('vm')
library;

import 'dart:io';

import 'package:llamadart/src/hook/native_release_pins.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../../tool/testing/check_native_release_digests.dart';

String sums(Map<String, String> digests, {String tag = llamaCppTag}) => [
  for (final MapEntry(key: bundle, value: digest) in digests.entries)
    '$digest  llamadart-native-$bundle-$tag.tar.gz',
  '${'0' * 64}  llamadart-native-headers-$tag.tar.gz',
  '',
].join('\n');

void main() {
  final linux = 'a' * 64;
  final mac = 'b' * 64;
  final pinned = {'linux-x64': linux, 'macos-arm64': mac};

  test('accepts pins equal to the release SHA256SUMS', () {
    expect(
      nativeReleaseDigestProblems(
        tag: 'v1.2.3',
        pins: pinned,
        checksumText: sums(pinned, tag: 'v1.2.3'),
      ),
      isEmpty,
    );
  });

  test('reports a stale digest by bundle', () {
    expect(
      nativeReleaseDigestProblems(
        tag: 'v1.2.3',
        pins: pinned,
        checksumText: sums({...pinned, 'macos-arm64': 'c' * 64}, tag: 'v1.2.3'),
      ),
      ['macos-arm64 pins $mac, but SHA256SUMS lists ${'c' * 64}'],
    );
  });

  test('reports a pinned bundle the release does not list', () {
    expect(
      nativeReleaseDigestProblems(
        tag: 'v1.2.3',
        pins: pinned,
        checksumText: sums({'linux-x64': linux}, tag: 'v1.2.3'),
      ),
      ['SHA256SUMS lists no llamadart-native-macos-arm64-v1.2.3.tar.gz'],
    );
  });

  test('compares archives of the pinned tag only', () {
    expect(
      nativeReleaseDigestProblems(
        tag: 'v1.2.3',
        pins: pinned,
        checksumText: sums(pinned, tag: 'v1.2.2'),
      ),
      hasLength(2),
    );
  });

  test('rejects a malformed SHA256SUMS', () {
    expect(
      nativeReleaseDigestProblems(
        tag: 'v1.2.3',
        pins: pinned,
        checksumText: 'not a checksum line\n',
      ),
      [contains('malformed line 1')],
    );
  });

  group('CLI', () {
    late Directory scratch;

    setUp(() {
      scratch = Directory.systemTemp.createTempSync('native-digests-');
    });

    tearDown(() => scratch.deleteSync(recursive: true));

    Future<ProcessResult> run(Map<String, String> digests) {
      final file = File(p.join(scratch.path, 'SHA256SUMS'))
        ..writeAsStringSync(sums(digests));
      return Process.run(Platform.resolvedExecutable, [
        'run',
        'tool/testing/check_native_release_digests.dart',
        '--sums-file',
        file.path,
      ]);
    }

    test('passes for the committed pins', () async {
      final result = await run(llamaCppBundleSha256);
      expect(result.exitCode, 0, reason: '${result.stderr}');
    });

    test('fails and names the drifted bundle', () async {
      final bundle = llamaCppBundleSha256.keys.first;
      final result = await run({...llamaCppBundleSha256, bundle: 'f' * 64});
      expect(result.exitCode, 1);
      expect(result.stderr, contains('$bundle pins'));
      expect(result.stderr, contains('sync_native_release_pins.py'));
    });
  });
}
