// Fails when a `llamaCppBundleSha256` digest in
// lib/src/hook/native_release_pins.dart differs from the `SHA256SUMS` that the
// pinned `llamaCppTag` release publishes, so a manual pin edit cannot ship
// digests every consumer build would reject.
//
// Network-dependent: CI runs it only when the pin file changes. Pass
// `--sums-file <path>` to check against a local copy instead.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:llamadart/src/hook/native_archive_digest.dart';
import 'package:llamadart/src/hook/native_release_pins.dart';

/// GitHub repository that publishes the pinned llama.cpp runtime archives.
const String nativeReleaseRepository = 'leehack/llamadart-native';

/// Largest `SHA256SUMS` body the check reads.
const int maxSha256SumsBytes = 64 * 1024;

/// Returns one problem per pinned bundle whose digest is missing from, or
/// differs from, [checksumText] for release [tag].
List<String> nativeReleaseDigestProblems({
  required String tag,
  required Map<String, String> pins,
  required String checksumText,
  String source = 'SHA256SUMS',
}) {
  final problems = <String>[];
  for (final MapEntry(key: bundle, value: pinned) in pins.entries) {
    final archive = 'llamadart-native-$bundle-$tag.tar.gz';
    final String? published;
    try {
      published = sha256SumsEntry(
        checksumText,
        fileName: archive,
        source: source,
      );
    } on NativeArchiveDigestException catch (error) {
      return <String>[error.message];
    }
    if (published == null) {
      problems.add('$source lists no $archive');
    } else if (published != pinned) {
      problems.add('$bundle pins $pinned, but $source lists $published');
    }
  }
  return problems;
}

/// Downloads the `SHA256SUMS` body at [url], rejecting a non-200 status or a
/// body over [maxSha256SumsBytes].
Future<String> fetchSha256Sums(
  Uri url, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(url).timeout(timeout);
    final response = await request.close().timeout(timeout);
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('HTTP ${response.statusCode}', uri: url);
    }
    final bytes = <int>[];
    await for (final chunk in response.timeout(timeout)) {
      bytes.addAll(chunk);
      if (bytes.length > maxSha256SumsBytes) {
        throw HttpException('body exceeds $maxSha256SumsBytes bytes', uri: url);
      }
    }
    return utf8.decode(bytes);
  } finally {
    client.close(force: true);
  }
}

/// Runs the check and returns its exit code, writing to [out] and [err]
/// (stdout and stderr by default).
///
/// Tests call this in-process: a child `dart run` re-bundles native assets
/// that the test VM holds open, which Windows refuses to overwrite.
Future<int> run(
  List<String> args, {
  StringSink? out,
  StringSink? err,
  Future<String> Function(Uri url)? fetch,
}) async {
  out ??= stdout;
  err ??= stderr;
  if (args.isNotEmpty && (args.length != 2 || args.first != '--sums-file')) {
    err.writeln(
      'Usage: dart run tool/testing/check_native_release_digests.dart '
      '[--sums-file <path>]',
    );
    return 64;
  }
  final url = Uri.parse(
    'https://github.com/$nativeReleaseRepository/releases/download/'
    '$llamaCppTag/SHA256SUMS',
  );
  final String checksumText;
  final String source;
  try {
    if (args.isNotEmpty) {
      source = args.last;
      checksumText = File(source).readAsStringSync();
    } else {
      source = url.toString();
      checksumText = await (fetch ?? fetchSha256Sums)(url);
    }
  } on Exception catch (error) {
    err.writeln('Could not read SHA256SUMS for $llamaCppTag: $error');
    return 1;
  }
  final problems = nativeReleaseDigestProblems(
    tag: llamaCppTag,
    pins: llamaCppBundleSha256,
    checksumText: checksumText,
    source: source,
  );
  if (problems.isEmpty) {
    out.writeln(
      'llamaCppBundleSha256 matches $llamaCppTag SHA256SUMS '
      '(${llamaCppBundleSha256.length} bundles).',
    );
    return 0;
  }
  err
    ..writeln('llamaCppBundleSha256 does not match $llamaCppTag SHA256SUMS:')
    ..writeAll(problems.map((problem) => '  $problem\n'))
    ..writeln(
      'Regenerate the pins with tool/native/sync_native_release_pins.py '
      '(or the sync_native_bindings workflow) instead of editing them.',
    );
  return 1;
}

Future<void> main(List<String> args) async {
  exitCode = await run(args);
}
