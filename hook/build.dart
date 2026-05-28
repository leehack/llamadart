import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:hooks/hooks.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;

import 'package:llamadart/src/hook/native_bundle_config.dart';

const _llamaCppTag = 'b9371';
const _nativeRepoSlug = 'leehack/llamadart-native';

const _packageName = 'llamadart';
const _thirdPartyDir = 'third_party';
const _binDir = 'bin';
const _dartToolDir = '.dart_tool';
const _cacheBaseDir = 'llamadart';
const _bundleCacheDir = 'native_bundles';
const _reportDir = 'llamadart_bin';
const _allowLegacyLocalBundleEnv = 'LLAMADART_ALLOW_LEGACY_LOCAL_BUNDLES';
const _litertLmVersion = '0.12.0';
const _litertLmNativeReleaseBaseUrl =
    'https://github.com/leehack/litert-lm-native/releases/download/'
    'v$_litertLmVersion';
const _litertLmCacheDir = 'litert_lm';
const _litertLmChecksumFileName = '.llamadart_litert_lm.sha256';

const _litertLmBundles = <String, _LiteRtLmBundleSpec>{
  'android-arm64': _LiteRtLmBundleSpec(
    directoryName: 'android/arm64',
    archiveName: 'litert-lm-native-runtime-android-arm64-v0.12.0.tar.gz',
    sha256: '1d4332e740aca7bb3d23af20d94fb16193803e8997138a87633e8de4a096a026',
    releaseBaseUrl: _litertLmNativeReleaseBaseUrl,
    sourcePrefix: 'android/arm64',
    requiredLibraries: {
      'libGemmaModelConstraintProvider.so',
      'libLiteRt.so',
      'libLiteRtGpuAccelerator.so',
      'libLiteRtLm.so',
      'libLiteRtOpenClAccelerator.so',
      'libLiteRtTopKOpenClSampler.so',
      'libLiteRtTopKWebGpuSampler.so',
      'libLiteRtWebGpuAccelerator.so',
      'libStreamProxy.so',
    },
    emitAllLibraries: true,
  ),
  'android-x64': _LiteRtLmBundleSpec(
    directoryName: 'android/x64',
    archiveName: 'litert-lm-native-runtime-android-x64-v0.12.0.tar.gz',
    sha256: 'b59cb34a83d5e3b8c467fe9b670a7f810fe956f1b47b524271008546bc31c655',
    releaseBaseUrl: _litertLmNativeReleaseBaseUrl,
    sourcePrefix: 'android/x64',
    requiredLibraries: {
      'libGemmaModelConstraintProvider.so',
      'libLiteRt.so',
      'libLiteRtGpuAccelerator.so',
      'libLiteRtLm.so',
      'libLiteRtOpenClAccelerator.so',
      'libLiteRtTopKOpenClSampler.so',
      'libLiteRtTopKWebGpuSampler.so',
      'libLiteRtWebGpuAccelerator.so',
      'libStreamProxy.so',
    },
    emitAllLibraries: true,
  ),
  'ios-arm64': _LiteRtLmBundleSpec(
    directoryName: 'ios/arm64',
    archiveName: 'litert-lm-native-runtime-ios-arm64-v0.12.0.tar.gz',
    sha256: 'd1c48c085f901baac67097209814e25a84dfa61d79644a8fe6d125d6ab39c3c3',
    releaseBaseUrl: _litertLmNativeReleaseBaseUrl,
    sourcePrefix: 'ios/arm64',
    requiredLibraries: {'libLiteRtLm.dylib', 'libStreamProxy.dylib'},
  ),
  'ios-arm64-sim': _LiteRtLmBundleSpec(
    directoryName: 'ios/arm64-sim',
    archiveName: 'litert-lm-native-runtime-ios-arm64-sim-v0.12.0.tar.gz',
    sha256: '9ae754eb6a0e9d6ff51caa94864b24b520b7e73c46a46091b8a44f99b7a4aef6',
    releaseBaseUrl: _litertLmNativeReleaseBaseUrl,
    sourcePrefix: 'ios/arm64-sim',
    requiredLibraries: {'libLiteRtLm.dylib', 'libStreamProxy.dylib'},
  ),
  'ios-x64-sim': _LiteRtLmBundleSpec(
    directoryName: 'ios/x64-sim',
    archiveName: 'litert-lm-native-runtime-ios-x64-sim-v0.12.0.tar.gz',
    sha256: 'be573217169878cb5d79b70084730c5a2978230cc6d1b96144f694249e2027e0',
    releaseBaseUrl: _litertLmNativeReleaseBaseUrl,
    sourcePrefix: 'ios/x64-sim',
    requiredLibraries: {'libLiteRtLm.dylib', 'libStreamProxy.dylib'},
  ),
  'macos-arm64': _LiteRtLmBundleSpec(
    directoryName: 'macos/arm64',
    archiveName: 'litert-lm-native-runtime-macos-arm64-v0.12.0.tar.gz',
    sha256: '6fe694ccc895c904b173f2952b73b7698097eda18d8bff0210ea9fcf10ca3da9',
    releaseBaseUrl: _litertLmNativeReleaseBaseUrl,
    sourcePrefix: 'macos/arm64',
    requiredLibraries: {
      'libGemmaModelConstraintProvider.dylib',
      'libLiteRt.dylib',
      'libLiteRtLm.dylib',
      'libLiteRtMetalAccelerator.dylib',
      'libLiteRtTopKMetalSampler.dylib',
      'libLiteRtTopKWebGpuSampler.dylib',
      'libLiteRtWebGpuAccelerator.dylib',
      'libStreamProxy.dylib',
    },
  ),
  'macos-x64': _LiteRtLmBundleSpec(
    directoryName: 'macos/x64',
    archiveName: 'litert-lm-native-runtime-macos-x64-v0.12.0.tar.gz',
    sha256: '8b54daaf55d6cb2570b7a667891c71bba1578a5875d8c2b7230c2185b2e88bf4',
    releaseBaseUrl: _litertLmNativeReleaseBaseUrl,
    sourcePrefix: 'macos/x64',
    requiredLibraries: {'libLiteRtLm.dylib', 'libStreamProxy.dylib'},
  ),
  'linux-arm64': _LiteRtLmBundleSpec(
    directoryName: 'linux/arm64',
    archiveName: 'litert-lm-native-runtime-linux-arm64-v0.12.0.tar.gz',
    sha256: 'd0546e0f769b1156f973051dfd928d8f4448e0db9465d57386cf0490192651c1',
    releaseBaseUrl: _litertLmNativeReleaseBaseUrl,
    sourcePrefix: 'linux/arm64',
    requiredLibraries: {
      'libGemmaModelConstraintProvider.so',
      'libLiteRt.so',
      'libLiteRtLm.so',
      'libLiteRtTopKWebGpuSampler.so',
      'libLiteRtWebGpuAccelerator.so',
      'libStreamProxy.so',
    },
    emitAllLibraries: true,
  ),
  'linux-x64': _LiteRtLmBundleSpec(
    directoryName: 'linux/x64',
    archiveName: 'litert-lm-native-runtime-linux-x64-v0.12.0.tar.gz',
    sha256: 'e508e545d7be417895071c47612fd4fd5da842b05864f0776c98c2c67ad223e9',
    releaseBaseUrl: _litertLmNativeReleaseBaseUrl,
    sourcePrefix: 'linux/x64',
    requiredLibraries: {
      'libGemmaModelConstraintProvider.so',
      'libLiteRt.so',
      'libLiteRtLm.so',
      'libLiteRtTopKWebGpuSampler.so',
      'libLiteRtWebGpuAccelerator.so',
      'libStreamProxy.so',
    },
    emitAllLibraries: true,
  ),
  'windows-x64': _LiteRtLmBundleSpec(
    directoryName: 'windows/x64',
    archiveName: 'litert-lm-native-runtime-windows-x64-v0.12.0.tar.gz',
    sha256: '4c6ff1b3affd37c49c4d45538fdd2f376cc065a85a1339ca6c166e2b542072df',
    releaseBaseUrl: _litertLmNativeReleaseBaseUrl,
    sourcePrefix: 'windows/x64',
    requiredLibraries: {
      'LiteRtLm.dll',
      'StreamProxy.dll',
      'libGemmaModelConstraintProvider.dll',
      'libLiteRt.dll',
      'libLiteRtTopKWebGpuSampler.dll',
      'libLiteRtWebGpuAccelerator.dll',
    },
    emitAllLibraries: true,
  ),
};

