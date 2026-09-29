@TestOn('vm')
library;

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import 'package:llamadart/src/hook/native_release_pins.dart';

import '../../../hook/build.dart' as build_hook;

const _stableDiffusionAssetId = 'package:llamadart/stable_diffusion';
const _primaryAssetId = 'package:llamadart/llamadart';

void main() {
  final nativeBundlesRoot = '.dart_tool/llamadart/native_bundles/$llamaCppTag';
  final stableDiffusionRoot =
      '.dart_tool/llamadart/stable_diffusion/$stableDiffusionVersion';

  Directory nativeBundle(String bundle) =>
      Directory('$nativeBundlesRoot/$bundle/extracted');
  Directory stableDiffusionBundle(String bundle) =>
      Directory('$stableDiffusionRoot/$bundle');

  final nativeBundles = {
    'linux-x64': const [
      'libllamadart.so',
      'libllama.so',
      'libggml.so',
      'libggml-base.so',
      'libggml-cpu.so',
      'libggml-vulkan.so',
    ],
    'android-x64': const [
      'libllamadart.so',
      'libllama.so',
      'libggml.so',
      'libggml-base.so',
      'libggml-cpu.so',
    ],
    'macos-arm64': const ['libllamadart.dylib'],
  };
  final stableDiffusionBundles = {
    for (final spec in stableDiffusionBundleSpecs)
      if (const {
        'linux-x64',
        'linux-x64-vulkan',
        'macos-arm64',
        'ios-arm64',
      }.contains(spec.bundle))
        spec.bundle: spec.requiredLibraries.single,
  };
  final liteRtLmLinuxBundle = Directory(
    '.dart_tool/llamadart/litert_lm/$liteRtLmVersion/linux/x64',
  );
  final backups = [
    for (final bundle in nativeBundles.keys) nativeBundle(bundle),
    for (final bundle in stableDiffusionBundles.keys)
      stableDiffusionBundle(bundle),
    liteRtLmLinuxBundle,
  ];

  setUpAll(() async {
    for (final directory in backups) {
      await _moveDirectory(directory, _backupOf(directory));
    }
  });

  setUp(() async {
    for (final MapEntry(key: bundle, value: libraries)
        in nativeBundles.entries) {
      await _writeLibraries(nativeBundle(bundle), {
        for (final library in libraries) library: 'fake-$library',
      });
    }
    for (final MapEntry(key: bundle, value: library)
        in stableDiffusionBundles.entries) {
      await _writeLibraries(stableDiffusionBundle(bundle), {
        library: 'fake-sd-$bundle',
      });
    }
    await _writeLibraries(liteRtLmLinuxBundle, {
      for (final library
          in liteRtLmBundleSpecs
              .singleWhere((spec) => spec.bundle == 'linux-x64')
              .requiredLibraries)
        library: 'fake-$library',
    });
  });

  tearDownAll(() async {
    for (final directory in backups.reversed) {
      if (directory.existsSync()) {
        await directory.delete(recursive: true);
      }
      await _moveDirectory(_backupOf(directory), directory);
    }
  });

  test('default and all selections never bundle stable_diffusion', () async {
    final vulkanCache = stableDiffusionBundle('linux-x64-vulkan');
    await vulkanCache.delete(recursive: true);
    for (final defines in <Map<String, Object?>>[
      {},
      {
        'llamadart_native_runtimes': ['all'],
      },
      {'llamadart_native_runtimes': 'both'},
    ]) {
      await testCodeBuildHook(
        mainMethod: build_hook.main,
        targetOS: OS.linux,
        targetArchitecture: Architecture.x64,
        userDefines: _userDefines(defines),
        check: (_, output) {
          final ids = _codeAssetIds(output);
          expect(ids, contains(_primaryAssetId), reason: '$defines');
          expect(ids, isNot(contains(_stableDiffusionAssetId)));
        },
      );
      expect(
        vulkanCache.existsSync(),
        isFalse,
        reason: 'nothing may be downloaded without opting in: $defines',
      );
    }
  });

  test('Linux bundles the Vulkan archive with default backends', () async {
    await testCodeBuildHook(
      mainMethod: build_hook.main,
      targetOS: OS.linux,
      targetArchitecture: Architecture.x64,
      userDefines: _userDefines({
        'llamadart_native_runtimes': ['llama_cpp', 'stable_diffusion'],
      }),
      check: (_, output) {
        expect(_codeAssetIds(output), contains(_primaryAssetId));
        final asset = _stableDiffusionAsset(output);
        expect(asset.linkMode, isA<DynamicLoadingBundled>());
        final file = File.fromUri(asset.file!);
        expect(path.basename(file.path), 'libstable-diffusion.so');
        expect(file.readAsStringSync(), 'fake-sd-linux-x64-vulkan');
      },
    );
  });

  test('Linux bundles the CPU archive when Vulkan is not selected', () async {
    await testCodeBuildHook(
      mainMethod: build_hook.main,
      targetOS: OS.linux,
      targetArchitecture: Architecture.x64,
      userDefines: _userDefines({
        'llamadart_native_runtimes': 'llama_cpp,stable-diffusion',
        'llamadart_native_backends': {
          'platforms': {'linux': 'cpu'},
        },
      }),
      check: (_, output) {
        final assets = output.assets.encodedAssets
            .where((asset) => asset.isCodeAsset)
            .map((asset) => asset.asCodeAsset);
        expect(
          assets.map((asset) => path.basename(asset.file!.toFilePath())),
          isNot(contains('libggml-vulkan.so')),
        );
        expect(
          File.fromUri(_stableDiffusionAsset(output).file!).readAsStringSync(),
          'fake-sd-linux-x64',
        );
      },
    );
  });

  test('stable_diffusion can be bundled without llama.cpp', () async {
    await testCodeBuildHook(
      mainMethod: build_hook.main,
      targetOS: OS.macOS,
      targetArchitecture: Architecture.arm64,
      userDefines: _userDefines({
        'llamadart_native_runtimes': ['stable_diffusion'],
      }),
      check: (_, output) {
        expect(_codeAssetIds(output), {_stableDiffusionAssetId});
        final asset = _stableDiffusionAsset(output);
        expect(asset.linkMode, isA<DynamicLoadingBundled>());
        expect(
          File.fromUri(asset.file!).readAsStringSync(),
          'fake-sd-macos-arm64',
        );
      },
    );
  });

  test(
    'an unpublished target drops a broadly named stable_diffusion',
    () async {
      for (final defines in <Map<String, Object?>>[
        {
          'llamadart_native_runtimes': ['llama_cpp', 'stable_diffusion'],
        },
        {
          'llamadart_native_runtimes': {
            'platforms': {
              'android': ['llama_cpp', 'stable_diffusion'],
            },
          },
        },
      ]) {
        await testCodeBuildHook(
          mainMethod: build_hook.main,
          targetOS: OS.android,
          targetArchitecture: Architecture.x64,
          targetAndroidNdkApi: 30,
          userDefines: _userDefines(defines),
          check: (_, output) {
            final ids = _codeAssetIds(output);
            expect(ids, contains(_primaryAssetId), reason: '$defines');
            expect(ids, isNot(contains(_stableDiffusionAssetId)));
          },
        );
      }

      await testCodeBuildHook(
        mainMethod: build_hook.main,
        targetOS: OS.android,
        targetArchitecture: Architecture.x64,
        targetAndroidNdkApi: 30,
        userDefines: _userDefines({
          'llamadart_native_runtimes': ['stable_diffusion'],
        }),
        check: (_, output) {
          expect(_codeAssetIds(output), isEmpty);
        },
      );
    },
  );

  test('an unpublished target rejects a bundle-scoped request', () async {
    var emitted = false;
    await expectLater(
      testCodeBuildHook(
        mainMethod: build_hook.main,
        targetOS: OS.android,
        targetArchitecture: Architecture.x64,
        targetAndroidNdkApi: 30,
        userDefines: _userDefines({
          'llamadart_native_runtimes': {
            'platforms': {
              'android-x64': ['llama_cpp', 'stable_diffusion'],
            },
          },
        }),
        check: (_, _) => emitted = true,
      ),
      throwsA(
        predicate(
          (error) => error.toString().contains(
            'stable_diffusion runtime is not available for android-x64',
          ),
        ),
      ),
    );
    expect(emitted, isFalse);
  });

  test(
    'Flutter Apple companion builds still bundle stable_diffusion',
    () async {
      final consumer = await Directory.systemTemp.createTemp(
        'llamadart_sd_apple_consumer_',
      );
      addTearDown(() => consumer.delete(recursive: true));
      final pubspec = File(path.join(consumer.path, 'pubspec.yaml'))
        ..writeAsStringSync('''
name: llamadart_sd_apple_consumer
publish_to: none

environment:
  sdk: ^3.10.7

dependencies:
  flutter:
    sdk: flutter
  llamadart: ^0.9.0
  llamadart_litert_lm_flutter: ^0.0.17
''');

      await testCodeBuildHook(
        mainMethod: build_hook.main,
        targetOS: OS.iOS,
        targetArchitecture: Architecture.arm64,
        targetIOSSdk: IOSSdk.iPhoneOS,
        userDefines: PackageUserDefines(
          workspacePubspec: PackageUserDefinesSource(
            defines: {
              'llamadart_native_runtimes': ['llama_cpp', 'stable_diffusion'],
            },
            basePath: pubspec.uri,
          ),
        ),
        check: (_, output) {
          expect(_codeAssetIds(output), {_stableDiffusionAssetId});
          final asset = _stableDiffusionAsset(output);
          expect(asset.linkMode, isA<DynamicLoadingBundled>());
          expect(
            File.fromUri(asset.file!).readAsStringSync(),
            'fake-sd-ios-arm64',
          );
        },
      );
    },
  );
}

