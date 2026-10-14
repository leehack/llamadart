@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:llamadart/src/hook/native_release_pins.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import '../../../hook/build.dart' as build_hook;

void main() {
  final nativeTag = _readPinnedConst('llamaCppTag');
  final litertVersion = _readPinnedConst('liteRtLmVersion');
  final nativeBundleDir = Directory(
    '.dart_tool/llamadart/native_bundles/$nativeTag/linux-arm64/extracted',
  );
  final litertBundleDir = Directory(
    '.dart_tool/llamadart/litert_lm/$litertVersion/linux/arm64',
  );
  final macosArm64NativeBundleDir = Directory(
    '.dart_tool/llamadart/native_bundles/$nativeTag/macos-arm64/extracted',
  );
  final macosArm64LitertBundleDir = Directory(
    '.dart_tool/llamadart/litert_lm/$litertVersion/macos/arm64',
  );
  final macosX64NativeBundleDir = Directory(
    '.dart_tool/llamadart/native_bundles/$nativeTag/macos-x86_64/extracted',
  );
  final iosDeviceNativeBundleDir = Directory(
    '.dart_tool/llamadart/native_bundles/$nativeTag/ios-arm64/extracted',
  );
  final iosArm64SimNativeBundleDir = Directory(
    '.dart_tool/llamadart/native_bundles/$nativeTag/ios-arm64-sim/extracted',
  );
  final iosX64SimNativeBundleDir = Directory(
    '.dart_tool/llamadart/native_bundles/$nativeTag/ios-x86_64-sim/extracted',
  );
  final iosDeviceLitertBundleDir = Directory(
    '.dart_tool/llamadart/litert_lm/$litertVersion/ios/arm64',
  );
  final iosArm64SimLitertBundleDir = Directory(
    '.dart_tool/llamadart/litert_lm/$litertVersion/ios/arm64-sim',
  );
  final backupPairs = [
    (nativeBundleDir, Directory('${nativeBundleDir.path}.__litert_test')),
    (litertBundleDir, Directory('${litertBundleDir.path}.__litert_test')),
    (
      macosArm64NativeBundleDir,
      Directory('${macosArm64NativeBundleDir.path}.__litert_test'),
    ),
    (
      macosArm64LitertBundleDir,
      Directory('${macosArm64LitertBundleDir.path}.__litert_test'),
    ),
    (
      macosX64NativeBundleDir,
      Directory('${macosX64NativeBundleDir.path}.__litert_test'),
    ),
    (
      iosDeviceNativeBundleDir,
      Directory('${iosDeviceNativeBundleDir.path}.__litert_test'),
    ),
    (
      iosArm64SimNativeBundleDir,
      Directory('${iosArm64SimNativeBundleDir.path}.__litert_test'),
    ),
    (
      iosX64SimNativeBundleDir,
      Directory('${iosX64SimNativeBundleDir.path}.__litert_test'),
    ),
    (
      iosDeviceLitertBundleDir,
      Directory('${iosDeviceLitertBundleDir.path}.__litert_test'),
    ),
    (
      iosArm64SimLitertBundleDir,
      Directory('${iosArm64SimLitertBundleDir.path}.__litert_test'),
    ),
  ];

  setUpAll(() async {
    for (final (directory, backup) in backupPairs) {
      await _backupDirectory(directory, backup);
    }
  });

  setUp(() async {
    await _writeBundleLibraries(nativeBundleDir, const [
      'libllamadart.so',
      'libllama.so',
      'libggml.so',
      'libggml-base.so',
      'libggml-cpu.so',
    ]);
    await _writeBundleLibraries(litertBundleDir, _linuxLiteRtLibraries);
    await _writeBundleLibraries(macosArm64NativeBundleDir, const [
      'libllamadart.dylib',
    ]);
    await _writeBundleLibraries(
      macosArm64LitertBundleDir,
      _macosArm64LiteRtLibraries,
    );
    await _writeBundleLibraries(macosX64NativeBundleDir, const [
      'libllamadart.dylib',
    ]);
    for (final directory in [
      iosDeviceNativeBundleDir,
      iosArm64SimNativeBundleDir,
      iosX64SimNativeBundleDir,
    ]) {
      await _writeBundleLibraries(directory, const ['libllamadart.dylib']);
    }
    for (final directory in [
      iosDeviceLitertBundleDir,
      iosArm64SimLitertBundleDir,
    ]) {
      await _writeBundleLibraries(directory, [
        ..._iosLiteRtLibraries,
        'libLegacySplitRuntime.dylib',
        'GemmaModelConstraintProvider',
      ]);
    }
  });

  tearDownAll(() async {
    for (final (directory, backup) in backupPairs.reversed) {
      await _restoreDirectory(directory, backup);
    }
  });

  test('LiteRT-LM bundle specs require platform runtime companions', () {
    final source = File(
      'lib/src/hook/native_release_pins.dart',
    ).readAsStringSync();

    _expectSpecLibraries(source, 'android-arm64', _androidLiteRtLibraries);
    _expectSpecLibraries(source, 'android-x64', _androidLiteRtLibraries);
    _expectSpecLibraries(source, 'ios-arm64', _iosLiteRtLibraries);
    _expectSpecLibraries(source, 'ios-arm64-sim', _iosLiteRtLibraries);
    _expectSpecLibraries(source, 'macos-arm64', _macosArm64LiteRtLibraries);
    final liteRtLmSpecs = source.substring(
      source.indexOf('const liteRtLmBundleSpecs'),
      source.indexOf('];', source.indexOf('const liteRtLmBundleSpecs')),
    );
    expect(liteRtLmSpecs, contains("'macos-arm64'"));
    expect(liteRtLmSpecs, isNot(contains("'macos-x64'")));
    _expectSpecLibraries(source, 'linux-arm64', _linuxLiteRtLibraries);
    _expectSpecLibraries(source, 'linux-x64', _linuxLiteRtLibraries);
    _expectSpecLibraries(source, 'windows-x64', _windowsLiteRtLibraries);
  });

  test('LiteRT-LM bundle specs pin archive checksums', () {
    final source = File(
      'lib/src/hook/native_release_pins.dart',
    ).readAsStringSync();

    for (final bundleKey in const [
      'android-arm64',
      'android-x64',
      'ios-arm64',
      'ios-arm64-sim',
      'macos-arm64',
      'linux-arm64',
      'linux-x64',
      'windows-x64',
    ]) {
      _expectSpecChecksum(source, bundleKey);
    }
  });

  test(
    'build hook emits Linux arm64 LiteRT-LM runtime companions when requested',
    () async {
      await testCodeBuildHook(
        mainMethod: build_hook.main,
        targetOS: OS.linux,
        targetArchitecture: Architecture.arm64,
        userDefines: _bothRuntimeUserDefines(),
        check: (input, output) {
          final codeAssets = output.assets.encodedAssets
              .where((asset) => asset.isCodeAsset)
              .map((asset) => asset.asCodeAsset)
              .toList(growable: false);

          final codeAssetIds = codeAssets.map((asset) => asset.id).toSet();
          final emittedNames = codeAssets
              .map((asset) => path.basename(asset.file!.toFilePath()))
              .toSet();

          expect(codeAssetIds, contains('package:llamadart/llamadart'));
          for (final library in _linuxLiteRtLibraries) {
            expect(emittedNames, contains(library));
          }
          for (final assetName in _linuxLiteRtAssetNames) {
            expect(codeAssetIds, contains('package:llamadart/$assetName'));
          }
        },
      );
    },
  );

  test(
    'build hook keeps macOS LiteRT-LM libraries in the cache when requested',
    () async {
      await testCodeBuildHook(
        mainMethod: build_hook.main,
        targetOS: OS.macOS,
        targetArchitecture: Architecture.arm64,
        userDefines: _bothRuntimeUserDefines(),
        check: (input, output) {
          final codeAssets = output.assets.encodedAssets
              .where((asset) => asset.isCodeAsset)
              .map((asset) => asset.asCodeAsset)
              .toList(growable: false);

          final codeAssetIds = codeAssets.map((asset) => asset.id).toSet();
          final emittedNames = codeAssets
              .map((asset) => path.basename(asset.file!.toFilePath()))
              .toSet();

          expect(codeAssetIds, contains('package:llamadart/llamadart'));
          expect(codeAssetIds.where((id) => id.contains('litert_lm')), isEmpty);
          for (final library in _macosArm64LiteRtLibraries) {
            expect(emittedNames, isNot(contains(library)));
          }
        },
      );
    },
  );

  for (final (selection, userDefines) in [
    ('both', _bothRuntimeUserDefines),
    ('litert_lm only', _liteRtLmOnlyUserDefines),
  ]) {
    test('build hook skips LiteRT-LM on macOS x64 with a warning when '
        '$selection is selected', () async {
      final records = <String>[];
      final subscription = Logger.root.onRecord.listen(
        (record) => records.add(record.message),
      );
      addTearDown(subscription.cancel);
      final stderrLines = await _capturingStderr(
        () async => testCodeBuildHook(
          mainMethod: build_hook.main,
          targetOS: OS.macOS,
          targetArchitecture: Architecture.x64,
          userDefines: userDefines(),
          check: (input, output) {
            final codeAssetIds = output.assets.encodedAssets
                .where((asset) => asset.isCodeAsset)
                .map((asset) => asset.asCodeAsset.id)
                .toList(growable: false);
            expect(
              codeAssetIds,
              selection == 'both' ? ['package:llamadart/llamadart'] : isEmpty,
            );
          },
        ),
      );
      expect(stderrLines, contains(_macOsX64LiteRtLmSkippedWarning));
      _expectNoLiteRtLmBundleRequest(records);
    });
  }

  test('build hook can emit LiteRT-LM runtime without llama.cpp', () async {
    await testCodeBuildHook(
      mainMethod: build_hook.main,
      targetOS: OS.linux,
      targetArchitecture: Architecture.arm64,
      userDefines: _liteRtLmOnlyUserDefines(),
      check: (input, output) {
        final codeAssets = output.assets.encodedAssets
            .where((asset) => asset.isCodeAsset)
            .map((asset) => asset.asCodeAsset)
            .toList(growable: false);

        final codeAssetIds = codeAssets.map((asset) => asset.id).toSet();
        final emittedNames = codeAssets
            .map((asset) => path.basename(asset.file!.toFilePath()))
            .toSet();

        expect(codeAssetIds, isNot(contains('package:llamadart/llamadart')));
        expect(emittedNames, isNot(contains('libllamadart.so')));
        for (final library in _linuxLiteRtLibraries) {
          expect(emittedNames, contains(library));
        }
        for (final assetName in _linuxLiteRtAssetNames) {
          expect(codeAssetIds, contains('package:llamadart/$assetName'));
        }
      },
    );
  });

  test(
    'build hook bundles Apple native assets without companion packages',
    () async {
      final liteRtLmBinary = File(
        path.join(iosDeviceLitertBundleDir.path, 'LiteRtLm'),
      );
      if (!Platform.isWindows) {
        final result = await Process.run('chmod', ['a-w', liteRtLmBinary.path]);
        expect(result.exitCode, 0, reason: '${result.stderr}');
      }
      await testCodeBuildHook(
        mainMethod: build_hook.main,
        targetOS: OS.iOS,
        targetArchitecture: Architecture.arm64,
        targetIOSSdk: IOSSdk.iPhoneOS,
        userDefines: _bothRuntimeUserDefines(),
        check: (input, output) {
          final codeAssets = output.assets.encodedAssets
              .where((asset) => asset.isCodeAsset)
              .map((asset) => asset.asCodeAsset)
              .toList(growable: false);

          final codeAssetIds = codeAssets.map((asset) => asset.id).toSet();
          expect(codeAssetIds, contains('package:llamadart/llamadart'));
          for (final assetName in _iosLiteRtAssetNames) {
            expect(codeAssetIds, contains('package:llamadart/$assetName'));
          }
          expect(
            codeAssetIds.where((id) => id.contains('/litert_lm_')).toSet(),
            {
              for (final assetName in _iosLiteRtAssetNames)
                'package:llamadart/$assetName',
            },
          );
          expect(
            codeAssets.every(
              (asset) => asset.linkMode is DynamicLoadingBundled,
            ),
            isTrue,
          );

          final outputDir = input.outputDirectory.toFilePath();
          if (!Platform.isWindows) {
            final emittedLiteRtLm = codeAssets.singleWhere(
              (asset) => path.basename(asset.file!.toFilePath()) == 'LiteRtLm',
            );
            final mode = FileStat.statSync(
              emittedLiteRtLm.file!.toFilePath(),
            ).mode;
            expect(mode & 0x80, isNonZero);
          }
          expect(
            Directory(path.join(outputDir, 'llamadart_bin')).existsSync(),
            isTrue,
          );
        },
      );
    },
  );

  for (final target in [OS.iOS, OS.macOS]) {
    test(
      'Apple $target rejects resolved old ABI despite native overrides',
      () async {
        final defines = await _flutterAppleUserDefines(
          dependencies: const ['llamadart_llama_cpp_flutter'],
          companionTag: 'v0.3.0',
          companionVersion: '0.0.17',
          defines: {
            'llamadart_native_tag': 'v0.4.0',
            'llamadart_native_path': './new-runtime',
            'llamadart_native_runtimes': ['litert_lm'],
          },
        );
        var emitted = false;
        await expectLater(
          testCodeBuildHook(
            mainMethod: build_hook.main,
            targetOS: target,
            targetArchitecture: Architecture.arm64,
            targetIOSSdk: target == OS.iOS ? IOSSdk.iPhoneOS : null,
            userDefines: defines,
            check: (_, _) => emitted = true,
          ),
          throwsA(
            predicate(
              (error) => error.toString().contains(
                'Incompatible Apple llama.cpp companion',
              ),
            ),
          ),
        );
        expect(emitted, isFalse);
      },
    );
  }

  for (final target in [OS.iOS, OS.macOS]) {
    for (final MapEntry(key: tag, value: missing)
        in llamaCppCompatibleAppleCompanionTags.entries) {
      test('Apple $target links a companion pinning compatible $tag with an '
          'upgrade warning', () async {
        final records = <String>[];
        final subscription = Logger.root.onRecord.listen(
          (record) => records.add(record.message),
        );
        addTearDown(subscription.cancel);
        final defines = await _flutterAppleUserDefines(
          dependencies: const ['llamadart_llama_cpp_flutter'],
          companionTag: tag,
          companionVersion: '0.0.22',
        );
        final stderrLines = await _capturingStderr(
          () => testCodeBuildHook(
            mainMethod: build_hook.main,
            targetOS: target,
            targetArchitecture: Architecture.arm64,
            targetIOSSdk: target == OS.iOS ? IOSSdk.iPhoneOS : null,
            userDefines: defines,
            check: (_, output) {
              final asset = output.assets.encodedAssets.single.asCodeAsset;
              expect(asset.id, 'package:llamadart/llamadart');
              expect(asset.linkMode, isA<LookupInProcess>());
            },
          ),
        );
        final warning =
            'Resolved llamadart_llama_cpp_flutter 0.0.22 pins '
            'leehack/llamadart-native@$tag, an earlier build of the same '
            'llama.cpp runtime as $llamaCppTag, so this build links it. '
            'Its frameworks lack $missing. Depend on '
            '`llamadart_llama_cpp_flutter: ^$llamaCppAppleCompanionVersion` '
            'to link $llamaCppTag.';
        expect(stderrLines, contains('warning: llamadart: $warning'));
        expect(records, contains(warning));
      });

      test('Apple $target still rejects local Artifacts beside compatible '
          '$tag', () async {
        final defines = await _flutterAppleUserDefines(
          dependencies: const ['llamadart_llama_cpp_flutter'],
          companionTag: tag,
          companionVersion: '0.0.22',
          localArtifacts: true,
        );
        final captured = _CapturedStderr();
        await expectLater(
          IOOverrides.runZoned(
            () => testCodeBuildHook(
              mainMethod: build_hook.main,
              targetOS: target,
              targetArchitecture: Architecture.arm64,
              targetIOSSdk: target == OS.iOS ? IOSSdk.iPhoneOS : null,
              userDefines: defines,
              check: (_, _) => fail('Must not emit in-process assets'),
            ),
            stderr: () => captured,
          ),
          throwsA(
            predicate(
              (error) => error.toString().contains(
                'Incompatible Apple llama.cpp companion: Local Artifacts',
              ),
            ),
          ),
        );
        expect(captured.lines, isNot(contains(contains('earlier build'))));
      });
    }

    test('Apple $target links the exact companion pin without a compatibility '
        'warning', () async {
      final records = <String>[];
      final subscription = Logger.root.onRecord.listen(
        (record) => records.add(record.message),
      );
      addTearDown(subscription.cancel);
      final defines = await _flutterAppleUserDefines(
        dependencies: const ['llamadart_llama_cpp_flutter'],
        companionVersion: llamaCppAppleCompanionVersion,
      );
      final stderrLines = await _capturingStderr(
        () => testCodeBuildHook(
          mainMethod: build_hook.main,
          targetOS: target,
          targetArchitecture: Architecture.arm64,
          targetIOSSdk: target == OS.iOS ? IOSSdk.iPhoneOS : null,
          userDefines: defines,
          check: (_, output) => expect(
            output.assets.encodedAssets.single.asCodeAsset.linkMode,
            isA<LookupInProcess>(),
          ),
        ),
      );
      expect(stderrLines, isNot(contains(contains('earlier build'))));
      expect(records, isNot(contains(contains('earlier build'))));
    });

    for (final tag in ['v0.6.0-1', 'v0.6.0-4', 'v0.5.0-2']) {
      test('Apple $target rejects unlisted companion pin $tag and names the '
          'companion release to depend on', () async {
        final defines = await _flutterAppleUserDefines(
          dependencies: const ['llamadart_llama_cpp_flutter'],
          companionTag: tag,
          companionVersion: '0.0.22',
        );
        var emitted = false;
        await expectLater(
          testCodeBuildHook(
            mainMethod: build_hook.main,
            targetOS: target,
            targetArchitecture: Architecture.arm64,
            targetIOSSdk: target == OS.iOS ? IOSSdk.iPhoneOS : null,
            userDefines: defines,
            check: (_, _) => emitted = true,
          ),
          throwsA(
            predicate(
              (error) => error.toString().contains(
                'Incompatible Apple llama.cpp companion: Resolved companion '
                '0.0.22 does not uniquely pin the required native runtime '
                '$llamaCppTag. Depend on `llamadart_llama_cpp_flutter: '
                '^$llamaCppAppleCompanionVersion`, the first release '
                'pinning leehack/llamadart-native@$llamaCppTag, in '
                'pubspec.yaml and rerun flutter pub get; a caret '
                'constraint on an earlier 0.0.x release never resolves it.',
              ),
            ),
          ),
        );
        expect(emitted, isFalse);
      });
    }
  }

  for (final (scenario, compatibleTag) in [
    for (final tag in [null, ...llamaCppCompatibleAppleCompanionTags.keys])
      for (final scenario in [
        'missing',
        'duplicate',
        'local',
        'false-version',
        'malformed-config',
        'malformed-pubspec',
        'wrong-name',
        'missing-pin',
        'duplicate-pin',
        'wrong-target',
        'hardcoded-url',
        'comment-decoy',
        'missing-manifest',
      ])
        (scenario, tag),
  ]) {
    test(
      'Apple companion rejects $scenario metadata before lookup'
      '${compatibleTag == null ? '' : ' with compatible pin $compatibleTag'}',
      () async {
        final defines = await _flutterAppleUserDefines(
          dependencies: const ['llamadart_llama_cpp_flutter'],
          missingConfiguration: scenario == 'missing',
          duplicateCompanion: scenario == 'duplicate',
          localArtifacts: scenario == 'local',
          companionTag: scenario == 'false-version' ? 'v0.3.0' : compatibleTag,
          mutate: (root) {
            final config = File(
              path.join(root.path, '.dart_tool', 'package_config.json'),
            );
            final metadata = File(
              path.join(root.path, 'resolved companion', 'pubspec.yaml'),
            );
            final manifest = File(
              path.join(
                root.path,
                'resolved companion',
                'darwin',
                'llamadart_llama_cpp_flutter',
                'Package.swift',
              ),
            );
            switch (scenario) {
              case 'malformed-config':
                config.writeAsStringSync('{');
              case 'malformed-pubspec':
                metadata.writeAsStringSync('name: [');
              case 'wrong-name':
                metadata.writeAsStringSync('name: other\nversion: 0.0.18');
              case 'missing-pin':
                manifest.writeAsStringSync('// no pin');
              case 'duplicate-pin':
                manifest.writeAsStringSync(
                  '${manifest.readAsStringSync()}\nlet llamaCppTag = "v0.4.0"\n',
                );
              case 'wrong-target':
                manifest.writeAsStringSync(
                  manifest.readAsStringSync().replaceFirst(
                    'tag: llamaCppTag,',
                    'tag: "v0.3.0",',
                  ),
                );
              case 'missing-manifest':
                manifest.deleteSync();
              case 'hardcoded-url':
                manifest.writeAsStringSync(
                  manifest.readAsStringSync().replaceFirst(
                    r'url: "https://github.com/\(repository)/releases/download/\(tag)/\(artifactName)"',
                    'url: "https://github.com/leehack/llamadart-native/releases/download/v0.3.0/llamadart-native-apple-xcframework-v0.3.0.zip"',
                  ),
                );
              case 'comment-decoy':
                manifest.writeAsStringSync(
                  manifest.readAsStringSync().replaceFirst(
                    'tag: llamaCppTag,',
                    '// tag: llamaCppTag,\n            tag: "v0.3.0",',
                  ),
                );
            }
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
                'Incompatible Apple llama.cpp companion',
              ),
            ),
          ),
        );
        expect(emitted, isFalse);
      },
    );
  }

  test(
    'workspace-resolved matching companion tracks all metadata for caching',
    () async {
      final defines = await _flutterAppleUserDefines(
        dependencies: const ['llamadart_llama_cpp_flutter'],
        workspaceMember: true,
      );
      await testCodeBuildHook(
        mainMethod: build_hook.main,
        targetOS: OS.macOS,
        targetArchitecture: Architecture.arm64,
        userDefines: defines,
        check: (_, output) {
          expect(
            output.assets.encodedAssets.single.asCodeAsset.linkMode,
            isA<LookupInProcess>(),
          );
          final dependencies = output.dependencies
              .map((uri) => uri.toFilePath())
              .toList();
          expect(
            dependencies.where((entry) => entry.endsWith('pubspec.yaml')),
            hasLength(2),
          );
          expect(
            dependencies.any((entry) => entry.endsWith('package_config.json')),
            isTrue,
          );
          expect(
            dependencies.any((entry) => entry.endsWith('Package.swift')),
            isTrue,
          );
          expect(
            output.dependencies.any(
              (uri) =>
                  uri.path.endsWith('/darwin/llamadart_llama_cpp_flutter/'),
            ),
            isTrue,
          );
          expect(
            output.dependencies.any((uri) => uri.path.endsWith('/Artifacts/')),
            isFalse,
          );
          for (final uri in output.dependencies.where(
            (uri) => uri.path.endsWith('/'),
          )) {
            expect(Directory.fromUri(uri).existsSync(), isTrue);
          }
        },
      );
    },
  );

  test(
    'flow YAML and dependency overrides cannot hide old resolved ABI',
    () async {
      final defines = await _flutterAppleUserDefines(
        dependencies: const ['llamadart_llama_cpp_flutter'],
        companionTag: 'v0.3.0',
        mutate: (root) =>
            File(path.join(root.path, 'pubspec.yaml')).writeAsStringSync('''
name: consumer
dependencies: {flutter: {sdk: flutter}, llamadart: ^0.8.22, llamadart_llama_cpp_flutter: ^0.0.18}
dependency_overrides: {llamadart_llama_cpp_flutter: {path: resolved companion}}
'''),
      );
      await expectLater(
        testCodeBuildHook(
          mainMethod: build_hook.main,
          targetOS: OS.iOS,
          targetArchitecture: Architecture.arm64,
          targetIOSSdk: IOSSdk.iPhoneOS,
          userDefines: defines,
          check: (_, _) => fail('Must not emit in-process assets'),
        ),
        throwsA(
          predicate(
            (error) => error.toString().contains(
              'Incompatible Apple llama.cpp companion',
            ),
          ),
        ),
      );
    },
  );

  test('build hook ignores native source overrides for Apple SPM', () async {
    final userDefines = await _flutterAppleUserDefines(
      dependencies: const ['llamadart_llama_cpp_flutter'],
      defines: {
        'llamadart_native_runtimes': ['litert_lm'],
        'llamadart_native_tag': '../ignored-by-spm',
        'llamadart_native_repository': '../ignored-by-spm',
        'llamadart_native_path': './missing-native-bundles',
        'llamadart_native_backends': {
          'platforms': {
            'ios-arm64': ['cuda'],
          },
        },
      },
    );

    await testCodeBuildHook(
      mainMethod: build_hook.main,
      targetOS: OS.iOS,
      targetArchitecture: Architecture.arm64,
      targetIOSSdk: IOSSdk.iPhoneOS,
      userDefines: userDefines,
      check: (input, output) {
        final codeAssets = output.assets.encodedAssets
            .where((asset) => asset.isCodeAsset)
            .map((asset) => asset.asCodeAsset)
            .toList(growable: false);

        expect(codeAssets, hasLength(1));
        final codeAsset = codeAssets.single;
        expect(codeAsset.id, 'package:llamadart/llamadart');
        expect(codeAsset.file, isNull);
        expect(codeAsset.linkMode, isA<LookupInProcess>());

        final outputDir = input.outputDirectory.toFilePath();
        expect(
          Directory(path.join(outputDir, 'llamadart_bin')).existsSync(),
          isFalse,
        );
      },
    );
  });

  test(
    'build hook emits no bundled Apple assets for Flutter iOS LiteRT-LM SPM mode',
    () async {
      await testCodeBuildHook(
        mainMethod: build_hook.main,
        targetOS: OS.iOS,
        targetArchitecture: Architecture.arm64,
        targetIOSSdk: IOSSdk.iPhoneOS,
        userDefines: await _flutterLiteRtLmOnlyUserDefines(),
        check: (input, output) {
          final codeAssets = output.assets.encodedAssets
              .where((asset) => asset.isCodeAsset)
              .map((asset) => asset.asCodeAsset)
              .toList(growable: false);

          expect(codeAssets, isEmpty);
          final outputDir = input.outputDirectory.toFilePath();
          expect(
            Directory(path.join(outputDir, 'llamadart_bin')).existsSync(),
            isFalse,
          );
        },
      );
    },
  );

  for (final architecture in [Architecture.arm64]) {
    test(
      'build hook hands Flutter macOS $architecture LiteRT-LM to the SwiftPM '
      'companion and keeps its cache for flutter_tester',
      () async {
        final records = <String>[];
        final subscription = Logger.root.onRecord.listen(
          (record) => records.add(record.message),
        );
        addTearDown(subscription.cancel);
        final stderrLines = await _capturingStderr(
          () async => testCodeBuildHook(
            mainMethod: build_hook.main,
            targetOS: OS.macOS,
            targetArchitecture: architecture,
            userDefines: await _flutterLiteRtLmOnlyUserDefines(),
            check: (input, output) {
              expect(output.assets.encodedAssets, isEmpty);
              final outputDir = input.outputDirectory.toFilePath();
              expect(
                Directory(path.join(outputDir, 'llamadart_bin')).existsSync(),
                isFalse,
              );
              expect(
                output.dependencies.map((uri) => uri.toFilePath()),
                contains(
                  endsWith(
                    path.join(
                      'resolved litert companion',
                      'darwin',
                      'llamadart_litert_lm_flutter',
                      'Package.swift',
                    ),
                  ),
                ),
              );
            },
          ),
        );
        final arch = architecture == Architecture.arm64 ? 'arm64' : 'x64';
        // The hook joins the platform and arch with '/', so normalise Windows
        // separators before matching the cache directory.
        expect(
          records.map((record) => record.replaceAll(r'\\', '/')),
          contains(
            allOf(
              startsWith('Using cached LiteRT-LM bundle: '),
              endsWith('macos/$arch'),
            ),
          ),
        );
        expect(stderrLines, isNot(contains(contains('warning: llamadart:'))));
      },
    );
  }

  for (final (scenario, defines) in [
    (
      'the published 0.0.14 manifest',
      () => _flutterLiteRtLmOnlyUserDefines(
        liteRtLmManifest: _publishedLiteRtLmCompanion0014Manifest(),
      ),
    ),
    (
      'a manifest pinning another LiteRT-LM tag',
      () => _flutterLiteRtLmOnlyUserDefines(
        liteRtLmManifest: _liteRtLmCompanionManifest().replaceFirst(
          'let liteRtLmTag = "${_readPinnedConst('liteRtLmReleaseTag')}"',
          'let liteRtLmTag = "v0.17.0-8"',
        ),
      ),
    ),
    (
      'an edited manifest',
      () => _flutterLiteRtLmOnlyUserDefines(
        liteRtLmManifest: _liteRtLmCompanionManifest().replaceFirst(
          '.target(name: "WebgpuDawn", condition: .when(platforms: [.macOS]))',
          '.target(name: "WebgpuDawn", condition: .when(platforms: [.iOS]))',
        ),
      ),
    ),
    (
      'an unresolved companion',
      () => _flutterLiteRtLmOnlyUserDefines(resolveLiteRtLmCompanion: false),
    ),
  ]) {
    for (final architecture in [Architecture.arm64]) {
      test('build hook keeps Flutter macOS $architecture LiteRT-LM on the '
          'hook cache with a build warning for $scenario', () async {
        final stderrLines = await _capturingStderr(
          () async => testCodeBuildHook(
            mainMethod: build_hook.main,
            targetOS: OS.macOS,
            targetArchitecture: architecture,
            userDefines: await defines(),
            check: (input, output) {
              expect(output.assets.encodedAssets, isEmpty);
              final outputDir = input.outputDirectory.toFilePath();
              expect(
                Directory(path.join(outputDir, 'llamadart_bin')).existsSync(),
                isTrue,
              );
            },
          ),
        );
        expect(
          stderrLines,
          contains(
            startsWith(
              'warning: llamadart: The resolved llamadart_litert_lm_flutter '
              'does not link the complete macOS LiteRT-LM runtime',
            ),
          ),
        );
      });
    }
  }

  for (final (scenario, dependencies, expectedAssetIds) in [
    ('the LiteRT-LM companion', const ['llamadart_litert_lm_flutter'], []),
    (
      'both companions',
      const ['llamadart_llama_cpp_flutter', 'llamadart_litert_lm_flutter'],
      ['package:llamadart/llamadart'],
    ),
  ]) {
    test('build hook drops companion-implied LiteRT-LM from the Flutter macOS '
        'x64 slice with a warning for $scenario', () async {
      final records = <String>[];
      final subscription = Logger.root.onRecord.listen(
        (record) => records.add(record.message),
      );
      addTearDown(subscription.cancel);
      final stderrLines = await _capturingStderr(
        () async => testCodeBuildHook(
          mainMethod: build_hook.main,
          targetOS: OS.macOS,
          targetArchitecture: Architecture.x64,
          userDefines: await _flutterAppleUserDefines(
            dependencies: dependencies,
            defines: {
              'llamadart_native_runtimes': {
                'runtimes': ['litert_lm'],
                'platforms': {
                  'macos': ['litert_lm'],
                },
              },
            },
          ),
          check: (input, output) {
            expect(
              output.assets.encodedAssets
                  .map((asset) => asset.asCodeAsset.id)
                  .toList(growable: false),
              expectedAssetIds,
            );
            final outputDir = input.outputDirectory.toFilePath();
            expect(
              Directory(path.join(outputDir, 'llamadart_bin')).existsSync(),
              isFalse,
            );
          },
        ),
      );
      expect(stderrLines, contains(_macOsX64LiteRtLmSkippedWarning));
      _expectNoLiteRtLmBundleRequest(records);
    });
  }

  for (final bundleKey in ['macos-x86_64', 'macos-x64']) {
    test('build hook fails a Flutter macOS x64 build whose $bundleKey entry '
        'names LiteRT-LM', () async {
      await expectLater(
        testCodeBuildHook(
          mainMethod: build_hook.main,
          targetOS: OS.macOS,
          targetArchitecture: Architecture.x64,
          userDefines: await _flutterAppleUserDefines(
            dependencies: const ['llamadart_litert_lm_flutter'],
            defines: {
              'llamadart_native_runtimes': {
                'platforms': {
                  bundleKey: ['litert_lm'],
                },
              },
            },
          ),
          check: (_, _) {},
        ),
        throwsA(
          isA<Exception>().having(
            (error) => error.toString(),
            'message',
            allOf(
              contains(
                'LiteRT-LM is not available on macOS x86_64: '
                'litert-lm-native publishes arm64-only macOS runtimes '
                '(leehack/litert-lm-native#72).',
              ),
              contains(
                'Remove litert_lm from the macos-x86_64 entry of '
                'llamadart_native_runtimes',
              ),
            ),
          ),
        ),
      );
    });
  }

  test(
    'build hook keeps iOS LiteRT-LM on SwiftPM without probing the manifest',
    () async {
      await testCodeBuildHook(
        mainMethod: build_hook.main,
        targetOS: OS.iOS,
        targetArchitecture: Architecture.arm64,
        targetIOSSdk: IOSSdk.iPhoneOS,
        userDefines: await _flutterLiteRtLmOnlyUserDefines(
          liteRtLmManifest: _publishedLiteRtLmCompanion0014Manifest(),
        ),
        check: (input, output) {
          expect(output.assets.encodedAssets, isEmpty);
          final outputDir = input.outputDirectory.toFilePath();
          expect(
            Directory(path.join(outputDir, 'llamadart_bin')).existsSync(),
            isFalse,
          );
        },
      );
    },
  );

  test(
    'build hook keeps non-Flutter macOS LiteRT-LM on the hook cache',
    () async {
      await testCodeBuildHook(
        mainMethod: build_hook.main,
        targetOS: OS.macOS,
        targetArchitecture: Architecture.arm64,
        userDefines: await _nonFlutterConsumerUserDefines(
          dependencies: const ['llamadart_litert_lm_flutter'],
          defines: {
            'llamadart_native_runtimes': ['litert_lm'],
          },
        ),
        check: (input, output) {
          expect(output.assets.encodedAssets, isEmpty);
          final outputDir = input.outputDirectory.toFilePath();
          expect(
            Directory(path.join(outputDir, 'llamadart_bin')).existsSync(),
            isTrue,
          );
        },
      );
    },
  );

  test('build hook hands both macOS runtimes to SwiftPM companions', () async {
    await testCodeBuildHook(
      mainMethod: build_hook.main,
      targetOS: OS.macOS,
      targetArchitecture: Architecture.arm64,
      userDefines: await _flutterAppleUserDefines(
        dependencies: const [
          'llamadart_llama_cpp_flutter',
          'llamadart_litert_lm_flutter',
        ],
      ),
      check: (input, output) {
        final codeAssets = output.assets.encodedAssets
            .where((asset) => asset.isCodeAsset)
            .map((asset) => asset.asCodeAsset)
            .toList(growable: false);

        expect(codeAssets, hasLength(1));
        final codeAsset = codeAssets.single;
        expect(codeAsset.id, 'package:llamadart/llamadart');
        expect(codeAsset.file, isNull);
        expect(codeAsset.linkMode, isA<LookupInProcess>());

        final outputDir = input.outputDirectory.toFilePath();
        expect(
          Directory(path.join(outputDir, 'llamadart_bin')).existsSync(),
          isFalse,
        );
      },
    );
  });

  test('build hook mixes macOS llama.cpp SPM with LiteRT-LM hook assets for an '
      'older LiteRT-LM companion', () async {
    await testCodeBuildHook(
      mainMethod: build_hook.main,
      targetOS: OS.macOS,
      targetArchitecture: Architecture.arm64,
      userDefines: await _flutterAppleUserDefines(
        dependencies: const [
          'llamadart_llama_cpp_flutter',
          'llamadart_litert_lm_flutter',
        ],
        liteRtLmManifest: _publishedLiteRtLmCompanion0014Manifest(),
      ),
      check: (input, output) {
        final codeAssets = output.assets.encodedAssets
            .where((asset) => asset.isCodeAsset)
            .map((asset) => asset.asCodeAsset)
            .toList(growable: false);

        expect(codeAssets, hasLength(1));
        expect(codeAssets.single.linkMode, isA<LookupInProcess>());
        final outputDir = input.outputDirectory.toFilePath();
        expect(
          Directory(path.join(outputDir, 'llamadart_bin')).existsSync(),
          isTrue,
        );
      },
    );
  });

  test(
    'build hook uses SPM process lookup for Flutter iOS llama.cpp companion',
    () async {
      await testCodeBuildHook(
        mainMethod: build_hook.main,
        targetOS: OS.iOS,
        targetArchitecture: Architecture.arm64,
        targetIOSSdk: IOSSdk.iPhoneOS,
        userDefines: await _flutterAppleUserDefines(
          dependencies: const ['llamadart_llama_cpp_flutter'],
          defines: {
            'llamadart_native_runtimes': ['litert_lm'],
          },
        ),
        check: (_, output) {
          final codeAssets = output.assets.encodedAssets
              .where((asset) => asset.isCodeAsset)
              .map((asset) => asset.asCodeAsset)
              .toList(growable: false);

          expect(codeAssets, hasLength(1));
          final codeAsset = codeAssets.single;
          expect(codeAsset.id, 'package:llamadart/llamadart');
          expect(codeAsset.file, isNull);
          expect(codeAsset.linkMode, isA<LookupInProcess>());
        },
      );
    },
  );

  test(
    'build hook bundles iOS x64 simulator llama.cpp without companion packages',
    () async {
      await testCodeBuildHook(
        mainMethod: build_hook.main,
        targetOS: OS.iOS,
        targetArchitecture: Architecture.x64,
        targetIOSSdk: IOSSdk.iPhoneSimulator,
        userDefines: _llamaCppOnlyUserDefines(),
        check: (_, output) {
          final codeAssets = output.assets.encodedAssets
              .where((asset) => asset.isCodeAsset)
              .map((asset) => asset.asCodeAsset)
              .toList(growable: false);

          expect(codeAssets.map((asset) => asset.id), [
            'package:llamadart/llamadart',
          ]);
          expect(codeAssets.single.linkMode, isA<DynamicLoadingBundled>());
        },
      );
    },
  );

  test('build hook drops unavailable LiteRT-LM from both and empty '
      'selections', () async {
    for (final userDefines in [
      _bothRuntimeUserDefines(),
      _emptyRuntimeUserDefines(),
    ]) {
      await testCodeBuildHook(
        mainMethod: build_hook.main,
        targetOS: OS.iOS,
        targetArchitecture: Architecture.x64,
        targetIOSSdk: IOSSdk.iPhoneSimulator,
        userDefines: userDefines,
        check: (_, output) {
          final codeAssets = output.assets.encodedAssets
              .where((asset) => asset.isCodeAsset)
              .map((asset) => asset.asCodeAsset)
              .toList(growable: false);

          expect(codeAssets.map((asset) => asset.id), [
            'package:llamadart/llamadart',
          ]);
          expect(codeAssets.single.linkMode, isA<DynamicLoadingBundled>());
        },
      );
    }
  });

  test(
    'build hook ignores nested pubspec keys when detecting companions',
    () async {
      await testCodeBuildHook(
        mainMethod: build_hook.main,
        targetOS: OS.iOS,
        targetArchitecture: Architecture.arm64,
        targetIOSSdk: IOSSdk.iPhoneOS,
        userDefines: await _flutterAppleUserDefines(
          dependencies: const [],
          dependenciesYaml: '''
  not_a_companion:
    llamadart_llama_cpp_flutter: true
''',
        ),
        check: (_, output) {
          final codeAssets = output.assets.encodedAssets
              .where((asset) => asset.isCodeAsset)
              .map((asset) => asset.asCodeAsset)
              .toList(growable: false);

          final codeAssetIds = codeAssets.map((asset) => asset.id).toSet();
          expect(codeAssetIds, contains('package:llamadart/llamadart'));
          for (final assetName in _iosLiteRtAssetNames) {
            expect(codeAssetIds, contains('package:llamadart/$assetName'));
          }
          expect(
            codeAssets.every(
              (asset) => asset.linkMode is DynamicLoadingBundled,
            ),
            isTrue,
          );
        },
      );
    },
  );

  test(
    'build hook lets runtime config win outside Flutter Apple apps',
    () async {
      await testCodeBuildHook(
        mainMethod: build_hook.main,
        targetOS: OS.iOS,
        targetArchitecture: Architecture.arm64,
        targetIOSSdk: IOSSdk.iPhoneOS,
        userDefines: await _nonFlutterConsumerUserDefines(
          dependencies: const ['llamadart_litert_lm_flutter'],
          defines: {
            'llamadart_native_runtimes': ['llama_cpp'],
          },
        ),
        check: (_, output) {
          final codeAssets = output.assets.encodedAssets
              .where((asset) => asset.isCodeAsset)
              .map((asset) => asset.asCodeAsset)
              .toList(growable: false);

          expect(codeAssets.map((asset) => asset.id), [
            'package:llamadart/llamadart',
          ]);
          expect(codeAssets.single.linkMode, isA<DynamicLoadingBundled>());
        },
      );
    },
  );

  test(
    'build hook fails when explicitly requested LiteRT-LM is unavailable',
    () async {
      await expectLater(
        testCodeBuildHook(
          mainMethod: build_hook.main,
          targetOS: OS.iOS,
          targetArchitecture: Architecture.x64,
          targetIOSSdk: IOSSdk.iPhoneSimulator,
          userDefines: _liteRtLmOnlyUserDefines(),
          check: (_, _) {},
        ),
        throwsA(
          isA<Exception>().having(
            (error) => error.toString(),
            'message',
            contains('LiteRT-LM runtime is not available for ios-x86_64-sim'),
          ),
        ),
      );
    },
  );

  test(
    'build hook fails when Flutter companion selects unavailable LiteRT-LM',
    () async {
      await expectLater(
        testCodeBuildHook(
          mainMethod: build_hook.main,
          targetOS: OS.iOS,
          targetArchitecture: Architecture.x64,
          targetIOSSdk: IOSSdk.iPhoneSimulator,
          userDefines: await _flutterAppleUserDefines(
            dependencies: const ['llamadart_litert_lm_flutter'],
          ),
          check: (_, _) {},
        ),
        throwsA(
          isA<Exception>().having(
            (error) => error.toString(),
            'message',
            contains('LiteRT-LM runtime is not available for ios-x86_64-sim'),
          ),
        ),
      );
    },
  );
}