const _dynamicLibraryExtensions = {'.so', '.dylib', '.dll'};
final _windowsCudartPattern = RegExp(r'^cudart64(?:[_-]?\d+)?\.dll$');
final _windowsCublasPattern = RegExp(r'^cublas64(?:[_-]?\d+)?\.dll$');
final _linuxVersionedSoPattern = RegExp(r'\.so\.\d+$');
final _nativeTagPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$');
final _githubRepoSegmentPattern = RegExp(r'^[A-Za-z0-9_.-]+$');

class _NativeBundleConfig {
  final String tag;
  final String repository;
  final Uri? localPath;

  const _NativeBundleConfig({
    required this.tag,
    required this.repository,
    required this.localPath,
  });

  bool get usesOverride =>
      tag != _llamaCppTag || repository != _nativeRepoSlug || localPath != null;

  String get sourceLabel {
    final pathUri = localPath;
    if (pathUri != null) {
      return 'local path ${pathUri.toFilePath()}';
    }
    return '$repository@$tag';
  }
}

class _LiteRtLmBundleSpec {
  final String directoryName;
  final String archiveName;
  final String? sha256;
  final String releaseBaseUrl;
  final String? sourcePrefix;
  final Set<String> requiredLibraries;
  final bool emitAllLibraries;

  const _LiteRtLmBundleSpec({
    required this.directoryName,
    required this.archiveName,
    required this.sha256,
    required this.releaseBaseUrl,
    this.sourcePrefix,
    required this.requiredLibraries,
    this.emitAllLibraries = false,
  });
}

