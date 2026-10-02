@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

import '../../../tool/release/companion_pub_preflight.dart';
import '../../../tool/testing/release_metadata_readiness.dart';
import '../../../tool/testing/verify_release_docs_versions.dart';

/// Every hand-maintained companion list must name each Flutter Apple companion
/// checked out under `packages/`, so a removed or misspelled entry fails here.
void main() {
  final companions = discoverAppleCompanionPackages(Directory.current);

  test('the companion inventory is discovered', () {
    expect(
      companions.map((companion) => companion.name),
      contains('llamadart_stable_diffusion_flutter'),
    );
  });

  for (final companion in companions) {
    group(companion.name, () {
      test('release metadata docs include its README', () {
        final readme = '${companion.path}/README.md';
        expect(releaseMetadataDocs, contains(readme));
        expect(File(readme).existsSync(), isTrue);
      });

      test('the release docs verifier reads its pubspec', () {
        final pubspec = File(packagePubspecPath(companion.name));
        expect(pubspec.path, '${companion.path}/pubspec.yaml');
        expect(
          pubspec.readAsStringSync(),
          contains('name: ${companion.name}\n'),
        );
      });

      test('the release docs verifier checks its SwiftPM pin', () {
        final pin = companionSwiftPins.singleWhere(
          (pin) => pin.package == companion.name,
        );
        expect(pin.root, companion.path);
        expect(
          pin.swiftTag.hasMatch(File(pin.swiftPackagePath).readAsStringSync()),
          isTrue,
        );
      });

      test('release automation can publish it', () {
        final release = File(
          '.github/workflows/release_on_prep_merge.yml',
        ).readAsStringSync();
        final publish = File(
          '.github/workflows/publish_companion_pubdev.yml',
        ).readAsStringSync();

        expect(release, contains('            ${companion.path}\n'));
        expect(
          publish,
          contains("      - '${companion.name}-v[0-9]+.[0-9]+.[0-9]+*'"),
        );
        expect(publish, contains('package_path="${companion.path}"'));
      });
    });
  }

  test(
    'the release docs verifier pins no companion that is not checked out',
    () {
      expect(
        companionSwiftPins.map((pin) => pin.package).toSet(),
        companions.map((companion) => companion.name).toSet(),
      );
    },
  );
}