const _macOsX64LiteRtLmSkippedWarning =
    'warning: llamadart: LiteRT-LM is not available on macOS x86_64: '
    'litert-lm-native publishes arm64-only macOS runtimes '
    '(leehack/litert-lm-native#72). The x86_64 slice of this build leaves '
    'LiteRT-LM out; selecting it there throws LlamaUnsupportedException.';

/// Fails when the hook looked up, downloaded or cached any LiteRT-LM bundle.
void _expectNoLiteRtLmBundleRequest(List<String> records) {
  expect(records, isNot(contains(contains('LiteRT-LM bundle'))));
  expect(records, isNot(contains(contains('litert-lm-native-runtime-'))));
}

/// Runs [body] with `stderr` captured, returning the lines it wrote.
Future<List<String>> _capturingStderr(Future<void> Function() body) async {
  final captured = _CapturedStderr();
  await IOOverrides.runZoned(body, stderr: () => captured);
  return captured.lines;
}

class _CapturedStderr implements Stdout {
  final lines = <String>[];

  @override
  void writeln([Object? object = '']) => lines.add('$object');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

String _readPinnedConst(String name) {
  final source = File(
    'lib/src/hook/native_release_pins.dart',
  ).readAsStringSync();
  final match = RegExp("const $name = '([^']+)';").firstMatch(source);
  if (match == null) {
    throw StateError(
      'Could not locate $name in lib/src/hook/native_release_pins.dart',
    );
  }
  return match.group(1)!;
}

PackageUserDefines _liteRtLmOnlyUserDefines() => PackageUserDefines(
  workspacePubspec: PackageUserDefinesSource(
    defines: {
      'llamadart_native_runtimes': ['litert_lm'],
    },
    basePath: Directory.current.uri,
  ),
);

PackageUserDefines _bothRuntimeUserDefines() => PackageUserDefines(
  workspacePubspec: PackageUserDefinesSource(
    defines: {
      'llamadart_native_runtimes': ['both'],
    },
    basePath: Directory.current.uri,
  ),
);

PackageUserDefines _emptyRuntimeUserDefines() => PackageUserDefines(
  workspacePubspec: PackageUserDefinesSource(
    defines: {'llamadart_native_runtimes': <String>[]},
    basePath: Directory.current.uri,
  ),
);

Future<PackageUserDefines> _flutterLiteRtLmOnlyUserDefines({
  bool resolveLiteRtLmCompanion = true,
  String? liteRtLmManifest,
}) {
  return _flutterAppleUserDefines(
    dependencies: const ['llamadart_litert_lm_flutter'],
    defines: {
      'llamadart_native_runtimes': ['llama_cpp'],
    },
    resolveLiteRtLmCompanion: resolveLiteRtLmCompanion,
    liteRtLmManifest: liteRtLmManifest,
  );
}

/// The maintained companion manifest, which links the complete macOS runtime.
String _liteRtLmCompanionManifest() => File(
  'packages/llamadart_litert_lm_flutter/'
  'darwin/llamadart_litert_lm_flutter/Package.swift',
).readAsStringSync();

/// The manifest published as companion 0.0.14, which links only LiteRtLm and
/// the CLiteRTLM shim on macOS.
String _publishedLiteRtLmCompanion0014Manifest() => File(
  'test/fixtures/litert_lm/llamadart_litert_lm_flutter_0.0.14_Package.swift',
).readAsStringSync();

Future<PackageUserDefines> _nonFlutterConsumerUserDefines({
  required List<String> dependencies,
  Map<String, Object?> defines = const {},
}) async {
  final dir = await Directory.systemTemp.createTemp('llamadart_dart_consumer_');
  addTearDown(() {
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });

  final pubspec = File(path.join(dir.path, 'pubspec.yaml'));
  await pubspec.writeAsString('''
name: llamadart_dart_consumer
publish_to: none

environment:
  sdk: ^3.10.7

dependencies:
${dependencies.map((dependency) => '  $dependency: ^0.8.0').join('\n')}
''');

  return PackageUserDefines(
    workspacePubspec: PackageUserDefinesSource(
      defines: defines,
      basePath: pubspec.uri,
    ),
  );
}

Future<PackageUserDefines> _flutterAppleUserDefines({
  required List<String> dependencies,
  Map<String, Object?> defines = const {},
  String dependenciesYaml = '',
  String? companionTag,
  String companionVersion = '0.0.18',
  bool missingConfiguration = false,
  bool duplicateCompanion = false,
  bool localArtifacts = false,
  bool workspaceMember = false,
  bool resolveLiteRtLmCompanion = true,
  String? liteRtLmManifest,
  void Function(Directory)? mutate,
}) async {
  final dir = await Directory.systemTemp.createTemp(
    'llamadart_apple_consumer_',
  );
  addTearDown(() {
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });

  final consumer = workspaceMember
      ? Directory(path.join(dir.path, 'app'))
      : dir;
  await consumer.create(recursive: true);
  final pubspec = File(path.join(consumer.path, 'pubspec.yaml'));
  await pubspec.writeAsString('''
name: llamadart_apple_consumer
publish_to: none

environment:
  sdk: ^3.10.7
  flutter: ^3.38.0

dependencies:
  llamadart: ^0.8.22
  flutter:
    sdk: flutter
${dependenciesYaml.trimRight()}
${dependencies.map((dependency) => '  $dependency: ^0.0.17').join('\n')}
''');

  final packageEntries = <Map<String, String>>[];
  if (dependencies.contains('llamadart_llama_cpp_flutter') &&
      !missingConfiguration) {
    final companion = Directory(path.join(dir.path, 'resolved companion'));
    await companion.create();
    await File(path.join(companion.path, 'pubspec.yaml')).writeAsString(
      'name: llamadart_llama_cpp_flutter\nversion: $companionVersion\n',
    );
    final manifest = File(
      path.join(
        companion.path,
        'darwin',
        'llamadart_llama_cpp_flutter',
        'Package.swift',
      ),
    );
    await manifest.parent.create(recursive: true);
    await manifest.writeAsString(
      File(
        'packages/llamadart_llama_cpp_flutter/'
        'darwin/llamadart_llama_cpp_flutter/Package.swift',
      ).readAsStringSync().replaceFirst(
        'let llamaCppTag = "${_readPinnedConst('llamaCppTag')}"',
        'let llamaCppTag = "${companionTag ?? _readPinnedConst('llamaCppTag')}"',
      ),
    );
    if (localArtifacts) {
      await Directory(path.join(manifest.parent.path, 'Artifacts')).create();
    }
    final entry = {
      'name': 'llamadart_llama_cpp_flutter',
      'rootUri': '../resolved%20companion',
    };
    packageEntries.addAll([entry, if (duplicateCompanion) entry]);
  }
  if (dependencies.contains('llamadart_litert_lm_flutter') &&
      resolveLiteRtLmCompanion &&
      !missingConfiguration) {
    final companion = Directory(
      path.join(dir.path, 'resolved litert companion'),
    );
    final manifest = File(
      path.join(
        companion.path,
        'darwin',
        'llamadart_litert_lm_flutter',
        'Package.swift',
      ),
    );
    await manifest.parent.create(recursive: true);
    await File(
      path.join(companion.path, 'pubspec.yaml'),
    ).writeAsString('name: llamadart_litert_lm_flutter\nversion: 0.0.14\n');
    await manifest.writeAsString(
      liteRtLmManifest ?? _liteRtLmCompanionManifest(),
    );
    packageEntries.add({
      'name': 'llamadart_litert_lm_flutter',
      'rootUri': '../resolved%20litert%20companion',
    });
  }
  if (packageEntries.isNotEmpty) {
    final config = File(
      path.join(dir.path, '.dart_tool', 'package_config.json'),
    );
    await config.parent.create();
    await config.writeAsString(
      jsonEncode({'configVersion': 2, 'packages': packageEntries}),
    );
  }
  mutate?.call(dir);

  return PackageUserDefines(
    workspacePubspec: PackageUserDefinesSource(
      defines: defines,
      basePath: pubspec.uri,
    ),
  );
}

PackageUserDefines _llamaCppOnlyUserDefines() => PackageUserDefines(
  workspacePubspec: PackageUserDefinesSource(
    defines: {
      'llamadart_native_runtimes': ['llama_cpp'],
    },
    basePath: Directory.current.uri,
  ),
);

void _expectSpecLibraries(
  String source,
  String bundleKey,
  List<String> expectedLibraries,
) {
  final escapedKey = RegExp.escape(bundleKey);
  final match = RegExp(
    "\\bLiteRtLmBundleSpec\\(\\s*'$escapedKey',[\\s\\S]*?"
    'requiredLibraries:\\s*\\{([\\s\\S]*?)\\},',
  ).firstMatch(source);
  if (match == null) {
    throw StateError('Could not locate LiteRT-LM libraries for $bundleKey');
  }
  final spec = match.group(1)!;
  for (final library in expectedLibraries) {
    expect(spec, contains("'$library'"), reason: bundleKey);
  }
}

void _expectSpecChecksum(String source, String bundleKey) {
  final escapedKey = RegExp.escape(bundleKey);
  final match = RegExp(
    "\\bLiteRtLmBundleSpec\\(\\s*'$escapedKey',[\\s\\S]*?"
    "sha256:\\s*'([0-9a-f]{64})',",
  ).firstMatch(source);
  expect(match, isNotNull, reason: bundleKey);
}

const List<String> _androidLiteRtLibraries = [
  'libGemmaModelConstraintProvider.so',
  'libLiteRtGpuAccelerator.so',
  'libLiteRtLm.so',
  'libLiteRtOpenClAccelerator.so',
  'libLiteRtTopKOpenClSampler.so',
  'libLiteRtTopKWebGpuSampler.so',
  'libLiteRtWebGpuAccelerator.so',
  'libwebgpu_dawn.so',
];

const List<String> _iosLiteRtLibraries = [
  'LiteRtLm',
  'CLiteRTLM',
  'LiteRtMetalAccelerator',
  'LiteRtTopKMetalSampler',
];

const List<String> _iosLiteRtAssetNames = [
  'litert_lm_LiteRtLm',
  'litert_lm_CLiteRTLM',
  'litert_lm_LiteRtMetalAccelerator',
  'litert_lm_LiteRtTopKMetalSampler',
];

const List<String> _macosArm64LiteRtLibraries = [
  'libCLiteRTLM_mac.dylib',
  'libGemmaModelConstraintProvider.dylib',
  'libLiteRt.dylib',
  'libLiteRtLm.dylib',
  'libLiteRtMetalAccelerator.dylib',
  'libLiteRtTopKMetalSampler.dylib',
  'libLiteRtTopKWebGpuSampler.dylib',
  'libLiteRtWebGpuAccelerator.dylib',
  'libwebgpu_dawn.dylib',
];

const List<String> _linuxLiteRtLibraries = [
  'libGemmaModelConstraintProvider.so',
  'libLiteRt.so',
  'libLiteRtLm.so',
  'libwebgpu_dawn.so',
  'libLiteRtTopKWebGpuSampler.so',
  'libLiteRtWebGpuAccelerator.so',
];

const List<String> _linuxLiteRtAssetNames = [
  'litert_lm_GemmaModelConstraintProvider',
  'litert_lm_LiteRt',
  'litert_lm_LiteRtLm',
  'litert_lm_webgpu_dawn',
  'litert_lm_LiteRtTopKWebGpuSampler',
  'litert_lm_LiteRtWebGpuAccelerator',
];

const List<String> _windowsLiteRtLibraries = [
  'LiteRtLm.dll',
  'dxcompiler.dll',
  'dxil.dll',
  'libGemmaModelConstraintProvider.dll',
  'libLiteRt.dll',
  'libwebgpu_dawn.dll',
  'webgpu_dawn.dll',
  'libLiteRtTopKWebGpuSampler.dll',
  'libLiteRtWebGpuAccelerator.dll',
];

Future<void> _backupDirectory(Directory directory, Directory backup) async {
  if (backup.existsSync()) {
    await backup.delete(recursive: true);
  }
  if (directory.existsSync()) {
    await directory.rename(backup.path);
  }
}

Future<void> _restoreDirectory(Directory directory, Directory backup) async {
  if (directory.existsSync()) {
    await directory.delete(recursive: true);
  }
  if (backup.existsSync()) {
    await backup.rename(directory.path);
  }
}

Future<void> _writeBundleLibraries(
  Directory bundleDir,
  List<String> fileNames,
) async {
  if (bundleDir.existsSync()) {
    await bundleDir.delete(recursive: true);
  }
  await bundleDir.create(recursive: true);
  for (final name in fileNames) {
    await File(path.join(bundleDir.path, name)).writeAsString('fake-$name');
  }
}
