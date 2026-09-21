@TestOn('vm')
library;

import 'package:llamadart/src/hook/native_bundle_config.dart';
import 'package:llamadart/src/hook/native_release_pins.dart';
import 'package:test/test.dart';

void main() {
  final sha256Pattern = RegExp(r'^[0-9a-f]{64}$');

  test('llama.cpp tag follows the native release tag grammar', () {
    expect(isValidNativeReleaseTag(llamaCppTag), isTrue, reason: llamaCppTag);
  });

  test('LiteRT-LM cache version is the release tag without its v prefix', () {
    expect(liteRtLmReleaseTag, startsWith('v'));
    expect(liteRtLmVersion, liteRtLmReleaseTag.substring(1));
  });

  test('LiteRT-LM bundle specs are unique and pin a sha256 each', () {
    final bundles = liteRtLmBundleSpecs.map((spec) => spec.bundle).toList();
    expect(bundles.toSet(), hasLength(bundles.length));
    for (final spec in liteRtLmBundleSpecs) {
      expect(spec.bundle, matches(RegExp(r'^[a-z]+-[a-z0-9]+(-sim)?$')));
      expect(spec.sha256, matches(sha256Pattern), reason: spec.bundle);
      expect(spec.requiredLibraries, isNotEmpty, reason: spec.bundle);
    }
  });

  test('LiteRT-LM bundle specs cover every hook-selectable bundle', () {
    expect(
      liteRtLmBundleSpecs.map((spec) => spec.bundle),
      unorderedEquals(const [
        'android-arm64',
        'android-x64',
        'ios-arm64',
        'ios-arm64-sim',
        'macos-arm64',
        'macos-x64',
        'linux-arm64',
        'linux-x64',
        'windows-x64',
      ]),
    );
  });
}
