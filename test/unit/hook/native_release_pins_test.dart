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

  test('llama.cpp pins the approved v1.0.0-3 release', () {
    expect(llamaCppTag, 'v1.0.0-3');
  });

  test('llama.cpp tag follows the native release tag grammar', () {
    expect(isValidNativeReleaseTag(llamaCppTag), isTrue, reason: llamaCppTag);
  });

  group('Apple llama.cpp compatibility', () {
    final proof =
        jsonDecode(
              File(
                'test/fixtures/native/llama_cpp_apple_compatibility.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;

    final checksums = (proof['xcframework_checksums'] as Map)
        .cast<String, String>();
    final published = (proof['published_companion_tags'] as Map)
        .cast<String, String>();

    test('is bound to the verified artifacts', () {
      expect(proof['current_tag'], llamaCppTag);
      expect(published, isNotEmpty);
      expect(
        llamaCppCompatibleAppleCompanionTags.keys,
        unorderedEquals(published.values.toSet()),
      );
      for (final description in llamaCppCompatibleAppleCompanionTags.values) {
        expect(description.trim(), isNotEmpty);
      }
      expect(llamaCppCompatibleAppleCompanionChecksums, checksums);
      expect(
        File(
          'packages/llamadart_llama_cpp_flutter/darwin/'
          'llamadart_llama_cpp_flutter/Package.swift',
        ).readAsStringSync(),
        contains('checksum: "${checksums[llamaCppTag]}"'),
      );
    });

    test('checked every framework slice', () {
      final slices = proof['slices'] as List<dynamic>;
      expect(proof['core_symbols_checked'], greaterThan(0));
      expect(
        slices.cast<Map<String, dynamic>>().map(
          (slice) => (slice['library'], slice['architecture']),
        ),
        unorderedEquals([
          ('ios-arm64', 'arm64'),
          ('ios-arm64_x86_64-simulator', 'arm64'),
          ('ios-arm64_x86_64-simulator', 'x86_64'),
          ('macos-arm64_x86_64', 'arm64'),
          ('macos-arm64_x86_64', 'x86_64'),
        ]),
      );
      for (final slice in slices.cast<Map<String, dynamic>>()) {
        final missing = slice['missing_core_symbols'] as Map<String, dynamic>;
        expect(missing.keys, unorderedEquals(checksums.keys));
        expect(missing.values, everyElement(isEmpty));
      }
    });

    test('names the checksum the published companions declare', () {
      for (final MapEntry(key: tag, value: nativeTag) in published.entries) {
        final checksum = checksums[nativeTag];
        expect(checksum, isNotNull);
        final ref = 'refs/tags/$tag';
        final tagExists =
            Process.runSync('git', [
              'show-ref',
              '--verify',
              '--quiet',
              ref,
            ]).exitCode ==
            0;
        if (!tagExists &&
            Platform.environment['LLAMADART_REQUIRE_PUBLISHED_COMPANION_TAGS'] !=
                '1') {
          continue;
        }
        final shown = Process.runSync('git', [
          'show',
          '$ref:packages/llamadart_llama_cpp_flutter/darwin/'
              'llamadart_llama_cpp_flutter/Package.swift',
        ]);
        expect(shown.exitCode, 0, reason: '$ref: ${shown.stderr}');
        final manifest = shown.stdout as String;
        expect(
          manifest,
          contains('let llamaCppTag = "$nativeTag"'),
          reason: tag,
        );
        expect(manifest, contains('checksum: "$checksum"'), reason: tag);
      }
    });

    test('core stays off what only the pinned runtime has', () {
      final changedTypes =
          (proof['types_changed_and_unused_by_core'] as List<dynamic>)
              .cast<String>();
      final bindings = RegExp(r'(^|/)(stable_diffusion_)?bindings\.dart$');
      final word = RegExp(r'[A-Za-z_][A-Za-z_0-9]*');
      final llamaBindings = File(
        'lib/src/backends/llama_cpp/bindings.dart',
      ).readAsStringSync();
      final dependingOnChangedTypes = <String>{
        for (final match in RegExp(
          r'^(?:external\s+[^;]*?|[\w.<>]+\s+)\b(\w+)\([^;{]*?\)\s*[;{]',
          multiLine: true,
        ).allMatches(llamaBindings))
          if (word
              .allMatches(match[0]!)
              .any((w) => changedTypes.contains(w[0])))
            match[1]!,
      };
      final forbidden = <String>{
        ...(proof['current_only_symbols'] as List<dynamic>).cast<String>(),
        ...changedTypes,
        ...dependingOnChangedTypes,
      };
      final uses = <String>[];
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File ||
            !entity.path.endsWith('.dart') ||
            bindings.hasMatch(entity.path.replaceAll(r'\', '/'))) {
          continue;
        }
        final source = entity.readAsStringSync();
        for (final match in word.allMatches(source)) {
          if (forbidden.contains(match[0])) {
            uses.add('${entity.path}: ${match[0]}');
          }
        }
      }
      expect(
        uses,
        isEmpty,
        reason:
            'An admitted companion lacks these or lays them out differently. '
            'Probe the runtime '
            'first, then move the name out of the fixture.',
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

  test('LiteRT-LM SwiftPM targets match the published owner manifest', () {
    // Published manifest SHA-256 b8d5d196e1c9c64026aad52ae14a9909228eabe6eceb4837a7cab60fffe58d9f;
    // verified against GitHub asset metadata and the independent #2003 receipt.
    final manifest =
        jsonDecode(
              File(
                'test/fixtures/native/litert_lm_v0_19_1_5_manifest.json',
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

  test('desktop bundle specs agree with the C API 1.0 required lists', () {
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
          unorderedEquals([...modern, ...entry.value, ...?liteRt[entry.key]]),
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

  test('stable_diffusion pins the published v0.4.0 release artifacts', () {
    // Exact published owner manifest, independently checked against GitHub
    // asset digests before adoption. This also binds the Apple binary target.
    final manifestBytes = File(
      'test/fixtures/native/stable_diffusion_v0_4_0_manifest.json',
    ).readAsBytesSync();
    expect(
      sha256.convert(manifestBytes).toString(),
      'bed5598df5a62914b48a3c0652701df9819cb2405f6346c692e2494dccfeb927',
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
      expect(spec.requiredLibraries, {
        runtimes[spec.bundle]!['library'],
      }, reason: spec.bundle);
    }
    final apple = artifacts.singleWhere(
      (artifact) =>
          artifact['file'] ==
          'stable-diffusion-native-apple-xcframework-v0.4.0.zip',
    );
    final swift = File(
      'packages/llamadart_stable_diffusion_flutter/darwin/'
      'llamadart_stable_diffusion_flutter/Package.swift',
    ).readAsStringSync();
    expect(swift, contains('let stableDiffusionTag = "${manifest['tag']}"'));
    expect(swift, contains('checksum: "${apple['sha256']}"'));
    expect(stableDiffusionCompatibleAppleCompanionTags, isEmpty);
    expect(stableDiffusionAppleCompanionChecksums, {
      stableDiffusionReleaseTag: apple['sha256'],
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
    // v0.4.0 breaks the image generation parameter ABI of the 0.19.x pair.
    expect(firstPinning, anyOf('Unreleased', '0.20.0'));
    expect(stableDiffusionAppleCompanionVersion, '0.20.0');
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