void main(List<String> args) async {
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((record) {
    print('${record.level.name}: ${record.time}: ${record.message}');
  });

  final log = Logger('${_packageName}_hook');

  await build(args, (input, output) async {
    CodeConfig? code;
    try {
      code = input.config.code;
    } catch (_) {
      // Non-native targets (web) may not expose code config.
    }

    if (code == null) {
      log.info('Hook: Skipping native asset build for non-native platform.');
      return;
    }

    final isIosSimulator =
        code.targetOS == OS.iOS && code.iOS.targetSdk == IOSSdk.iPhoneSimulator;
    final spec = resolveNativeBundleSpec(
      os: code.targetOS,
      arch: code.targetArchitecture,
      isIosSimulator: isIosSimulator,
    );

    if (spec == null) {
      log.warning(
        'Unsupported platform/arch: ${code.targetOS}-${code.targetArchitecture}.',
      );
      return;
    }

    log.info('Hook Start: ${spec.bundle}');

    final nativeConfig = _resolveNativeBundleConfig(input.userDefines);
    log.info('Using native runtime source: ${nativeConfig.sourceLabel}');
    if (nativeConfig.usesOverride) {
      log.warning(
        'Native runtime overrides do not regenerate Dart FFI bindings. '
        'The selected binaries must stay ABI- and symbol-compatible with '
        '$_nativeRepoSlug@$_llamaCppTag.',
      );
    }

    final pkgRoot = input.packageRoot.toFilePath();
    final selectedRuntimes = selectNativeRuntimesForBundle(
      bundle: spec.bundle,
      rawUserConfig: input.userDefines[nativeRuntimesUserDefineKey],
      warn: log.warning,
    );
    if (selectedRuntimes.isEmpty) {
      throw Exception(
        'No native runtimes selected for ${spec.bundle}. Configure '
        '$nativeRuntimesUserDefineKey with llama_cpp, litert_lm, or both.',
      );
    }
    final includeLlamaCpp = selectedRuntimes.contains(nativeRuntimeLlamaCpp);
    final includeLiteRtLm = selectedRuntimes.contains(nativeRuntimeLiteRtLm);
    log.info('Selected native runtimes: ${selectedRuntimes.join(', ')}.');

    if (includeLiteRtLm &&
        _liteRtLmBundleSpecForCode(code) == null &&
        input.userDefines[nativeRuntimesUserDefineKey] != null) {
      throw Exception('LiteRT-LM runtime is not available for ${spec.bundle}.');
    }

    final reportDirPath = path.join(
      input.outputDirectory.toFilePath(),
      _reportDir,
    );
    final reportDir = Directory(reportDirPath);
    if (reportDir.existsSync()) {
      await reportDir.delete(recursive: true);
    }
    await reportDir.create(recursive: true);

    final copiedFileNames = <String>{};
    final usedAssetNames = <String>{};

    final emittedLibraries = <NativeLibraryDescriptor>[];

    if (includeLlamaCpp) {
      final bundleDir = await _acquireBundleDirectory(
        packageRoot: pkgRoot,
        nativeConfig: nativeConfig,
        bundle: spec.bundle,
        log: log,
      );

      final libraryPaths = _collectDynamicLibraryPaths(bundleDir);
      if (libraryPaths.isEmpty) {
        throw Exception('No dynamic libraries found in ${bundleDir.path}.');
      }

      final libraries = describeNativeLibraries(libraryPaths);
      if (!libraries.any((library) => library.isPrimary)) {
        throw Exception(
          'No primary libllamadart library found in ${bundleDir.path}.',
        );
      }

      final selectedLibraries = selectLibrariesForBundling(
        spec: spec,
        libraries: libraries,
        rawUserConfig: input.userDefines[nativeBackendUserDefineKey],
        warn: log.warning,
      );

      for (final library in selectedLibraries) {
        final emittedFileNames = _emittedFileNamesForLibrary(
          spec: spec,
          library: library,
        );

        for (final emittedFileName in emittedFileNames) {
          final loweredFileName = emittedFileName.toLowerCase();
          if (copiedFileNames.contains(loweredFileName)) {
            if (emittedFileName == library.fileName) {
              log.warning(
                'Duplicate library filename detected, skipping: '
                '${library.fileName}',
              );
            }
            continue;
          }

          copiedFileNames.add(loweredFileName);

          final destinationPath = path.join(reportDirPath, emittedFileName);
          await File(library.filePath).copy(destinationPath);
          emittedLibraries.add(describeNativeLibrary(destinationPath));
        }
      }
    }

    for (final emittedLibrary in emittedLibraries) {
      final baseAssetName = codeAssetNameForLibrary(
        spec: spec,
        library: emittedLibrary,
      );
      final assetName = _dedupeAssetName(baseAssetName, usedAssetNames);

      output.assets.code.add(
        CodeAsset(
          package: _packageName,
          name: assetName,
          linkMode: DynamicLoadingBundled(),
          file: Uri.file(path.absolute(emittedLibrary.filePath)),
        ),
      );

      log.info(
        'Reporting native library `${emittedLibrary.fileName}` as code asset '
        '`package:$_packageName/$assetName`.',
      );
    }

    if (includeLiteRtLm) {
      await _emitLiteRtLmAssets(
        code: code,
        output: output,
        packageRoot: pkgRoot,
        reportDirPath: reportDirPath,
        usedAssetNames: usedAssetNames,
        log: log,
      );
    }

    if (includeLlamaCpp && !usedAssetNames.contains(_packageName)) {
      throw Exception(
        'Primary asset package:$_packageName/$_packageName was not emitted.',
      );
    }
  });
}

Future<void> _emitLiteRtLmAssets({
  required CodeConfig code,
  required BuildOutputBuilder output,
  required String packageRoot,
  required String reportDirPath,
  required Set<String> usedAssetNames,
  required Logger log,
}) async {
  final bundleSpec = _liteRtLmBundleSpecForCode(code);
  if (bundleSpec == null) {
    return;
  }

  final bundleDir = await _acquireLiteRtLmBundle(
    packageRoot: packageRoot,
    bundleSpec: bundleSpec,
    log: log,
  );
  final libraryPaths = _collectDynamicLibraryPaths(bundleDir);
  if (libraryPaths.isEmpty) {
    log.warning('LiteRT-LM bundle had no dynamic libraries.');
    return;
  }

  final emittedFileNames = <String>{};
  for (final sourcePath in libraryPaths) {
    final fileName = path.basename(sourcePath);
    final loweredFileName = fileName.toLowerCase();
    if (!emittedFileNames.add(loweredFileName)) {
      log.info('Skipping duplicate LiteRT-LM library `$fileName`.');
      continue;
    }
    final destinationPath = path.join(reportDirPath, fileName);
    await File(sourcePath).copy(destinationPath);
    if (!_shouldEmitLiteRtLmCodeAsset(code, bundleSpec, fileName)) {
      log.info(
        'Copied LiteRT-LM companion `$fileName` without reporting it '
        'as a native asset.',
      );
      continue;
    }
    final assetName = _dedupeAssetName(
      _liteRtLmAssetName(fileName),
      usedAssetNames,
    );
    output.assets.code.add(
      CodeAsset(
        package: _packageName,
        name: assetName,
        linkMode: DynamicLoadingBundled(),
        file: Uri.file(path.absolute(destinationPath)),
      ),
    );
    log.info(
      'Reporting LiteRT-LM library `$fileName` as code asset '
      '`package:$_packageName/$assetName`.',
    );
  }
}

