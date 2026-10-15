@TestOn('vm')
library;

import 'dart:io';

import 'package:llamadart/src/hook/native_release_pins.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../../tool/testing/check_native_release_digests.dart';
import '../../../tool/testing/check_native_release_digests.dart'
    as check_native_release_digests;

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
    late StringBuffer out;
    late StringBuffer err;

    setUp(() {
      scratch = Directory.systemTemp.createTempSync('native-digests-');
      out = StringBuffer();
      err = StringBuffer();
    });

    tearDown(() => scratch.deleteSync(recursive: true));

    Future<int> runWith(Map<String, String> digests) {
      final file = File(p.join(scratch.path, 'SHA256SUMS'))
        ..writeAsStringSync(sums(digests));
      return run(['--sums-file', file.path], out: out, err: err);
    }

    test('passes for the committed pins', () async {
      expect(await runWith(llamaCppBundleSha256), 0, reason: '$err');
      expect(out.toString(), contains('matches $llamaCppTag'));
    });

    test('fails and names the drifted bundle', () async {
      final bundle = llamaCppBundleSha256.keys.first;
      expect(await runWith({...llamaCppBundleSha256, bundle: 'f' * 64}), 1);
      expect(err.toString(), contains('$bundle pins'));
      expect(err.toString(), contains('sync_native_release_pins.py'));
    });

    test('fetches the pinned release SHA256SUMS without --sums-file', () async {
      Uri? fetched;
      final code = await run(
        const [],
        out: out,
        err: err,
        fetch: (url) async {
          fetched = url;
          return sums(llamaCppBundleSha256);
        },
      );
      expect(code, 0, reason: '$err');
      expect(fetched?.path, endsWith('/$llamaCppTag/SHA256SUMS'));
    });

    test('fails when SHA256SUMS cannot be read', () async {
      final code = await run(
        ['--sums-file', p.join(scratch.path, 'missing')],
        out: out,
        err: err,
      );
      expect(code, 1);
      expect(err.toString(), contains('Could not read SHA256SUMS'));
    });

    test('rejects unknown arguments with a usage error', () async {
      for (final args in [
        ['--bogus'],
        ['--bogus', 'x'],
        ['--sums-file'],
        ['--sums-file', 'a', 'b'],
      ]) {
        err.clear();
        expect(
          await run(args, out: out, err: err),
          64,
          reason: '$args',
        );
        expect(err.toString(), contains('Usage:'), reason: '$args');
      }
    });

    test('main sets the process exit code', () async {
      final bundle = llamaCppBundleSha256.keys.first;
      final file = File(p.join(scratch.path, 'SHA256SUMS'))
        ..writeAsStringSync(sums({...llamaCppBundleSha256, bundle: 'f' * 64}));
      addTearDown(() => exitCode = 0);
      await check_native_release_digests.main(['--sums-file', file.path]);
      expect(exitCode, 1);
    });
  });

  group('fetchSha256Sums', () {
    late HttpServer server;
    late Uri url;
    var status = HttpStatus.ok;
    var body = '';

    setUp(() async {
      status = HttpStatus.ok;
      body = '';
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      url = Uri.parse(
        'http://${server.address.host}:${server.port}/SHA256SUMS',
      );
      server.listen((request) {
        request.response
          ..statusCode = status
          ..write(body)
          ..close();
      });
    });

    tearDown(() => server.close(force: true));

    test('returns a body of exactly the size limit', () async {
      body = 'a' * maxSha256SumsBytes;
      expect(await fetchSha256Sums(url), body);
    });

    test('rejects a body over the size limit', () async {
      body = 'a' * (maxSha256SumsBytes + 1);
      await expectLater(
        fetchSha256Sums(url),
        throwsA(
          isA<HttpException>().having(
            (error) => error.message,
            'message',
            contains('body exceeds'),
          ),
        ),
      );
    });

    test('rejects a non-200 response', () async {
      status = HttpStatus.notFound;
      await expectLater(
        fetchSha256Sums(url),
        throwsA(
          isA<HttpException>().having(
            (error) => error.message,
            'message',
            'HTTP 404',
          ),
        ),
      );
    });
  });
}
