@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import 'package:llamadart/src/hook/native_release_pins.dart';

import '../../../hook/build.dart' as build_hook;

const _stableDiffusionAssetId = 'package:llamadart/stable_diffusion';
const _primaryAssetId = 'package:llamadart/llamadart';
const _liteRtLmAssetIdPrefix = 'package:llamadart/litert_lm_';

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
    'ios-x86_64-sim': const ['libllamadart.dylib'],
    'windows-arm64': const [
      'llamadart-windows-arm64.dll',
      'llama-windows-arm64.dll',
      'ggml-windows-arm64.dll',
      'ggml-base-windows-arm64.dll',
      'ggml-cpu-windows-arm64.dll',
    ],
  };
  final stableDiffusionBundles = {
    for (final spec in stableDiffusionBundleSpecs)
      if (const {
        'linux-x64',
        'linux-x64-vulkan',
        'macos-arm64',
        'ios-arm64',
        'ios-x64-sim',
      }.contains(spec.bundle))
        spec.bundle: spec.requiredLibraries.single,
  };
  final liteRtLmBundles = {
    'linux-x64': Directory(
      '.dart_tool/llamadart/litert_lm/$liteRtLmVersion/linux/x64',
    ),
    'android-x64': Directory(
      '.dart_tool/llamadart/litert_lm/$liteRtLmVersion/android/x64',
    ),
  };
  final backups = [
    for (final bundle in nativeBundles.keys) nativeBundle(bundle),
    for (final bundle in stableDiffusionBundles.keys)
      stableDiffusionBundle(bundle),
    ...liteRtLmBundles.values,
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
    for (final MapEntry(key: bundle, value: directory)
        in liteRtLmBundles.entries) {
      await _writeLibraries(directory, {
        for (final library
            in liteRtLmBundleSpecs
                .singleWhere((spec) => spec.bundle == bundle)
                .requiredLibraries)
          library: 'fake-$library',
      });
    }
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

  test('[all, stable_diffusion] keeps the default runtimes and skips what a '
      'target does not publish', () async {
    const liteRtLmSkipped = 'LiteRT-LM runtime is not available for';
    const stableDiffusionSkipped = 'stable_diffusion runtime is not available';
    for (final (
          :os,
          :architecture,
          :simulator,
          :bundle,
          :liteRtLm,
          :stableDiffusion,
        )
        in const [
          (
            os: OS.linux,
            architecture: Architecture.x64,
            simulator: false,
            bundle: 'linux-x64',
            liteRtLm: true,
            stableDiffusion: true,
          ),
          (
            os: OS.android,
            architecture: Architecture.x64,
            simulator: false,
            bundle: 'android-x64',
            liteRtLm: true,
            stableDiffusion: false,
          ),
          (
            os: OS.iOS,
            architecture: Architecture.x64,
            simulator: true,
            bundle: 'ios-x86_64-sim',
            liteRtLm: false,
            stableDiffusion: true,
          ),
          (
            os: OS.windows,
            architecture: Architecture.arm64,
            simulator: false,
            bundle: 'windows-arm64',
            liteRtLm: false,
            stableDiffusion: false,
          ),
        ]) {
      final log = await _captureHookLog(
        () => testCodeBuildHook(
          mainMethod: build_hook.main,
          targetOS: os,
          targetArchitecture: architecture,
          targetAndroidNdkApi: os == OS.android ? 30 : null,
          targetIOSSdk: simulator ? IOSSdk.iPhoneSimulator : null,
          userDefines: _userDefines({
            'llamadart_native_runtimes': ['all', 'stable_diffusion'],
          }),
          check: (_, output) {
            final ids = _codeAssetIds(output);
            expect(ids, contains(_primaryAssetId), reason: bundle);
            expect(
              ids.any((id) => id.startsWith(_liteRtLmAssetIdPrefix)),
              liteRtLm,
              reason: bundle,
            );
            expect(
              ids.contains(_stableDiffusionAssetId),
              stableDiffusion,
              reason: bundle,
            );
          },
        ),
      );
      final warnings = log.where((line) => line.startsWith('WARNING: '));
      expect(
        warnings.any((line) => line.contains('$liteRtLmSkipped $bundle')),
        !liteRtLm,
        reason: bundle,
      );
      expect(
        warnings.any(
          (line) => line.contains('$stableDiffusionSkipped for $bundle'),
        ),
        !stableDiffusion,
        reason: bundle,
      );
      expect(
        log,
        contains(
          endsWith(
            'Selected native runtimes: ${['llama_cpp', if (liteRtLm) 'litert_lm', if (stableDiffusion) 'stable_diffusion'].join(', ')}.',
          ),
        ),
        reason: bundle,
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

  test('stable_diffusion picks its own build independently of llama.cpp '
      'backends', () async {
    await testCodeBuildHook(
      mainMethod: build_hook.main,
      targetOS: OS.linux,
      targetArchitecture: Architecture.x64,
      userDefines: _userDefines({
        'llamadart_native_runtimes': ['llama_cpp', 'stable_diffusion'],
        'llamadart_stable_diffusion_backends': {
          'platforms': {'linux': 'cpu'},
        },
      }),
      check: (_, output) {
        final assets = output.assets.encodedAssets
            .where((asset) => asset.isCodeAsset)
            .map((asset) => asset.asCodeAsset);
        expect(
          assets.map((asset) => path.basename(asset.file!.toFilePath())),
          contains('libggml-vulkan.so'),
          reason: 'llama.cpp keeps its default Vulkan backend',
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
    'Flutter Apple builds without the stable_diffusion companion bundle it',
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

  test('Flutter iOS hook bundling raises an Xcode warning that App Store '
      'upload needs the companion', () async {
    final defines = await _flutterAppleApp(
      companions: const [],
      defines: {
        'llamadart_native_runtimes': ['stable_diffusion'],
      },
    );
    final warnings = await _captureStderr(
      () => testCodeBuildHook(
        mainMethod: build_hook.main,
        targetOS: OS.iOS,
        targetArchitecture: Architecture.arm64,
        targetIOSSdk: IOSSdk.iPhoneOS,
        userDefines: defines,
        check: (_, output) {
          expect(
            _stableDiffusionAsset(output).linkMode,
            isA<DynamicLoadingBundled>(),
          );
        },
      ),
    );
    expect(
      warnings,
      contains(
        allOf(
          startsWith('warning: '),
          contains('MinimumOSVersion 13.0'),
          contains(_stableDiffusionCompanionName),
        ),
      ),
    );
  });

  test(
    'the stable_diffusion companion selects and links it in process',
    () async {
      final defines = await _flutterAppleApp(
        companions: const [_stableDiffusionCompanionName],
      );
      final warnings = await _captureStderr(
        () => testCodeBuildHook(
          mainMethod: build_hook.main,
          targetOS: OS.macOS,
          targetArchitecture: Architecture.arm64,
          userDefines: defines,
          check: (input, output) {
            expect(_codeAssetIds(output), {
              _primaryAssetId,
              _stableDiffusionAssetId,
            });
            final asset = _stableDiffusionAsset(output);
            expect(asset.linkMode, isA<LookupInProcess>());
            expect(asset.file, isNull);
            // llama.cpp has no companion here, so it stays on the hook.
            final llama = output.assets.encodedAssets
                .map((asset) => asset.asCodeAsset)
                .singleWhere((asset) => asset.id == _primaryAssetId);
            expect(llama.linkMode, isA<DynamicLoadingBundled>());
            expect(
              output.dependencies.any(
                (uri) => uri.path.endsWith('Package.swift'),
              ),
              isTrue,
            );
          },
        ),
      );
      expect(warnings, isEmpty);
    },
  );

  test(
    'both companions link llama.cpp and stable_diffusion in process',
    () async {
      final defines = await _flutterAppleApp(
        companions: const [
          _llamaCppCompanionName,
          _stableDiffusionCompanionName,
        ],
        defines: {
          'llamadart_native_runtimes': ['llama_cpp'],
        },
      );
      await testCodeBuildHook(
        mainMethod: build_hook.main,
        targetOS: OS.iOS,
        targetArchitecture: Architecture.x64,
        targetIOSSdk: IOSSdk.iPhoneSimulator,
        userDefines: defines,
        check: (input, output) {
          final assets = output.assets.encodedAssets
              .map((asset) => asset.asCodeAsset)
              .toList();
          expect(assets.map((asset) => asset.id).toSet(), {
            _primaryAssetId,
            _stableDiffusionAssetId,
          });
          expect(
            assets.every((asset) => asset.linkMode is LookupInProcess),
            isTrue,
          );
          expect(
            Directory(
              path.join(input.outputDirectory.toFilePath(), 'llamadart_bin'),
            ).existsSync(),
            isFalse,
          );
        },
      );
    },
  );

  for (final scenario in [
    'old-pin',
    'local-artifacts',
    'hardcoded-url',
    'missing-resolution',
  ]) {
    test(
      'the stable_diffusion companion rejects $scenario before lookup',
      () async {
        final defines = await _flutterAppleApp(
          companions: const [_stableDiffusionCompanionName],
          localArtifacts: scenario == 'local-artifacts',
          resolve: scenario != 'missing-resolution',
          editManifest: (manifest) => switch (scenario) {
            'old-pin' => manifest.replaceFirst(
              'let stableDiffusionTag = "$stableDiffusionReleaseTag"',
              'let stableDiffusionTag = "v0.1.1"',
            ),
            'hardcoded-url' => manifest.replaceFirst(
              r'url: "https://github.com/\(repository)/releases/download/\(tag)/\(artifactName)"',
              'url: "https://example.com/stable_diffusion.zip"',
            ),
            _ => manifest,
          },
        );
        var emitted = false;
        await expectLater(
          testCodeBuildHook(
            mainMethod: build_hook.main,
            targetOS: OS.iOS,
            targetArchitecture: Architecture.arm64,
            targetIOSSdk: IOSSdk.iPhoneOS,
            userDefines: defines,
            check: (_, _) => emitted = true,
          ),
          throwsA(
            predicate(
              (error) => error.toString().contains(
                'Incompatible Apple stable_diffusion companion',
              ),
            ),
          ),
        );
        expect(emitted, isFalse);
      },
    );
  }
}

const _llamaCppCompanionName = 'llamadart_llama_cpp_flutter';
const _stableDiffusionCompanionName = 'llamadart_stable_diffusion_flutter';

/// A Flutter app depending on [companions], each resolved in its
/// `package_config.json` to a copy of the maintained package.
Future<PackageUserDefines> _flutterAppleApp({
  required List<String> companions,
  Map<String, Object?> defines = const {},
  String Function(String manifest)? editManifest,
  bool localArtifacts = false,
  bool resolve = true,
}) async {
  final app = await Directory.systemTemp.createTemp(
    'llamadart_sd_flutter_app_',
  );
  addTearDown(() => app.delete(recursive: true));
  final pubspec = File(path.join(app.path, 'pubspec.yaml'))
    ..writeAsStringSync('''
name: llamadart_sd_flutter_app
publish_to: none

environment:
  sdk: ^3.10.7

dependencies:
  flutter:
    sdk: flutter
  llamadart: ^0.9.0
${companions.map((name) => '  $name: any').join('\n')}
''');
  final entries = <Map<String, String>>[];
  for (final name in companions) {
    final root = Directory(path.join(app.path, 'resolved', name));
    final manifest = File(
      path.join(root.path, 'darwin', name, 'Package.swift'),
    );
    await manifest.parent.create(recursive: true);
    File(
      path.join(root.path, 'pubspec.yaml'),
    ).writeAsStringSync('name: $name\nversion: 0.0.1\n');
    final source = File(
      'packages/$name/darwin/$name/Package.swift',
    ).readAsStringSync();
    manifest.writeAsStringSync(
      name == _stableDiffusionCompanionName && editManifest != null
          ? editManifest(source)
          : source,
    );
    if (localArtifacts) {
      await Directory(path.join(manifest.parent.path, 'Artifacts')).create();
    }
    entries.add({'name': name, 'rootUri': '../resolved/$name'});
  }
  if (resolve) {
    final config = File(
      path.join(app.path, '.dart_tool', 'package_config.json'),
    );
    await config.parent.create();
    config.writeAsStringSync(
      jsonEncode({'configVersion': 2, 'packages': entries}),
    );
  }
  return PackageUserDefines(
    workspacePubspec: PackageUserDefinesSource(
      defines: defines,
      basePath: pubspec.uri,
    ),
  );
}

/// The records the hook logs while [body] runs, as `LEVEL: time: message`.
Future<List<String>> _captureHookLog(Future<void> Function() body) async {
  final lines = <String>{};
  await runZoned(
    body,
    zoneSpecification: ZoneSpecification(
      print: (_, _, _, line) => lines.add(line),
    ),
  );
  return lines.toList();
}

/// Lines the hook writes to stderr while [body] runs; Flutter relays them
/// into the Xcode build, where `warning:` lines become build warnings.
Future<List<String>> _captureStderr(Future<void> Function() body) async {
  final sink = _LineSink();
  await IOOverrides.runZoned(body, stderr: () => sink);
  return sink.lines;
}

final class _LineSink implements Stdout {
  final List<String> lines = [];

  @override
  void writeln([Object? object = '']) => lines.add('$object');

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName}');
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