bool _shouldEmitLiteRtLmCodeAsset(
  CodeConfig code,
  _LiteRtLmBundleSpec bundleSpec,
  String fileName,
) {
  if (code.targetOS == OS.macOS) {
    // Upstream LiteRT-LM dylibs are not reliable Dart Native Assets on macOS:
    // the JIT bundler rewrites install names, and some upstream dylibs do not
    // tolerate that rewrite. Keep them in the hook cache and let the
    // LiteRT-LM loader open them from there.
    return false;
  }
  if (bundleSpec.emitAllLibraries) {
    return true;
  }
  return true;
}

_LiteRtLmBundleSpec? _liteRtLmBundleSpecForCode(CodeConfig code) {
  switch (code.targetOS) {
    case OS.android:
      return switch (code.targetArchitecture) {
        Architecture.arm64 => _litertLmBundles['android-arm64'],
        Architecture.x64 => _litertLmBundles['android-x64'],
        _ => null,
      };
    case OS.iOS:
      final isSimulator = code.iOS.targetSdk == IOSSdk.iPhoneSimulator;
      return switch (code.targetArchitecture) {
        Architecture.arm64 =>
          _litertLmBundles[isSimulator ? 'ios-arm64-sim' : 'ios-arm64'],
        Architecture.x64 => _litertLmBundles['ios-x64-sim'],
        _ => null,
      };
    case OS.macOS:
      return switch (code.targetArchitecture) {
        Architecture.arm64 => _litertLmBundles['macos-arm64'],
        Architecture.x64 => _litertLmBundles['macos-x64'],
        _ => null,
      };
    case OS.linux:
      return switch (code.targetArchitecture) {
        Architecture.arm64 => _litertLmBundles['linux-arm64'],
        Architecture.x64 => _litertLmBundles['linux-x64'],
        _ => null,
      };
    case OS.windows:
      return switch (code.targetArchitecture) {
        Architecture.x64 => _litertLmBundles['windows-x64'],
        _ => null,
      };
    default:
      return null;
  }
}

String _liteRtLmAssetName(String fileName) {
  var name = path.basenameWithoutExtension(fileName);
  if (name.startsWith('lib')) {
    name = name.substring(3);
  }
  return 'litert_lm_$name';
}

Future<Directory> _acquireLiteRtLmBundle({
  required String packageRoot,
  required _LiteRtLmBundleSpec bundleSpec,
  required Logger log,
}) async {
  final cacheDir = path.join(
    packageRoot,
    _dartToolDir,
    _cacheBaseDir,
    _litertLmCacheDir,
    _litertLmVersion,
  );
  final extractedDir = Directory(path.join(cacheDir, bundleSpec.directoryName));
  if (_liteRtLmBundleIsUsable(extractedDir, bundleSpec)) {
    log.info('Using cached LiteRT-LM bundle: ${extractedDir.path}');
    return extractedDir;
  }

  await Directory(cacheDir).create(recursive: true);
  final archiveFile = File(path.join(cacheDir, bundleSpec.archiveName));
  final expectedSha256 = bundleSpec.sha256;
  if (archiveFile.existsSync() && expectedSha256 != null) {
    final digest = await _sha256File(archiveFile);
    if (digest != expectedSha256) {
      log.warning(
        'Cached LiteRT-LM archive checksum mismatch; redownloading '
        '${bundleSpec.archiveName}.',
      );
      await archiveFile.delete();
    }
  }
  if (!archiveFile.existsSync()) {
    await _downloadLiteRtLmArchive(
      bundleSpec: bundleSpec,
      destination: archiveFile,
      log: log,
    );
  }
  if (expectedSha256 != null) {
    final digest = await _sha256File(archiveFile);
    if (digest != expectedSha256) {
      throw Exception(
        'LiteRT-LM archive checksum mismatch: expected '
        '$expectedSha256, got $digest',
      );
    }
  }

  if (extractedDir.existsSync()) {
    await extractedDir.delete(recursive: true);
  }
  await extractedDir.create(recursive: true);
  try {
    final bytes = await archiveFile.readAsBytes();
    final archive = TarDecoder().decodeBytes(GZipDecoder().decodeBytes(bytes));
    for (final entry in archive.files) {
      if (!entry.isFile) {
        continue;
      }
      if (!_isLiteRtLmEntrySelected(entry.name, bundleSpec)) {
        continue;
      }
      final fileName = path.basename(entry.name);
      if (!_dynamicLibraryExtensions.contains(
        path.extension(fileName).toLowerCase(),
      )) {
        continue;
      }
      await File(
        path.join(extractedDir.path, fileName),
      ).writeAsBytes(entry.content as List<int>);
    }
  } on FormatException catch (error) {
    log.warning(
      'Archive package could not decode LiteRT-LM PAX metadata; falling back '
      'to system tar: $error',
    );
    final result = await Process.run('tar', [
      '-xzf',
      archiveFile.path,
      '-C',
      extractedDir.path,
    ]);
    if (result.exitCode != 0) {
      throw Exception(
        'System tar failed for LiteRT-LM bundle: ${result.stderr}',
      );
    }
    await _flattenLiteRtLmDynamicLibraries(extractedDir, bundleSpec);
  }
  final missingLibraries = _missingLiteRtLmLibraries(extractedDir, bundleSpec);
  if (missingLibraries.isNotEmpty) {
    throw Exception(
      'LiteRT-LM bundle ${bundleSpec.archiveName} is missing required '
      'libraries: ${missingLibraries.join(', ')}',
    );
  }
  await _writeLiteRtLmChecksumMarker(extractedDir, expectedSha256);
  log.info('Extracted LiteRT-LM bundle to ${extractedDir.path}');
  return extractedDir;
}

