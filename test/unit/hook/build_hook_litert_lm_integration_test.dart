@TestOn('vm')
library;

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import '../../../hook/build.dart' as build_hook;

void main() {
  final nativeTag = _readHookConst('_llamaCppTag');
  final litertVersion = _readHookConst('_litertLmVersion');
  final linuxArm64LitertSha256 = _readLiteRtBundleSha256('linux-arm64');
  final iosArm64LitertSha256 = _readLiteRtBundleSha256('ios-arm64');
  final iosArm64SimLitertSha256 = _readLiteRtBundleSha256('ios-arm64-sim');
  final iosX64SimLitertSha256 = _readLiteRtBundleSha256('ios-x64-sim');
  final nativeBundleDir = Directory(
    '.dart_tool/llamadart/native_bundles/$nativeTag/linux-arm64/extracted',
  );
  final litertBundleDir = Directory(
    '.dart_tool/llamadart/litert_lm/$litertVersion/linux/arm64',
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
  final iosX64SimLitertBundleDir = Directory(
    '.dart_tool/llamadart/litert_lm/$litertVersion/ios/x64-sim',
  );
  final backupPairs = [
    (nativeBundleDir, Directory('${nativeBundleDir.path}.__litert_test')),
    (litertBundleDir, Directory('${litertBundleDir.path}.__litert_test')),
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
    (
      iosX64SimLitertBundleDir,
      Directory('${iosX64SimLitertBundleDir.path}.__litert_test'),
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
    await _writeBundleLibraries(
      litertBundleDir,
      _linuxLiteRtLibraries,
      sha256: linuxArm64LitertSha256,
    );
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
      iosX64SimLitertBundleDir,
    ]) {
      await _writeBundleLibraries(
        directory,
        const ['libLiteRtLm.dylib', 'libStreamProxy.dylib'],
        sha256: switch (directory.path) {
          final path when path == iosDeviceLitertBundleDir.path =>
            iosArm64LitertSha256,
          final path when path == iosArm64SimLitertBundleDir.path =>
            iosArm64SimLitertSha256,
          final path when path == iosX64SimLitertBundleDir.path =>
            iosX64SimLitertSha256,
          _ => null,
        },
      );
    }
  });

  tearDownAll(() async {
    for (final (directory, backup) in backupPairs.reversed) {
      await _restoreDirectory(directory, backup);
    }
  });

  test('LiteRT-LM bundle specs require platform runtime companions', () {
    final source = File('hook/build.dart').readAsStringSync();

    _expectSpecLibraries(source, 'android-arm64', _androidLiteRtLibraries);
    _expectSpecLibraries(source, 'android-x64', _androidLiteRtLibraries);
    _expectSpecLibraries(source, 'ios-arm64', _iosLiteRtLibraries);
    _expectSpecLibraries(source, 'ios-arm64-sim', _iosLiteRtLibraries);
    _expectSpecLibraries(source, 'ios-x64-sim', _iosLiteRtLibraries);
    _expectSpecLibraries(source, 'macos-arm64', _macosArm64LiteRtLibraries);
    _expectSpecLibraries(source, 'macos-x64', _macosX64LiteRtLibraries);
    _expectSpecLibraries(source, 'linux-arm64', _linuxLiteRtLibraries);
    _expectSpecLibraries(source, 'linux-x64', _linuxLiteRtLibraries);
    _expectSpecLibraries(source, 'windows-x64', _windowsLiteRtLibraries);
  });

  test('build hook emits Linux arm64 LiteRT-LM runtime companions', () async {
    await testCodeBuildHook(
      mainMethod: build_hook.main,
      targetOS: OS.linux,
      targetArchitecture: Architecture.arm64,
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
  });

  test('build hook can emit LiteRT-LM runtime without llama.cpp', () async {
    final userDefines = PackageUserDefines(
      workspacePubspec: PackageUserDefinesSource(
        defines: {
          'llamadart_native_runtimes': ['litert_lm'],
        },
        basePath: Directory.current.uri,
      ),
    );

    await testCodeBuildHook(
      mainMethod: build_hook.main,
      targetOS: OS.linux,
      targetArchitecture: Architecture.arm64,
      userDefines: userDefines,
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
    'build hook emits iOS device LiteRT-LM runtime and StreamProxy',
    () async {
      await testCodeBuildHook(
        mainMethod: build_hook.main,
        targetOS: OS.iOS,
        targetArchitecture: Architecture.arm64,
        targetIOSSdk: IOSSdk.iPhoneOS,
        check: (input, output) {
          _expectLiteRtLmAssets(
            output.assets.encodedAssets,
            liteRtLmFileName: 'libLiteRtLm.dylib',
            streamProxyFileName: 'libStreamProxy.dylib',
          );
        },
      );
    },
  );

  test(
    'build hook emits iOS arm64 simulator LiteRT-LM runtime and StreamProxy',
    () async {
      await testCodeBuildHook(
        mainMethod: build_hook.main,
        targetOS: OS.iOS,
        targetArchitecture: Architecture.arm64,
        targetIOSSdk: IOSSdk.iPhoneSimulator,
        check: (input, output) {
          _expectLiteRtLmAssets(
            output.assets.encodedAssets,
            liteRtLmFileName: 'libLiteRtLm.dylib',
            streamProxyFileName: 'libStreamProxy.dylib',
          );
        },
      );
    },
  );

  test(
    'build hook emits iOS x64 simulator LiteRT-LM runtime and StreamProxy',
    () async {
      await testCodeBuildHook(
        mainMethod: build_hook.main,
        targetOS: OS.iOS,
        targetArchitecture: Architecture.x64,
        targetIOSSdk: IOSSdk.iPhoneSimulator,
        check: (input, output) {
          _expectLiteRtLmAssets(
            output.assets.encodedAssets,
            liteRtLmFileName: 'libLiteRtLm.dylib',
            streamProxyFileName: 'libStreamProxy.dylib',
          );
        },
      );
    },
  );
}

String _readHookConst(String name) {
  final source = File('hook/build.dart').readAsStringSync();
  final match = RegExp("const $name = '([^']+)';").firstMatch(source);
  if (match == null) {
    throw StateError('Could not locate $name in hook/build.dart');
  }
  return match.group(1)!;
}

void _expectSpecLibraries(
  String source,
  String bundleKey,
  List<String> expectedLibraries,
) {
  final escapedKey = RegExp.escape(bundleKey);
  final match = RegExp(
    "'$escapedKey':\\s*_LiteRtLmBundleSpec\\([\\s\\S]*?"
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

const List<String> _androidLiteRtLibraries = [
  'libGemmaModelConstraintProvider.so',
  'libLiteRt.so',
  'libLiteRtGpuAccelerator.so',
  'libLiteRtLm.so',
  'libLiteRtOpenClAccelerator.so',
  'libLiteRtTopKOpenClSampler.so',
  'libLiteRtTopKWebGpuSampler.so',
  'libLiteRtWebGpuAccelerator.so',
  'libStreamProxy.so',
];

const List<String> _iosLiteRtLibraries = [
  'libLiteRtLm.dylib',
  'libStreamProxy.dylib',
];

const List<String> _macosArm64LiteRtLibraries = [
  'libGemmaModelConstraintProvider.dylib',
  'libLiteRt.dylib',
  'libLiteRtLm.dylib',
  'libLiteRtMetalAccelerator.dylib',
  'libLiteRtTopKMetalSampler.dylib',
  'libLiteRtTopKWebGpuSampler.dylib',
  'libLiteRtWebGpuAccelerator.dylib',
  'libStreamProxy.dylib',
];

const List<String> _macosX64LiteRtLibraries = [
  'libLiteRtLm.dylib',
  'libStreamProxy.dylib',
];

const List<String> _linuxLiteRtLibraries = [
  'libGemmaModelConstraintProvider.so',
  'libLiteRt.so',
  'libLiteRtLm.so',
  'libLiteRtTopKWebGpuSampler.so',
  'libLiteRtWebGpuAccelerator.so',
  'libStreamProxy.so',
];

const List<String> _linuxLiteRtAssetNames = [
  'litert_lm_GemmaModelConstraintProvider',
  'litert_lm_LiteRt',
  'litert_lm_LiteRtLm',
  'litert_lm_LiteRtTopKWebGpuSampler',
  'litert_lm_LiteRtWebGpuAccelerator',
  'litert_lm_StreamProxy',
];

const List<String> _windowsLiteRtLibraries = [
  'LiteRtLm.dll',
  'StreamProxy.dll',
  'libGemmaModelConstraintProvider.dll',
  'libLiteRt.dll',
  'libLiteRtTopKWebGpuSampler.dll',
  'libLiteRtWebGpuAccelerator.dll',
];

String _readLiteRtBundleSha256(String bundleKey) {
  final source = File('hook/build.dart').readAsStringSync();
  final escapedKey = RegExp.escape(bundleKey);
  final match = RegExp(
    "'$escapedKey':\\s*_LiteRtLmBundleSpec\\([\\s\\S]*?sha256:\\s*'([^']+)'",
  ).firstMatch(source);
  if (match == null) {
    throw StateError('Could not locate LiteRT-LM checksum for $bundleKey');
  }
  return match.group(1)!;
}

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
  List<String> fileNames, {
  String? sha256,
}) async {
  if (bundleDir.existsSync()) {
    await bundleDir.delete(recursive: true);
  }
  await bundleDir.create(recursive: true);
  for (final name in fileNames) {
    await File(path.join(bundleDir.path, name)).writeAsString('fake-$name');
  }
  if (sha256 != null) {
    await File(
      path.join(bundleDir.path, '.llamadart_litert_lm.sha256'),
    ).writeAsString('$sha256\n');
  }
}

void _expectLiteRtLmAssets(
  Iterable<EncodedAsset> encodedAssets, {
  required String liteRtLmFileName,
  required String streamProxyFileName,
}) {
  final codeAssets = encodedAssets
      .where((asset) => asset.isCodeAsset)
      .map((asset) => asset.asCodeAsset)
      .toList(growable: false);

  final codeAssetIds = codeAssets.map((asset) => asset.id).toSet();
  final emittedNames = codeAssets
      .map((asset) => path.basename(asset.file!.toFilePath()))
      .toSet();

  expect(codeAssetIds, contains('package:llamadart/llamadart'));
  expect(codeAssetIds, contains('package:llamadart/litert_lm_LiteRtLm'));
  expect(codeAssetIds, contains('package:llamadart/litert_lm_StreamProxy'));
  expect(emittedNames, contains(liteRtLmFileName));
  expect(emittedNames, contains(streamProxyFileName));
}
