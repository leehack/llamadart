#!/usr/bin/env dart

/// Fails a release before any tag is pushed when a Flutter Apple companion
/// package does not exist on pub.dev yet.
///
/// `release_on_prep_merge.yml` pushes a `<package>-v<version>` tag for every
/// companion version missing from pub.dev, but pub.dev automated publishing
/// cannot create a package: the tag's publish job would fail, the release
/// would wait for a version that never appears, and the core tag would never
/// be pushed. The owner publishes a package's first version by hand instead.
///
/// ```bash
/// dart run tool/release/companion_pub_preflight.dart
/// ```
library;

import 'dart:io';

/// A Flutter Apple SwiftPM companion package checked out under `packages/`.
typedef CompanionPackage = ({String name, String path});

/// Every Flutter Apple companion package under [repoRoot]: a `packages/<name>`
/// directory with a `darwin/<name>/Package.swift` manifest, sorted by name.
List<CompanionPackage> discoverAppleCompanionPackages(Directory repoRoot) {
  final packages = Directory('${repoRoot.path}/packages');
  if (!packages.existsSync()) return const [];
  return [
    for (final directory in packages.listSync().whereType<Directory>())
      if (File(
        '${directory.path}/darwin/${_baseName(directory.path)}/Package.swift',
      ).existsSync())
        (
          name: _baseName(directory.path),
          path: 'packages/${_baseName(directory.path)}',
        ),
  ]..sort((a, b) => a.name.compareTo(b.name));
}

/// The pub.dev endpoint that answers 200 once [package] exists.
Uri pubDevPackageUri(String package) =>
    Uri.https('pub.dev', '/api/packages/$package');

/// Problems that must stop the release before any tag is pushed: one per
/// companion missing from pub.dev, with the owner's first-publish steps, or
/// one per companion whose presence could not be confirmed. [statusOf]
/// returns the HTTP status of a GET, or throws when the request fails.
Future<List<String>> companionPubPreflightProblems(
  List<CompanionPackage> companions,
  Future<int> Function(Uri uri) statusOf,
) async {
  final problems = <String>[];
  for (final companion in companions) {
    final uri = pubDevPackageUri(companion.name);
    final int status;
    try {
      status = await statusOf(uri);
    } on Object catch (error) {
      problems.add(
        'Could not confirm ${companion.name} exists on pub.dev ($uri): '
        '$error. No release tags were pushed; retry once pub.dev answers.',
      );
      continue;
    }
    if (status == HttpStatus.ok) continue;
    if (status == HttpStatus.notFound) {
      problems.add(firstPublishInstructions(companion));
      continue;
    }
    problems.add(
      'Could not confirm ${companion.name} exists on pub.dev: $uri answered '
      'HTTP $status. No release tags were pushed; retry once pub.dev answers '
      '200.',
    );
  }
  return problems;
}

/// What the owner must do before automation can publish [companion].
String firstPublishInstructions(CompanionPackage companion) {
  final name = companion.name;
  return '''
$name does not exist on pub.dev yet, and pub.dev automated publishing cannot
create a package, so no release tags were pushed. Before rerunning this
release, the package owner must:
  1. Publish the first version by hand from a temporary copy of ${companion.path}:
       tmp_package="\$(mktemp -d)"
       rsync -a --delete --exclude='.dart_tool' --exclude='build' \\
         --exclude='pubspec.lock' ${companion.path}/ "\$tmp_package/"
       (cd "\$tmp_package" && flutter pub publish)
  2. On https://pub.dev/packages/$name/admin, transfer the package to the
     leehack.com publisher.
  3. On the same page, enable automated publishing from GitHub Actions for
     repository leehack/llamadart with tag pattern $name-v{{version}}.''';
}

Future<int> _httpStatus(Uri uri) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  try {
    final request = await client.getUrl(uri);
    final response = await request.close().timeout(const Duration(seconds: 60));
    await response.drain<void>();
    return response.statusCode;
  } finally {
    client.close(force: true);
  }
}

String _baseName(String path) =>
    path.split(RegExp(r'[/\\]')).where((part) => part.isNotEmpty).last;

Future<void> main(List<String> arguments) async {
  if (arguments.isNotEmpty) {
    stderr.writeln('Usage: dart run tool/release/companion_pub_preflight.dart');
    exitCode = 64;
    return;
  }
  final companions = discoverAppleCompanionPackages(Directory.current);
  if (companions.isEmpty) {
    stderr.writeln(
      'No Flutter Apple companion packages found under packages/.',
    );
    exitCode = 1;
    return;
  }
  final problems = await companionPubPreflightProblems(companions, _httpStatus);
  if (problems.isNotEmpty) {
    stderr.writeln('Companion pub.dev preflight failed:');
    problems.forEach(stderr.writeln);
    exitCode = 1;
    return;
  }
  stdout.writeln(
    'Companion packages exist on pub.dev: '
    '${companions.map((companion) => companion.name).join(', ')}.',
  );
}