Future<void> _downloadLiteRtLmArchive({
  required _LiteRtLmBundleSpec bundleSpec,
  required File destination,
  required Logger log,
}) async {
  final url = '${bundleSpec.releaseBaseUrl}/${bundleSpec.archiveName}';
  log.info('Downloading LiteRT-LM bundle from $url');
  final response = await http.get(Uri.parse(url));
  if (response.statusCode != 200) {
    throw Exception(
      'Failed to download LiteRT-LM bundle: HTTP ${response.statusCode}',
    );
  }
  await destination.writeAsBytes(response.bodyBytes);
}

Future<String> _sha256File(File file) async {
  return sha256.convert(await file.readAsBytes()).toString();
}

bool _isLiteRtLmEntrySelected(
  String entryName,
  _LiteRtLmBundleSpec bundleSpec,
) {
  final sourcePrefix = bundleSpec.sourcePrefix;
  if (sourcePrefix == null) {
    return true;
  }
  final normalized = path.posix.normalize(entryName);
  return normalized == sourcePrefix || normalized.startsWith('$sourcePrefix/');
}

Future<void> _flattenLiteRtLmDynamicLibraries(
  Directory extractedDir,
  _LiteRtLmBundleSpec bundleSpec,
) async {
  final sourcePrefix = bundleSpec.sourcePrefix;
  if (sourcePrefix == null) {
    return;
  }
  final nestedDir = Directory(
    path.joinAll([extractedDir.path, ...sourcePrefix.split('/')]),
  );
  if (!nestedDir.existsSync()) {
    return;
  }
  await for (final entity in nestedDir.list(recursive: true)) {
    if (entity is! File) {
      continue;
    }
    final fileName = path.basename(entity.path);
    if (!_dynamicLibraryExtensions.contains(
      path.extension(fileName).toLowerCase(),
    )) {
      continue;
    }
    await entity.copy(path.join(extractedDir.path, fileName));
  }
  await nestedDir.delete(recursive: true);
}

bool _liteRtLmBundleIsUsable(
  Directory directory,
  _LiteRtLmBundleSpec bundleSpec,
) {
  if (_missingLiteRtLmLibraries(directory, bundleSpec).isNotEmpty) {
    return false;
  }
  final expectedSha256 = bundleSpec.sha256;
  if (expectedSha256 == null) {
    return true;
  }
  final checksumFile = File(
    path.join(directory.path, _litertLmChecksumFileName),
  );
  return checksumFile.existsSync() &&
      checksumFile.readAsStringSync().trim() == expectedSha256;
}

Future<void> _writeLiteRtLmChecksumMarker(
  Directory directory,
  String? sha256,
) async {
  if (sha256 == null) {
    return;
  }
  await File(
    path.join(directory.path, _litertLmChecksumFileName),
  ).writeAsString('$sha256\n');
}

List<String> _missingLiteRtLmLibraries(
  Directory directory,
  _LiteRtLmBundleSpec bundleSpec,
) {
  if (!directory.existsSync()) {
    return bundleSpec.requiredLibraries.toList(growable: false);
  }
  return bundleSpec.requiredLibraries
      .where((libraryName) {
        return !File(path.join(directory.path, libraryName)).existsSync();
      })
      .toList(growable: false);
}

String _dedupeAssetName(String base, Set<String> used) {
  if (!used.contains(base)) {
    used.add(base);
    return base;
  }

  var index = 2;
  while (used.contains('${base}_$index')) {
    index++;
  }

  final deduped = '${base}_$index';
  used.add(deduped);
  return deduped;
}

_NativeBundleConfig _resolveNativeBundleConfig(
  HookInputUserDefines userDefines,
) {
  return _NativeBundleConfig(
    tag: _resolveNativeTag(userDefines[nativeTagUserDefineKey]),
    repository: _resolveNativeRepository(
      userDefines[nativeRepositoryUserDefineKey],
    ),
    localPath: _resolveNativePath(userDefines),
  );
}

String _resolveNativeTag(Object? rawUserConfig) {
  if (rawUserConfig == null) {
    return _llamaCppTag;
  }

  if (rawUserConfig is! String) {
    throw FormatException(
      'hooks.user_defines.$_packageName.$nativeTagUserDefineKey must be a '
      'string release tag such as $_llamaCppTag.',
    );
  }

  final tag = rawUserConfig.trim();
  if (tag.isEmpty) {
    throw FormatException(
      'hooks.user_defines.$_packageName.$nativeTagUserDefineKey must not be '
      'empty.',
    );
  }
  if (!_nativeTagPattern.hasMatch(tag)) {
    throw FormatException(
      'hooks.user_defines.$_packageName.$nativeTagUserDefineKey must be a '
      'path-safe release tag such as $_llamaCppTag.',
    );
  }

  return tag;
}

String _resolveNativeRepository(Object? rawUserConfig) {
  if (rawUserConfig == null) {
    return _nativeRepoSlug;
  }

  if (rawUserConfig is! String) {
    throw FormatException(
      'hooks.user_defines.$_packageName.$nativeRepositoryUserDefineKey must be '
      'a GitHub repository slug such as $_nativeRepoSlug.',
    );
  }

  final repository = _normalizeNativeRepository(rawUserConfig);
  final segments = repository.split('/');
  if (segments.length != 2 ||
      segments.any((segment) => !_isValidGithubRepoSegment(segment))) {
    throw FormatException(
      'hooks.user_defines.$_packageName.$nativeRepositoryUserDefineKey must be '
      'a GitHub repository slug such as $_nativeRepoSlug.',
    );
  }

  return repository;
}

bool _isValidGithubRepoSegment(String segment) {
  return _githubRepoSegmentPattern.hasMatch(segment) &&
      segment != '.' &&
      segment != '..';
}

