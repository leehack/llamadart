@TestOn('vm')
library;

import 'dart:ffi';
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:llamadart/src/backends/litert_lm/litert_lm_runtime.dart';
import 'package:llamadart/src/hook/native_bundle_config.dart';
import 'package:llamadart/src/hook/native_release_pins.dart';
import 'package:test/test.dart';

void main() {
  final sha256Pattern = RegExp(r'^[0-9a-f]{64}$');

  test('llama.cpp tag follows the native release tag grammar', () {
    expect(isValidNativeReleaseTag(llamaCppTag), isTrue, reason: llamaCppTag);
  });

  test('compatible Apple companion tags are earlier wrapper builds of the '
      'pinned upstream llama.cpp release', () {
    // A stable wrapper tag keeps its upstream release as the vM.m.p prefix,
    // which the native release manifest binds to one upstream commit.
    final wrapper = RegExp(r'^(v\d+\.\d+\.\d+)(?:-([1-9]\d*))?$');
    final pinned = wrapper.firstMatch(llamaCppTag);
    expect(pinned, isNotNull, reason: llamaCppTag);
    final pinnedBuild = int.parse(pinned!.group(2) ?? '0');
    for (final MapEntry(key: tag, value: missing)
        in llamaCppCompatibleAppleCompanionTags.entries) {
      final match = wrapper.firstMatch(tag);
      expect(match, isNotNull, reason: tag);
      expect(match!.group(1), pinned.group(1), reason: tag);
      expect(int.parse(match.group(2) ?? '0'), lessThan(pinnedBuild));
      expect(missing.trim(), isNotEmpty, reason: tag);
    }
  });

  test('Apple companion version is the first release pinning llamaCppTag', () {
    const companion = 'packages/llamadart_llama_cpp_flutter';
    final version = RegExp(
      r'^version: (\d+)\.(\d+)\.(\d+)$',
      multiLine: true,
    ).firstMatch(File('$companion/pubspec.yaml').readAsStringSync())!;
    final changelog = File('$companion/CHANGELOG.md').readAsStringSync();
    final sections = RegExp(
      r'^## (.+)$',
      multiLine: true,
    ).allMatches(changelog).toList();
    String? firstPinning;
    for (final (index, section) in sections.indexed) {
      final end = index + 1 < sections.length
          ? sections[index + 1].start
          : changelog.length;
      if (changelog
          .substring(section.end, end)
          .contains('leehack/llamadart-native@$llamaCppTag`')) {
        firstPinning = section.group(1);
      }
    }
    final expected = firstPinning == 'Unreleased'
        ? '${version.group(1)}.${version.group(2)}.'
              '${int.parse(version.group(3)!) + 1}'
        : firstPinning;
    expect(llamaCppAppleCompanionVersion, expected);
  });

  test('llama.cpp pins a sha256 for exactly the bundles the hook selects', () {
    final selectable = <String>{
      for (final os in OS.values)
        for (final arch in Architecture.values)
          for (final isIosSimulator in const [false, true])
            ?resolveNativeBundleSpec(
              os: os,
              arch: arch,
              isIosSimulator: isIosSimulator,
            )?.bundle,
    };
    expect(llamaCppBundleSha256.keys.toSet(), selectable);
    for (final MapEntry(key: bundle, value: digest)
        in llamaCppBundleSha256.entries) {
      expect(digest, matches(sha256Pattern), reason: bundle);
    }
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
        'linux-arm64',
        'linux-x64',
        'windows-x64',
      ]),
    );
  });

  test('iOS inventory excludes the provider and retains CAPI and Metal', () {
    for (final bundle in const ['ios-arm64', 'ios-arm64-sim']) {
      final spec = liteRtLmBundleSpecs.singleWhere(
        (spec) => spec.bundle == bundle,
      );
      expect(
        spec.requiredLibraries,
        unorderedEquals(const [
          'CLiteRTLM',
          'LiteRtLm',
          'LiteRtMetalAccelerator',
          'LiteRtTopKMetalSampler',
        ]),
        reason: bundle,
      );
    }
    final mac = liteRtLmBundleSpecs.singleWhere(
      (spec) => spec.bundle == 'macos-arm64',
    );
    expect(
      mac.requiredLibraries,
      contains('libGemmaModelConstraintProvider.dylib'),
    );
  });

  test('desktop bundle specs agree with the runtime required lists', () {
    const desktopBundles = {
      'macos-arm64': Abi.macosArm64,
      'linux-arm64': Abi.linuxArm64,
      'linux-x64': Abi.linuxX64,
      'windows-x64': Abi.windowsX64,
    };
    for (final entry in desktopBundles.entries) {
      final spec = liteRtLmBundleSpecs.singleWhere(
        (spec) => spec.bundle == entry.key,
      );
      expect(
        liteRtLmRequiredLibrariesForAbi(entry.value),
        unorderedEquals(spec.requiredLibraries),
        reason: entry.key,
      );
    }
  });

  test('stable_diffusion cache version is the release tag without its v', () {
    expect(
      stableDiffusionReleaseTag,
      matches(RegExp(r'^v\d+\.\d+\.\d+(?:-[1-9]\d*)?$')),
    );
    expect(stableDiffusionVersion, stableDiffusionReleaseTag.substring(1));
  });

  test('stable_diffusion bundle specs pin one library and a sha256 each', () {
    final bundles = stableDiffusionBundleSpecs
        .map((spec) => spec.bundle)
        .toList();
    expect(bundles.toSet(), hasLength(bundles.length));
    for (final spec in stableDiffusionBundleSpecs) {
      expect(spec.sha256, matches(sha256Pattern), reason: spec.bundle);
      expect(spec.requiredLibraries, hasLength(1), reason: spec.bundle);
      final library = spec.requiredLibraries.single;
      expect(library, switch (spec.bundle.split('-').first) {
        'windows' => 'stable-diffusion.dll',
        'android' || 'linux' => 'libstable-diffusion.so',
        _ => 'libstable-diffusion.dylib',
      }, reason: spec.bundle);
    }
  });

  test('stable_diffusion specs cover every bundle the hook can select', () {
    final specs = stableDiffusionBundleSpecs.map((spec) => spec.bundle).toSet();
    final selectable = <String>{};
    for (final os in OS.values) {
      for (final arch in Architecture.values) {
        for (final isIosSimulator in const [false, true]) {
          final nativeSpec = resolveNativeBundleSpec(
            os: os,
            arch: arch,
            isIosSimulator: isIosSimulator,
          );
          if (nativeSpec == null) continue;
          for (final rawBackendConfig in [
            null,
            {
              'platforms': {nativeSpec.bundle: 'cpu'},
            },
          ]) {
            final bundle = stableDiffusionBundleForNativeBundle(
              spec: nativeSpec,
              rawBackendConfig: rawBackendConfig,
            );
            if (bundle != null) selectable.add(bundle);
          }
        }
      }
    }
    expect(selectable, specs);
  });
}