PackageUserDefines _userDefines(Map<String, Object?> defines) =>
    PackageUserDefines(
      workspacePubspec: PackageUserDefinesSource(
        defines: defines,
        basePath: Directory.current.uri,
      ),
    );

Set<String> _codeAssetIds(BuildOutput output) => output.assets.encodedAssets
    .where((asset) => asset.isCodeAsset)
    .map((asset) => asset.asCodeAsset.id)
    .toSet();

CodeAsset _stableDiffusionAsset(BuildOutput output) => output
    .assets
    .encodedAssets
    .where((asset) => asset.isCodeAsset)
    .map((asset) => asset.asCodeAsset)
    .singleWhere((asset) => asset.id == _stableDiffusionAssetId);

Directory _backupOf(Directory directory) =>
    Directory('${directory.path}.__sd_hook_test');

Future<void> _moveDirectory(Directory from, Directory to) async {
  if (to.existsSync()) {
    await to.delete(recursive: true);
  }
  if (from.existsSync()) {
    await to.parent.create(recursive: true);
    await from.rename(to.path);
  }
}

Future<void> _writeLibraries(
  Directory directory,
  Map<String, String> contents,
) async {
  if (directory.existsSync()) {
    await directory.delete(recursive: true);
  }
  await directory.create(recursive: true);
  for (final MapEntry(key: name, value: content) in contents.entries) {
    await File(path.join(directory.path, name)).writeAsString(content);
  }
}