String _normalizeNativeRepository(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    return trimmed;
  }

  final uri = Uri.tryParse(trimmed);
  if (uri != null &&
      (uri.scheme == 'https' || uri.scheme == 'http') &&
      uri.host == 'github.com' &&
      uri.pathSegments.length >= 2) {
    final owner = uri.pathSegments[0];
    final repo = uri.pathSegments[1].replaceFirst(RegExp(r'\.git$'), '');
    return '$owner/$repo';
  }

  final gitPrefix = 'git@github.com:';
  if (trimmed.startsWith(gitPrefix)) {
    return trimmed
        .substring(gitPrefix.length)
        .replaceFirst(RegExp(r'\.git$'), '');
  }

  return trimmed.replaceFirst(RegExp(r'\.git$'), '');
}

Uri? _resolveNativePath(HookInputUserDefines userDefines) {
  final rawUserConfig = userDefines[nativePathUserDefineKey];
  if (rawUserConfig == null) {
    return null;
  }

  if (rawUserConfig is! String) {
    throw FormatException(
      'hooks.user_defines.$_packageName.$nativePathUserDefineKey must be a '
      'path string.',
    );
  }
  if (rawUserConfig.trim().isEmpty) {
    throw FormatException(
      'hooks.user_defines.$_packageName.$nativePathUserDefineKey must not be '
      'empty.',
    );
  }

  final resolvedPath = userDefines.path(nativePathUserDefineKey);
  if (resolvedPath == null || !resolvedPath.isScheme('file')) {
    throw FormatException(
      'hooks.user_defines.$_packageName.$nativePathUserDefineKey must resolve '
      'to a local file path.',
    );
  }

  return resolvedPath;
}

Future<Directory> _acquireBundleDirectory({
  required String packageRoot,
  required _NativeBundleConfig nativeConfig,
  required String bundle,
  required Logger log,
}) async {
  final allowLegacyLocalBundles = _isLegacyLocalBundleEnabled();
  final archiveName = 'llamadart-native-$bundle-${nativeConfig.tag}.tar.gz';
  final cacheDir = _bundleCacheDirectory(
    packageRoot: packageRoot,
    nativeConfig: nativeConfig,
    bundle: bundle,
  );
  final extractedDir = Directory(path.join(cacheDir, 'extracted'));
  final archivePath = path.join(cacheDir, archiveName);
  final archiveFile = File(archivePath);

  final localPath = nativeConfig.localPath;
  if (localPath != null) {
    return _acquireLocalBundleDirectory(
      localPath: localPath,
      nativeTag: nativeConfig.tag,
      bundle: bundle,
      archiveName: archiveName,
      cacheDir: cacheDir,
      extractedDir: extractedDir,
      log: log,
    );
  }

  final cachedLibraryPaths = _collectDynamicLibraryPaths(extractedDir);
  if (cachedLibraryPaths.isNotEmpty &&
      _isBundleLayoutCompatible(
        bundle: bundle,
        libraryPaths: cachedLibraryPaths,
        log: log,
      )) {
    log.info('Using cached native bundle: ${extractedDir.path}');
    return extractedDir;
  }

  if (cachedLibraryPaths.isNotEmpty) {
    log.warning('Cached native bundle appears stale; refreshing: $bundle');
    if (extractedDir.existsSync()) {
      await extractedDir.delete(recursive: true);
    }
  }

  if (allowLegacyLocalBundles) {
    final localCandidates = _localBundleCandidates(
      packageRoot: packageRoot,
      bundle: bundle,
    );
    for (final candidatePath in localCandidates) {
      final candidate = Directory(candidatePath);
      final candidatePaths = _collectDynamicLibraryPaths(candidate);
      if (candidatePaths.isNotEmpty &&
          _isBundleLayoutCompatible(
            bundle: bundle,
            libraryPaths: candidatePaths,
            log: log,
          )) {
        log.info(
          'Using legacy local native bundle directory: ${candidate.path}',
        );
        return candidate;
      }
    }
  }

  await Directory(cacheDir).create(recursive: true);

  var extractedLibraryPaths = const <String>[];
  if (archiveFile.existsSync()) {
    extractedLibraryPaths = await _extractCachedArchive(
      archivePath: archivePath,
      extractedDir: extractedDir,
      cacheDir: cacheDir,
      log: log,
    );
    if (_isBundleLayoutCompatible(
      bundle: bundle,
      libraryPaths: extractedLibraryPaths,
      log: log,
    )) {
      log.info('Using cached native bundle archive: $archivePath');
      return extractedDir;
    }

    log.warning(
      'Cached native bundle archive is stale; redownloading: $archivePath',
    );
    await archiveFile.delete();
    if (extractedDir.existsSync()) {
      await extractedDir.delete(recursive: true);
    }
  }

  if (!archiveFile.existsSync()) {
    await _downloadReleaseAsset(
      repository: nativeConfig.repository,
      nativeTag: nativeConfig.tag,
      assetName: archiveName,
      destinationPath: archivePath,
      log: log,
    );
  }
  extractedLibraryPaths = await _extractCachedArchive(
    archivePath: archivePath,
    extractedDir: extractedDir,
    cacheDir: cacheDir,
    log: log,
  );
  if (!_isBundleLayoutCompatible(
    bundle: bundle,
    libraryPaths: extractedLibraryPaths,
    log: log,
  )) {
    throw Exception('Downloaded bundle $archiveName is missing runtime deps.');
  }
  return extractedDir;
}

String _bundleCacheDirectory({
  required String packageRoot,
  required _NativeBundleConfig nativeConfig,
  required String bundle,
}) {
  final localPath = nativeConfig.localPath;
  if (localPath != null) {
    final digest = sha1.convert(utf8.encode(localPath.toString())).toString();
    return path.join(
      packageRoot,
      _dartToolDir,
      _cacheBaseDir,
      _bundleCacheDir,
      'local',
      digest,
      nativeConfig.tag,
      bundle,
    );
  }

  if (nativeConfig.repository == _nativeRepoSlug) {
    return path.join(
      packageRoot,
      _dartToolDir,
      _cacheBaseDir,
      _bundleCacheDir,
      nativeConfig.tag,
      bundle,
    );
  }

  final segments = nativeConfig.repository.split('/');
  return path.join(
    packageRoot,
    _dartToolDir,
    _cacheBaseDir,
    _bundleCacheDir,
    'github',
    segments[0],
    segments[1],
    nativeConfig.tag,
    bundle,
  );
}

