@TestOn('vm')
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:llamadart/src/backends/litert_lm/litert_lm_runtime.dart';
import 'package:llamadart/src/hook/native_bundle_config.dart';
import 'package:llamadart/src/hook/native_release_manifest.dart';
import 'package:llamadart/src/hook/native_release_pins.dart';
import 'package:test/test.dart';

void main() {
  final sha256Pattern = RegExp(r'^[0-9a-f]{64}$');

  test('llama.cpp pins the approved v1.1.0 release', () {
    expect(llamaCppTag, 'v1.1.0');
  });

  test('llama.cpp tag follows the native release tag grammar', () {
    expect(isValidNativeReleaseTag(llamaCppTag), isTrue, reason: llamaCppTag);
  });

  group('Apple llama.cpp compatibility', () {
    test('binds the current XCFramework checksum to the companion pin', () {
      final manifest = File(
        'packages/llamadart_llama_cpp_flutter/darwin/'
        'llamadart_llama_cpp_flutter/Package.swift',
      ).readAsStringSync();
      expect(
        llamaCppCompatibleAppleCompanionChecksums[llamaCppTag],
        matches(sha256Pattern),
      );
      expect(
        manifest,
        contains(
          'checksum: "${llamaCppCompatibleAppleCompanionChecksums[llamaCppTag]}"',
        ),
      );
      expect(manifest, contains('let llamaCppTag = "$llamaCppTag"'));
    });

    test('admits no earlier companion without its own checksum proof', () {
      expect(
        llamaCppCompatibleAppleCompanionChecksums.keys,
        unorderedEquals({
          llamaCppTag,
          ...llamaCppCompatibleAppleCompanionTags.keys,
        }),
      );
    });
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

  test('llama.cpp pins a hook contract this hook supports', () {
    expect(
      supportedNativeHookContractVersions,
      contains(llamaCppHookContractVersion),
    );
  });

  test('llama.cpp backend sidecars extend a pinned bundle once each', () {
    final keys = <String>{};
    for (final spec in llamaCppBackendSidecarSpecs) {
      expect(llamaCppBundleSha256, contains(spec.bundle), reason: spec.archive);
      expect(spec.archive, startsWith('${spec.bundle}-'));
      expect(llamaCppBundleSha256, isNot(contains(spec.archive)));
      expect(spec.sha256, matches(sha256Pattern), reason: spec.archive);
      expect(keys.add('${spec.bundle}/${spec.backend}'), isTrue);
    }
    if (llamaCppHookContractVersion < 2) {
      expect(llamaCppBackendSidecarSpecs, isEmpty);
    }
  });

  test('LiteRT-LM cache version is the release tag without its v prefix', () {
    expect(liteRtLmReleaseTag, startsWith('v'));
    expect(liteRtLmVersion, liteRtLmReleaseTag.substring(1));
  });

  test('LiteRT-LM SwiftPM targets match the v0.20.0 manifest', () {
    final manifest =
        jsonDecode(
              File(
                'test/fixtures/native/litert_lm_v0_20_0_manifest.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    final tag = (manifest['release'] as Map<String, dynamic>)['tag'];
    expect(liteRtLmReleaseTag, tag);
    final artifacts = (manifest['artifacts'] as List)
        .cast<Map<String, dynamic>>();
    final swift = File(
      'packages/llamadart_litert_lm_flutter/darwin/'
      'llamadart_litert_lm_flutter/Package.swift',
    ).readAsStringSync();
    expect(swift, contains('let liteRtLmTag = "$tag"'));
    expect(
      swift,
      contains(
        r'url: "https://github.com/\(repository)/releases/download/\(tag)/\(artifactName)"',
      ),
    );
    final targets = RegExp(
      r'nativeRepoBinaryTarget\(\s*name: "([^"]+)",\s*'
      r'repository: "([^"]+)",\s*artifactName: "([^"]+)",\s*'
      r'tag: liteRtLmTag,\s*checksum: "([^"]+)"\s*\)',
    ).allMatches(swift).toList();
    const names = ['LiteRtLm', 'CLiteRTLM', 'CLiteRTLMMac', 'WebgpuDawn'];
    expect(targets.map((target) => target.group(1)), unorderedEquals(names));
    expect(
      RegExp(r'nativeRepoBinaryTarget\(').allMatches(swift).length,
      names.length + 1,
      reason: 'one helper declaration and four target calls',
    );
    for (final name in names) {
      final target = targets.singleWhere((target) => target.group(1) == name);
      final fileName = 'litert-lm-native-apple-$name-xcframework-$tag.zip';
      final artifact = artifacts.singleWhere(
        (artifact) => artifact['fileName'] == fileName,
      );
      expect(artifact['releaseTag'], tag, reason: name);
      expect(
        target.group(2),
        (manifest['native'] as Map)['repository'],
        reason: name,
      );
      expect(
        target.group(3)!.replaceAll(r'\(liteRtLmTag)', '$tag'),
        fileName,
        reason: name,
      );
      expect(target.group(4), artifact['sha256'], reason: '$name checksum');
    }
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

  test('iOS inventory excludes the provider and the Metal accelerator', () {
    for (final bundle in const ['ios-arm64', 'ios-arm64-sim']) {
      final spec = liteRtLmBundleSpecs.singleWhere(
        (spec) => spec.bundle == bundle,
      );
      expect(
        spec.requiredLibraries,
        unorderedEquals(const ['CLiteRTLM', 'LiteRtLm']),
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

  test('desktop bundle specs agree with the C API 1 required lists', () {
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
        liteRtLmRequiredLibrariesForAbi(entry.value, cApiV1: true),
        unorderedEquals(spec.requiredLibraries),
        reason: entry.key,
      );
    }
  });

  test(
    'legacy overrides retain their prebuilt accelerator and sampler requirements',
    () {
      const samplers = {
        Abi.macosArm64: [
          'libLiteRt.dylib',
          'libLiteRtMetalAccelerator.dylib',
          'libLiteRtTopKMetalSampler.dylib',
          'libLiteRtTopKWebGpuSampler.dylib',
          'libLiteRtWebGpuAccelerator.dylib',
        ],
        Abi.linuxArm64: ['libLiteRtTopKWebGpuSampler.so'],
        Abi.linuxX64: ['libLiteRtTopKWebGpuSampler.so'],
        Abi.windowsX64: ['libLiteRtTopKWebGpuSampler.dll'],
      };
      // v0.18.x Linux and Windows hosts import the prebuilt libLiteRt that
      // C API 1 hosts from v0.19.1-1 link in.
      const liteRt = {
        Abi.linuxArm64: ['libLiteRt.so'],
        Abi.linuxX64: ['libLiteRt.so'],
        Abi.windowsX64: ['libLiteRt.dll'],
      };
      for (final entry in samplers.entries) {
        final modern = liteRtLmRequiredLibrariesForAbi(entry.key, cApiV1: true);
        expect(
          liteRtLmRequiredLibrariesForAbi(entry.key),
          unorderedEquals({
            ...modern,
            ...entry.value,
            ...?liteRt[entry.key],
            ...liteRtLmOptionalCompanionLibrariesForAbi(entry.key),
          }),
          reason: entry.key.toString(),
        );
        for (final sampler in entry.value) {
          expect(
            modern,
            isNot(contains(sampler)),
            reason: entry.key.toString(),
          );
        }
      }
    },
  );

  test('stable_diffusion pins the published v0.4.0-1 release artifacts', () {
    // Exact published owner manifest, independently checked against GitHub
    // asset digests before adoption. This also binds the Apple binary target.
    final manifestBytes = File(
      'test/fixtures/native/stable_diffusion_v0_4_0_1_manifest.json',
    ).readAsBytesSync();
    expect(
      sha256.convert(manifestBytes).toString(),
      '2468c584c4bf948475d37d78f3288363c7a3f08d8a2b23d8d5b952ab5b2d4bc5',
    );
    final manifest =
        jsonDecode(utf8.decode(manifestBytes)) as Map<String, dynamic>;
    expect(stableDiffusionReleaseTag, manifest['tag']);
    final artifacts = (manifest['artifacts'] as List)
        .cast<Map<String, dynamic>>();
    final runtimes = {
      for (final artifact in artifacts)
        if (artifact['kind'] == 'runtime') artifact['target']: artifact,
    };
    expect(
      stableDiffusionBundleSpecs.map((spec) => spec.bundle).toSet(),
      runtimes.keys.toSet(),
    );
    for (final spec in stableDiffusionBundleSpecs) {
      expect(
        spec.sha256,
        runtimes[spec.bundle]!['sha256'],
        reason: spec.bundle,
      );
      final artifact = runtimes[spec.bundle]!;
      expect(spec.primaryLibrary, artifact['library'], reason: spec.bundle);
      expect(
        spec.requiredLibraries,
        unorderedEquals(
          artifact['libraries'] as List? ?? [artifact['library']],
        ),
        reason: spec.bundle,
      );
    }
    final apple = artifacts.singleWhere(
      (artifact) =>
          artifact['file'] ==
          'stable-diffusion-native-apple-xcframework-v0.4.0-1.zip',
    );
    final swift = File(
      'packages/llamadart_stable_diffusion_flutter/darwin/'
      'llamadart_stable_diffusion_flutter/Package.swift',
    ).readAsStringSync();
    expect(swift, contains('let stableDiffusionTag = "${manifest['tag']}"'));
    expect(swift, contains('checksum: "${apple['sha256']}"'));
    expect(stableDiffusionCompatibleAppleCompanionTags, {
      'v0.4.0':
          'no Apple changes (v0.4.0-1 only bundles Windows Visual C++ runtime DLLs)',
    });
    expect(stableDiffusionAppleCompanionChecksums, {
      stableDiffusionReleaseTag: apple['sha256'],
      'v0.4.0': apple['sha256'],
    });
  });

  test('Apple SD companion version is the first release pinning '
      'stableDiffusionReleaseTag', () {
    const companion = 'packages/llamadart_stable_diffusion_flutter';
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
          .contains(
            'leehack/stable-diffusion-native@$stableDiffusionReleaseTag`',
          )) {
        firstPinning = section.group(1);
      }
    }
    expect(firstPinning, anyOf('Unreleased', '0.20.7'));
    expect(stableDiffusionAppleCompanionVersion, '0.20.7');
  });

  test('stable_diffusion cache version is the release tag without its v', () {
    expect(
      stableDiffusionReleaseTag,
      matches(RegExp(r'^v\d+\.\d+\.\d+(?:-[1-9]\d*)?$')),
    );
    expect(stableDiffusionVersion, stableDiffusionReleaseTag.substring(1));
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