Future<Directory> _acquireLocalBundleDirectory({
  required Uri localPath,
  required String nativeTag,
  required String bundle,
  required String archiveName,
  required String cacheDir,
  required Directory extractedDir,
  required Logger log,
}) async {
  final localFilePath = localPath.toFilePath();

  final directArchive = File(localFilePath);
  if (directArchive.existsSync()) {
    return _extractLocalBundleArchive(
      archivePath: directArchive.path,
      bundle: bundle,
      cacheDir: cacheDir,
      extractedDir: extractedDir,
      log: log,
    );
  }

  for (final candidatePath in _localPathDirectoryCandidates(
    localPath: localFilePath,
    nativeTag: nativeTag,
    bundle: bundle,
  )) {
    final candidate = Directory(candidatePath);
    final candidatePaths = _collectDynamicLibraryPaths(candidate);
    if (candidatePaths.isNotEmpty &&
        _isBundleLayoutCompatible(
          bundle: bundle,
          libraryPaths: candidatePaths,
          log: log,
        )) {
      log.info('Using local native bundle directory: ${candidate.path}');
      return candidate;
    }
  }

  for (final candidatePath in _localPathArchiveCandidates(
    localPath: localFilePath,
    nativeTag: nativeTag,
    bundle: bundle,
    archiveName: archiveName,
  )) {
    final candidate = File(candidatePath);
    if (!candidate.existsSync()) {
      continue;
    }
    return _extractLocalBundleArchive(
      archivePath: candidate.path,
      bundle: bundle,
      cacheDir: cacheDir,
      extractedDir: extractedDir,
      log: log,
    );
  }

  throw Exception(
    'No compatible native bundle found at $localFilePath for $bundle. '
    'Expected a directory containing dynamic libraries, a directory containing '
    '$archiveName, or a direct path to a bundle archive.',
  );
}

List<String> _localPathDirectoryCandidates({
  required String localPath,
  required String nativeTag,
  required String bundle,
}) {
  return _dedupePaths([
    path.join(localPath, nativeTag, bundle, 'extracted'),
    path.join(localPath, nativeTag, bundle),
    path.join(localPath, bundle, 'extracted'),
    path.join(localPath, bundle),
    path.join(localPath, 'extracted'),
    localPath,
  ]);
}

List<String> _localPathArchiveCandidates({
  required String localPath,
  required String nativeTag,
  required String bundle,
  required String archiveName,
}) {
  return _dedupePaths([
    path.join(localPath, archiveName),
    path.join(localPath, nativeTag, bundle, archiveName),
    path.join(localPath, bundle, archiveName),
  ]);
}

List<String> _dedupePaths(List<String> paths) {
  final normalizedPaths = <String>[];
  final seen = <String>{};
  for (final entry in paths) {
    final normalized = path.normalize(entry);
    if (seen.add(normalized)) {
      normalizedPaths.add(normalized);
    }
  }
  return normalizedPaths;
}

Future<Directory> _extractLocalBundleArchive({
  required String archivePath,
  required String bundle,
  required String cacheDir,
  required Directory extractedDir,
  required Logger log,
}) async {
  final extractedLibraryPaths = await _extractCachedArchive(
    archivePath: archivePath,
    extractedDir: extractedDir,
    cacheDir: cacheDir,
    log: log,
  );
  if (!_isBundleLayoutCompatible(
    bundle: bundle,
    libraryPaths: extractedLibraryPaths,
    log: log,
  )) {
    throw Exception(
      'Local bundle archive $archivePath is missing runtime deps.',
    );
  }
  log.info('Using local native bundle archive: $archivePath');
  return extractedDir;
}

bool _isLegacyLocalBundleEnabled() {
  final raw = Platform.environment[_allowLegacyLocalBundleEnv];
  if (raw == null) {
    return false;
  }

  final normalized = raw.trim().toLowerCase();
  return normalized == '1' || normalized == 'true' || normalized == 'yes';
}

List<String> _localBundleCandidates({
  required String packageRoot,
  required String bundle,
}) {
  final candidates = <String>[
    path.join(packageRoot, _thirdPartyDir, _binDir, bundle),
  ];

  switch (bundle) {
    case 'android-arm64':
      candidates.add(
        path.join(packageRoot, _thirdPartyDir, _binDir, 'android', 'arm64'),
      );
      break;
    case 'android-x64':
      candidates.add(
        path.join(packageRoot, _thirdPartyDir, _binDir, 'android', 'x64'),
      );
      break;
    case 'ios-arm64':
    case 'ios-arm64-sim':
    case 'ios-x86_64-sim':
      candidates.add(path.join(packageRoot, _thirdPartyDir, _binDir, 'ios'));
      break;
    case 'linux-arm64':
      candidates.add(
        path.join(packageRoot, _thirdPartyDir, _binDir, 'linux', 'arm64'),
      );
      break;
    case 'linux-x64':
      candidates.add(
        path.join(packageRoot, _thirdPartyDir, _binDir, 'linux', 'x64'),
      );
      break;
    case 'macos-arm64':
      candidates.add(
        path.join(packageRoot, _thirdPartyDir, _binDir, 'macos', 'arm64'),
      );
      break;
    case 'macos-x86_64':
      candidates.add(
        path.join(packageRoot, _thirdPartyDir, _binDir, 'macos', 'x86_64'),
      );
      candidates.add(
        path.join(packageRoot, _thirdPartyDir, _binDir, 'macos', 'x64'),
      );
      break;
    case 'windows-arm64':
      candidates.add(
        path.join(packageRoot, _thirdPartyDir, _binDir, 'windows', 'arm64'),
      );
      break;
    case 'windows-x64':
      candidates.add(
        path.join(packageRoot, _thirdPartyDir, _binDir, 'windows', 'x64'),
      );
      break;
  }

  return candidates;
}

List<String> _collectDynamicLibraryPaths(Directory directory) {
  if (!directory.existsSync()) {
    return const [];
  }

  final paths = <String>[];
  for (final entity in directory.listSync(recursive: true)) {
    if (entity is! File) {
      continue;
    }
    final fileName = path.basename(entity.path).toLowerCase();
    final extension = path.extension(entity.path).toLowerCase();
    if (_dynamicLibraryExtensions.contains(extension) ||
        _linuxVersionedSoPattern.hasMatch(fileName)) {
      paths.add(entity.path);
    }
  }

  paths.sort();
  return paths;
}

List<String> _emittedFileNamesForLibrary({
  required NativeBundleSpec spec,
  required NativeLibraryDescriptor library,
}) {
  final fileNames = <String>[library.fileName];

  // Linux shared objects in native bundles can encode SONAME dependencies such
  // as `libllama.so.0`. Emit `.so.0` aliases so runtime dynamic loading
  // resolves those dependencies in `.dart_tool/lib`.
  if (spec.bundle.startsWith('linux-')) {
    final lowered = library.fileName.toLowerCase();
    if (lowered.endsWith('.so') && !lowered.endsWith('.so.0')) {
      fileNames.add('${library.fileName}.0');
    }
  }

  return fileNames;
}

bool _isBundleLayoutCompatible({
  required String bundle,
  required List<String> libraryPaths,
  required Logger log,
}) {
  if (libraryPaths.isEmpty) {
    return false;
  }

  if (bundle != 'windows-x64') {
    return true;
  }

  final fileNames = libraryPaths
      .map((entry) => path.basename(entry).toLowerCase())
      .toSet();

  if (_hasWindowsBackendModule(fileNames, 'cuda')) {
    final hasCudart = fileNames.any(_windowsCudartPattern.hasMatch);
    final hasCublas = fileNames.any(_windowsCublasPattern.hasMatch);
    if (!hasCudart || !hasCublas) {
      log.warning(
        'Windows CUDA backend module detected without required runtime '
        'dependencies (cudart/cublas).',
      );
      return false;
    }
  }

  if (_hasWindowsBackendModule(fileNames, 'blas')) {
    final hasOpenBlas = fileNames.any((name) => name.contains('openblas'));
    if (!hasOpenBlas) {
      log.warning(
        'Windows BLAS backend module detected without openblas runtime.',
      );
      return false;
    }
  }

  return true;
}

bool _hasWindowsBackendModule(Set<String> fileNames, String backend) {
  for (final fileName in fileNames) {
    if (!fileName.endsWith('.dll')) {
      continue;
    }
    if (!fileName.startsWith('ggml-$backend')) {
      continue;
    }
    return true;
  }
  return false;
}

Future<List<String>> _extractCachedArchive({
  required String archivePath,
  required Directory extractedDir,
  required String cacheDir,
  required Logger log,
}) async {
  final tmpExtractDir = Directory(path.join(cacheDir, 'extracting'));
  if (tmpExtractDir.existsSync()) {
    await tmpExtractDir.delete(recursive: true);
  }
  await tmpExtractDir.create(recursive: true);

  await _extractArchive(
    archivePath: archivePath,
    outputDirectory: tmpExtractDir.path,
    log: log,
  );

  final extractedLibraryPaths = _collectDynamicLibraryPaths(tmpExtractDir);
  if (extractedLibraryPaths.isEmpty) {
    throw Exception(
      'Downloaded bundle archive contains no dynamic libs: $archivePath',
    );
  }

  if (extractedDir.existsSync()) {
    await extractedDir.delete(recursive: true);
  }
  await tmpExtractDir.rename(extractedDir.path);

  log.info('Extracted native bundle to ${extractedDir.path}');
  return extractedLibraryPaths;
}

Future<void> _downloadReleaseAsset({
  required String repository,
  required String nativeTag,
  required String assetName,
  required String destinationPath,
  required Logger log,
}) async {
  final url =
      'https://github.com/$repository/releases/download/$nativeTag/$assetName';
  log.info('Downloading native bundle: $url');

  final destination = File(destinationPath);
  await destination.parent.create(recursive: true);

  final client = http.Client();
  try {
    final request = http.Request('GET', Uri.parse(url));
    final response = await client.send(request);

    if (response.statusCode != 200) {
      throw Exception('Failed to download $url (${response.statusCode}).');
    }

    final sink = destination.openWrite();
    await response.stream.pipe(sink);
    await sink.flush();
    await sink.close();
  } finally {
    client.close();
  }

  log.info('Saved native bundle to $destinationPath');
}

Future<void> _extractArchive({
  required String archivePath,
  required String outputDirectory,
  required Logger log,
}) async {
  final outputRoot = path.normalize(path.absolute(outputDirectory));
  final archiveBytes = await File(archivePath).readAsBytes();

  Archive archive;
  try {
    archive = TarDecoder().decodeBytes(GZipDecoder().decodeBytes(archiveBytes));
  } catch (error) {
    log.severe('Failed to decode archive $archivePath: $error');
    throw Exception('Failed to decode native bundle archive: $archivePath');
  }

  for (final file in archive.files) {
    final relativePath = path.normalize(file.name);
    final targetPath = path.normalize(path.join(outputRoot, relativePath));
    final isInRoot =
        targetPath == outputRoot || path.isWithin(outputRoot, targetPath);

    if (!isInRoot) {
      throw Exception(
        'Archive traversal entry blocked for $archivePath: ${file.name}',
      );
    }

    if (file.isDirectory) {
      await Directory(targetPath).create(recursive: true);
      continue;
    }

    final bytes = file.content as List<int>;
    await Directory(path.dirname(targetPath)).create(recursive: true);
    await File(targetPath).writeAsBytes(bytes);
  }
}
