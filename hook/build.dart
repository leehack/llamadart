import 'dart:async'
    show Completer, StreamSubscription, Timer, TimeoutException, unawaited;
import 'dart:convert' show utf8;
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:hooks/hooks.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;

import 'package:llamadart/src/hook/native_bundle_config.dart';

const _llamaCppTag = 'v0.3.0';
const _nativeRepoSlug = 'leehack/llamadart-native';

const _packageName = 'llamadart';
const _llamaCppFlutterPackageName = 'llamadart_llama_cpp_flutter';
const _liteRtLmFlutterPackageName = 'llamadart_litert_lm_flutter';
const _thirdPartyDir = 'third_party';
const _binDir = 'bin';
const _dartToolDir = '.dart_tool';
const _cacheBaseDir = 'llamadart';
const _bundleCacheDir = 'native_bundles';
const _reportDir = 'llamadart_bin';
const _allowLegacyLocalBundleEnv = 'LLAMADART_ALLOW_LEGACY_LOCAL_BUNDLES';
const _litertLmReleaseTag = 'v0.16.0-native.2';
const _litertLmVersion = '0.16.0-native.2';
const _litertLmNativeReleaseBaseUrl =
    'https://github.com/leehack/litert-lm-native/releases/download/'
    '$_litertLmReleaseTag';
const _litertLmCacheDir = 'litert_lm';
const _runtimeBundleDownloadMaxAttempts = 5;
const _runtimeBundleDownloadRequestTimeout = Duration(seconds: 60);
const _runtimeBundleDownloadTransferTimeout = Duration(minutes: 10);
const _runtimeBundleDownloadRetryBaseDelay = Duration(seconds: 3);

typedef RuntimeBundleDownloadFallbackForTesting =
    Future<bool> Function({
      required String url,
      required File destination,
      required String description,
      required Logger log,
    });

final _litertLmBundles = Map.unmodifiable({
  for (final bundle in _litertLmBundleSpecs) bundle.bundle: bundle,
});

const _litertLmBundleSpecs = <_LiteRtLmBundleSpec>[
  _LiteRtLmBundleSpec(
    'android-arm64',
    sha256: '1803d6c4ffebd78cb50c261e78fed411158d644e373255589eba762534e19008',
    requiredLibraries: {
      'libGemmaModelConstraintProvider.so',
      'libLiteRtGpuAccelerator.so',
      'libLiteRtLm.so',
      'libLiteRtOpenClAccelerator.so',
      'libLiteRtTopKOpenClSampler.so',
      'libLiteRtTopKWebGpuSampler.so',
      'libLiteRtWebGpuAccelerator.so',
      'libwebgpu_dawn.so',
    },
  ),
  _LiteRtLmBundleSpec(
    'android-x64',
    sha256: 'dd9477c53d0b4d76c79cb104bc8ba6fe18d2ebdd5350db0fba4f25427fe6bccf',
    requiredLibraries: {
      'libGemmaModelConstraintProvider.so',
      'libLiteRtGpuAccelerator.so',
      'libLiteRtLm.so',
      'libLiteRtOpenClAccelerator.so',
      'libLiteRtTopKOpenClSampler.so',
      'libLiteRtTopKWebGpuSampler.so',
      'libLiteRtWebGpuAccelerator.so',
      'libwebgpu_dawn.so',
    },
  ),
  _LiteRtLmBundleSpec(
    'ios-arm64',
    sha256: '550386b165d408dc900f4958f51627fcb59b55e2f485416bb9eecc78b12d0032',
    requiredLibraries: {
      'LiteRtLm',
      'CLiteRTLM',
      'GemmaModelConstraintProvider',
    },
  ),
  _LiteRtLmBundleSpec(
    'ios-arm64-sim',
    sha256: 'ec02c2246d04ce6e003b2c2dac1b68678a5b9e0eda387731516e0de12544e898',
    requiredLibraries: {
      'LiteRtLm',
      'CLiteRTLM',
      'GemmaModelConstraintProvider',
    },
  ),
  _LiteRtLmBundleSpec(
    'macos-arm64',
    sha256: 'd93c380b1fc63f568279e68ad596dcca3234b6885b2e953a10e2f6d4244d956c',
    requiredLibraries: {
      'libCLiteRTLM_mac.dylib',
      'libGemmaModelConstraintProvider.dylib',
      'libLiteRt.dylib',
      'libLiteRtLm.dylib',
      'libLiteRtMetalAccelerator.dylib',
      'libLiteRtTopKMetalSampler.dylib',
      'libLiteRtTopKWebGpuSampler.dylib',
      'libLiteRtWebGpuAccelerator.dylib',
      'libwebgpu_dawn.dylib',
    },
  ),
  _LiteRtLmBundleSpec(
    'macos-x64',
    sha256: '7991715cae696143cc20b2d5983abc31bdc6121ed6a7040dbb139a837bda9e0a',
    requiredLibraries: {'libCLiteRTLM_mac.dylib', 'libLiteRtLm.dylib'},
  ),
  _LiteRtLmBundleSpec(
    'linux-arm64',
    sha256: '7eda924bdf4a1a800e73f9029c1e4a2686cb36ee6a31e9190e46ec5d6345e0e2',
    requiredLibraries: {
      'libGemmaModelConstraintProvider.so',
      'libLiteRt.so',
      'libLiteRtLm.so',
      'libLiteRtTopKWebGpuSampler.so',
      'libLiteRtWebGpuAccelerator.so',
      'libwebgpu_dawn.so',
    },
  ),
  _LiteRtLmBundleSpec(
    'linux-x64',
    sha256: 'fd3a845f15b6ae3e158cea6668c2b61902ab5d7c89d8784d5d0f3a017e52096d',
    requiredLibraries: {
      'libGemmaModelConstraintProvider.so',
      'libLiteRt.so',
      'libLiteRtLm.so',
      'libLiteRtTopKWebGpuSampler.so',
      'libLiteRtWebGpuAccelerator.so',
      'libwebgpu_dawn.so',
    },
  ),
  _LiteRtLmBundleSpec(
    'windows-x64',
    sha256: 'd7e997b12f6c39e4bac0cb878d824e05f1b4bae21768a407b150c14cb998f13f',
    requiredLibraries: {
      'LiteRtLm.dll',
      'libGemmaModelConstraintProvider.dll',
      'libLiteRt.dll',
      'libLiteRtTopKWebGpuSampler.dll',
      'libLiteRtWebGpuAccelerator.dll',
      'libwebgpu_dawn.dll',
    },
  ),
];

const _dynamicLibraryExtensions = {'.so', '.dylib', '.dll'};
final _windowsCudartPattern = RegExp(r'^cudart64(?:[_-]?\d+)?\.dll$');
final _windowsCublasPattern = RegExp(r'^cublas64(?:[_-]?\d+)?\.dll$');
final _linuxVersionedSoPattern = RegExp(r'\.so\.\d+$');
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
  final String bundle;
  final String sha256;
  final Set<String> requiredLibraries;

  const _LiteRtLmBundleSpec(
    this.bundle, {
    required this.sha256,
    required this.requiredLibraries,
  });

  String get archiveName =>
      'litert-lm-native-runtime-$bundle-$_litertLmReleaseTag.tar.gz';

  String get directoryName {
    final separator = bundle.indexOf('-');
    if (separator < 0) {
      return bundle;
    }
    return '${bundle.substring(0, separator)}/${bundle.substring(separator + 1)}';
  }

  String get releaseUrl => '$_litertLmNativeReleaseBaseUrl/$archiveName';

  String get sourcePrefix => directoryName;
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

    final pkgRoot = input.packageRoot.toFilePath();
    final rawNativeRuntimeConfig =
        input.userDefines[nativeRuntimesUserDefineKey];
    final appleSpmRuntimes = _flutterAppleCompanionRuntimes(
      input: input,
      code: code,
      log: log,
    );
    var selectedRuntimes =
        appleSpmRuntimes ??
        selectNativeRuntimesForBundle(
          bundle: spec.bundle,
          rawUserConfig: rawNativeRuntimeConfig,
          warn: log.warning,
        );
    final liteRtLmBundleSpec = _liteRtLmBundleSpecForCode(code);
    if (selectedRuntimes.contains(nativeRuntimeLiteRtLm) &&
        liteRtLmBundleSpec == null) {
      final explicitLiteRtLmSelection =
          appleSpmRuntimes?.contains(nativeRuntimeLiteRtLm) == true ||
          nativeRuntimeExplicitlySelectedForBundle(
            bundle: spec.bundle,
            rawUserConfig: rawNativeRuntimeConfig,
            runtime: nativeRuntimeLiteRtLm,
          );
      if (explicitLiteRtLmSelection) {
        throw Exception(
          'LiteRT-LM runtime is not available for ${spec.bundle}.',
        );
      }
      selectedRuntimes = selectedRuntimes
          .where((runtime) => runtime != nativeRuntimeLiteRtLm)
          .toList(growable: false);
      log.warning(
        'LiteRT-LM runtime is not available for ${spec.bundle}; using '
        'available runtime families: ${selectedRuntimes.join(', ')}.',
      );
    }
    if (selectedRuntimes.isEmpty) {
      throw Exception(
        'No native runtimes selected for ${spec.bundle}. Configure '
        '$nativeRuntimesUserDefineKey with llama_cpp, litert_lm, or both.',
      );
    }
    log.info('Selected native runtimes: ${selectedRuntimes.join(', ')}.');

    final appleSpmHandledRuntimes = await _emitAppleSpmAssetsIfEnabled(
      code: code,
      output: output,
      includeLlamaCpp: selectedRuntimes.contains(nativeRuntimeLlamaCpp),
      includeLiteRtLm: selectedRuntimes.contains(nativeRuntimeLiteRtLm),
      appleSpmRuntimes: appleSpmRuntimes,
      rawNativeRuntimeConfig: rawNativeRuntimeConfig,
      hasNativeSourceOverride: _hasNativeSourceOverride(input.userDefines),
      hasNativeBackendOverride:
          input.userDefines[nativeBackendUserDefineKey] != null,
      log: log,
    );
    if (appleSpmHandledRuntimes != null) {
      selectedRuntimes = selectedRuntimes
          .where((runtime) => !appleSpmHandledRuntimes.contains(runtime))
          .toList(growable: false);
      if (selectedRuntimes.isEmpty) {
        return;
      }
    }
    final includeLlamaCpp = selectedRuntimes.contains(nativeRuntimeLlamaCpp);
    final includeLiteRtLm = selectedRuntimes.contains(nativeRuntimeLiteRtLm);

    final nativeConfig = _resolveNativeBundleConfig(input.userDefines);
    log.info('Using native runtime source: ${nativeConfig.sourceLabel}');
    if (nativeConfig.usesOverride) {
      log.warning(
        'Native runtime overrides do not regenerate Dart FFI bindings. '
        'The selected binaries must stay ABI- and symbol-compatible with '
        '$_nativeRepoSlug@$_llamaCppTag.',
      );
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
          nativeConfig: nativeConfig,
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

Future<List<String>?> _emitAppleSpmAssetsIfEnabled({
  required CodeConfig code,
  required BuildOutputBuilder output,
  required bool includeLlamaCpp,
  required bool includeLiteRtLm,
  required List<String>? appleSpmRuntimes,
  required Object? rawNativeRuntimeConfig,
  required bool hasNativeSourceOverride,
  required bool hasNativeBackendOverride,
  required Logger log,
}) async {
  if (appleSpmRuntimes == null) {
    return null;
  }

  log.info(
    'Detected Flutter Apple companion packages for native runtimes: '
    '${appleSpmRuntimes.join(', ')}.',
  );
  if (rawNativeRuntimeConfig != null) {
    log.warning(
      'Flutter Apple builds select native runtimes from companion package '
      'dependencies ($_llamaCppFlutterPackageName and '
      '$_liteRtLmFlutterPackageName). Ignoring $nativeRuntimesUserDefineKey '
      'for this Apple build.',
    );
  }
  if (hasNativeSourceOverride) {
    log.warning(
      'Flutter Apple companion packages use Package.swift binary target pins. '
      '$nativeTagUserDefineKey, $nativeRepositoryUserDefineKey, and '
      '$nativePathUserDefineKey do not change their SPM binaries.',
    );
  }
  if (hasNativeBackendOverride) {
    log.warning(
      'Flutter Apple companion packages ignore $nativeBackendUserDefineKey; '
      'their frameworks include packaged native modules.',
    );
  }
  final handledRuntimes = <String>[];
  if (includeLlamaCpp) {
    output.assets.code.add(
      CodeAsset(
        package: _packageName,
        name: _packageName,
        linkMode: LookupInProcess(),
      ),
    );
    log.info(
      'Reporting package:$_packageName/$_packageName as an in-process code '
      'asset for the SPM-linked llama.cpp runtime.',
    );
    handledRuntimes.add(nativeRuntimeLlamaCpp);
  }
  if (includeLiteRtLm) {
    if (code.targetOS == OS.macOS) {
      log.info(
        'Using bundled Apple native assets because the current LiteRT-LM macOS '
        'SwiftPM artifacts do not provide a complete universal runtime.',
      );
    } else {
      log.info(
        'LiteRT-LM will resolve symbols from the SPM-linked process image.',
      );
      handledRuntimes.add(nativeRuntimeLiteRtLm);
    }
  }
  return handledRuntimes;
}

bool _hasNativeSourceOverride(HookInputUserDefines userDefines) {
  return userDefines[nativeTagUserDefineKey] != null ||
      userDefines[nativeRepositoryUserDefineKey] != null ||
      userDefines[nativePathUserDefineKey] != null;
}

bool _isAppleTarget(OS os) => os == OS.iOS || os == OS.macOS;

List<String>? _flutterAppleCompanionRuntimes({
  required BuildInput input,
  required CodeConfig code,
  required Logger log,
}) {
  if (!_isAppleTarget(code.targetOS)) {
    return null;
  }

  final consumerRoot = _consumerPackageRoot(input);
  if (consumerRoot == null) {
    log.info(
      'Using bundled Apple native assets; could not resolve the invoking '
      'package root.',
    );
    return null;
  }

  final packageRoot = Directory.fromUri(input.packageRoot);
  if (_sameDirectory(consumerRoot, packageRoot)) {
    log.info('Using bundled Apple native assets for package-root builds.');
    return null;
  }

  final pubspec = File(path.join(consumerRoot.path, 'pubspec.yaml'));
  if (!pubspec.existsSync()) {
    log.info(
      'Using bundled Apple native assets; no pubspec.yaml found at '
      '${pubspec.path}.',
    );
    return null;
  }

  final pubspecSource = pubspec.readAsStringSync();
  final isFlutter = _pubspecDeclaresFlutter(pubspecSource);
  if (!isFlutter) {
    log.info(
      'Using bundled Apple native assets for non-Flutter package '
      '${consumerRoot.path}.',
    );
    return null;
  }

  final dependencies = _pubspecDependencyNames(pubspecSource);
  final runtimes = <String>[];
  if (dependencies.contains(_llamaCppFlutterPackageName)) {
    runtimes.add(nativeRuntimeLlamaCpp);
  }
  if (dependencies.contains(_liteRtLmFlutterPackageName)) {
    runtimes.add(nativeRuntimeLiteRtLm);
  }
  if (runtimes.isEmpty) {
    log.info(
      'Using bundled Apple native assets for Flutter package '
      '${consumerRoot.path}; no Flutter Apple companion package dependency was '
      'found.',
    );
    return null;
  }
  return runtimes;
}

Directory? _consumerPackageRoot(BuildInput input) {
  final fromUserDefines = _consumerPackageRootFromUserDefines(input);
  if (fromUserDefines != null) {
    return fromUserDefines;
  }

  final sharedOutputPath = path.normalize(
    input.outputDirectoryShared.toFilePath(),
  );
  final segments = path.split(sharedOutputPath);
  final dartToolIndex = segments.lastIndexOf(_dartToolDir);
  if (dartToolIndex <= 0) {
    return null;
  }
  return Directory(path.joinAll(segments.sublist(0, dartToolIndex)));
}

Directory? _consumerPackageRootFromUserDefines(BuildInput input) {
  final userDefines = input.json['user_defines'];
  if (userDefines is! Map) {
    return null;
  }
  final workspacePubspec = userDefines['workspace_pubspec'];
  if (workspacePubspec is! Map) {
    return null;
  }
  final basePathRaw = workspacePubspec['base_path'];
  if (basePathRaw is! String || basePathRaw.trim().isEmpty) {
    return null;
  }

  final basePath = _uriOrPathToFilePath(basePathRaw);
  if (basePath == null) {
    return null;
  }

  final type = FileSystemEntity.typeSync(basePath);
  return switch (type) {
    FileSystemEntityType.directory => Directory(basePath),
    FileSystemEntityType.file => File(basePath).parent,
    _ => File(basePath).parent,
  };
}

String? _uriOrPathToFilePath(String value) {
  if (_looksLikeWindowsPath(value)) {
    return value;
  }

  final uri = Uri.tryParse(value);
  if (uri != null && uri.scheme == 'file') {
    return uri.toFilePath();
  }
  if (uri != null && uri.scheme.isNotEmpty) {
    return null;
  }
  return value;
}

bool _looksLikeWindowsPath(String value) {
  if (value.startsWith(r'\\')) {
    return true;
  }
  return RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value);
}

bool _sameDirectory(Directory a, Directory b) {
  final left = path.normalize(path.absolute(a.path));
  final right = path.normalize(path.absolute(b.path));
  return left == right;
}

bool _pubspecDeclaresFlutter(String source) {
  final lines = source.split('\n');
  for (final rawLine in lines) {
    final line = rawLine.split('#').first;
    if (RegExp(r'^\s*sdk\s*:\s*flutter\s*$').hasMatch(line)) {
      return true;
    }
  }
  return false;
}

Set<String> _pubspecDependencyNames(String source) {
  final dependencies = <String>{};
  String? section;
  int? dependencyIndent;
  for (final rawLine in source.split('\n')) {
    final line = rawLine.split('#').first;
    if (line.trim().isEmpty) {
      continue;
    }

    final topLevel = RegExp(r'^([A-Za-z_][A-Za-z0-9_]*)\s*:').firstMatch(line);
    if (topLevel != null) {
      section = topLevel.group(1);
      dependencyIndent = null;
      continue;
    }

    if (section != 'dependencies') {
      continue;
    }

    final dependency = RegExp(
      r'^(\s+)([A-Za-z_][A-Za-z0-9_]*)\s*:',
    ).firstMatch(line);
    if (dependency != null) {
      final indent = dependency.group(1)!.length;
      dependencyIndent ??= indent;
      if (indent == dependencyIndent) {
        dependencies.add(dependency.group(2)!);
      }
    }
  }
  return dependencies;
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
    log.warning(
      'LiteRT-LM runtime is not available for '
      '${_liteRtLmTargetLabel(code)}; no LiteRT-LM assets will be bundled. '
      'Configure $nativeRuntimesUserDefineKey to exclude litert_lm for this '
      'target.',
    );
    return;
  }

  final bundleDir = await _acquireLiteRtLmBundle(
    packageRoot: packageRoot,
    bundleSpec: bundleSpec,
    log: log,
  );
  if (code.targetOS == OS.macOS) {
    log.info(
      'Keeping macOS LiteRT-LM libraries in the hook cache at '
      '${bundleDir.path}; the runtime loads them directly to avoid Flutter '
      'rewriting upstream install names during app bundling.',
    );
    return;
  }
  final libraryPaths = _collectDynamicLibraryPaths(
    bundleDir,
    additionalFileNames: bundleSpec.requiredLibraries,
    onlyFileNames: code.targetOS == OS.iOS
        ? bundleSpec.requiredLibraries
        : null,
  );
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
    if (code.targetOS == OS.iOS) {
      await _makeOwnerWritableForAppleStrip(File(destinationPath), log: log);
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

Future<void> _makeOwnerWritableForAppleStrip(
  File file, {
  required Logger log,
}) async {
  final result = await Process.run('chmod', ['u+w', file.path]);
  if (result.exitCode != 0) {
    throw Exception(
      'Could not make iOS native asset writable for Xcode strip: '
      '${file.path}. ${result.stderr}',
    );
  }
  log.fine('Made iOS native asset owner-writable: ${file.path}.');
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
        Architecture.x64 => null,
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

String _liteRtLmTargetLabel(CodeConfig code) {
  final architecture =
      code.targetOS == OS.iOS && code.targetArchitecture == Architecture.x64
      ? 'x86_64'
      : code.targetArchitecture.name;
  if (code.targetOS == OS.iOS && code.iOS.targetSdk == IOSSdk.iPhoneSimulator) {
    return '${code.targetOS.name}-$architecture-sim';
  }
  return '${code.targetOS.name}-$architecture';
}

String _liteRtLmAssetName(String fileName) {
  var name = path.basenameWithoutExtension(fileName);
  final extension = path.extension(fileName).toLowerCase();
  if (name.startsWith('lib') && extension != '.dylib') {
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
  if (archiveFile.existsSync() &&
      await _verifyLiteRtLmArchiveChecksum(
        archiveFile: archiveFile,
        bundleSpec: bundleSpec,
        log: log,
        allowRefresh: true,
      ) &&
      await _tryExtractLiteRtLmArchive(
        archiveFile: archiveFile,
        extractedDir: extractedDir,
        bundleSpec: bundleSpec,
        log: log,
        allowRefresh: true,
      )) {
    return extractedDir;
  }
  if (!archiveFile.existsSync()) {
    await _downloadLiteRtLmArchive(
      bundleSpec: bundleSpec,
      destination: archiveFile,
      log: log,
    );
  }
  await _verifyLiteRtLmArchiveChecksum(
    archiveFile: archiveFile,
    bundleSpec: bundleSpec,
    log: log,
    allowRefresh: false,
  );

  await _tryExtractLiteRtLmArchive(
    archiveFile: archiveFile,
    extractedDir: extractedDir,
    bundleSpec: bundleSpec,
    log: log,
    allowRefresh: false,
  );
  return extractedDir;
}

Future<bool> _verifyLiteRtLmArchiveChecksum({
  required File archiveFile,
  required _LiteRtLmBundleSpec bundleSpec,
  required Logger log,
  required bool allowRefresh,
}) async {
  final actualSha256 = sha256
      .convert(await archiveFile.readAsBytes())
      .toString();
  if (actualSha256 == bundleSpec.sha256) {
    return true;
  }

  final message =
      'LiteRT-LM archive ${bundleSpec.archiveName} checksum mismatch: '
      'expected ${bundleSpec.sha256}, got $actualSha256.';
  if (!allowRefresh) {
    throw Exception(message);
  }

  log.warning('$message Redownloading.');
  await archiveFile.delete();
  return false;
}

Future<bool> _tryExtractLiteRtLmArchive({
  required File archiveFile,
  required Directory extractedDir,
  required _LiteRtLmBundleSpec bundleSpec,
  required Logger log,
  required bool allowRefresh,
}) async {
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
      if (!_isLiteRtLmRuntimeLibraryFileName(fileName, bundleSpec)) {
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
  } catch (error) {
    if (!allowRefresh) {
      rethrow;
    }
    log.warning(
      'Cached LiteRT-LM archive could not be extracted; redownloading '
      '${bundleSpec.archiveName}: $error',
    );
    await archiveFile.delete();
    if (extractedDir.existsSync()) {
      await extractedDir.delete(recursive: true);
    }
    return false;
  }
  final missingLibraries = _missingLiteRtLmLibraries(extractedDir, bundleSpec);
  if (missingLibraries.isNotEmpty) {
    if (allowRefresh) {
      log.warning(
        'Cached LiteRT-LM archive ${bundleSpec.archiveName} is missing '
        'required libraries: ${missingLibraries.join(', ')}; redownloading.',
      );
      await archiveFile.delete();
      if (extractedDir.existsSync()) {
        await extractedDir.delete(recursive: true);
      }
      return false;
    }
    throw Exception(
      'LiteRT-LM bundle ${bundleSpec.archiveName} is missing required '
      'libraries: ${missingLibraries.join(', ')}',
    );
  }
  log.info('Extracted LiteRT-LM bundle to ${extractedDir.path}');
  return true;
}

Future<void> _downloadLiteRtLmArchive({
  required _LiteRtLmBundleSpec bundleSpec,
  required File destination,
  required Logger log,
}) async {
  log.info('Downloading LiteRT-LM bundle from ${bundleSpec.releaseUrl}');
  await _downloadRuntimeBundle(
    url: bundleSpec.releaseUrl,
    destination: destination,
    description: 'LiteRT-LM bundle',
    log: log,
  );
}

bool _isLiteRtLmEntrySelected(
  String entryName,
  _LiteRtLmBundleSpec bundleSpec,
) {
  final normalized = path.posix.normalize(entryName);
  final sourcePrefix = bundleSpec.sourcePrefix;
  return normalized == sourcePrefix || normalized.startsWith('$sourcePrefix/');
}

Future<void> _flattenLiteRtLmDynamicLibraries(
  Directory extractedDir,
  _LiteRtLmBundleSpec bundleSpec,
) async {
  final sourcePrefix = bundleSpec.sourcePrefix;
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
    if (!_isLiteRtLmRuntimeLibraryFileName(fileName, bundleSpec)) {
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
  return true;
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

bool _isLiteRtLmRuntimeLibraryFileName(
  String fileName,
  _LiteRtLmBundleSpec bundleSpec,
) {
  return _dynamicLibraryExtensions.contains(
        path.extension(fileName).toLowerCase(),
      ) ||
      bundleSpec.requiredLibraries.contains(fileName);
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

  final tag = rawUserConfig;
  if (tag.isEmpty) {
    throw FormatException(
      'hooks.user_defines.$_packageName.$nativeTagUserDefineKey must not be '
      'empty.',
    );
  }
  if (!isValidNativeReleaseTag(tag)) {
    throw FormatException(
      'hooks.user_defines.$_packageName.$nativeTagUserDefineKey must be a '
      'stable vMAJOR.MINOR.PATCH tag, stable wrapper rebuild '
      'vMAJOR.MINOR.PATCH-N, canonical historical/nightly bNNNN tag without '
      'leading zeros, nightly wrapper '
      'rebuild bNNNN-N, or legacy wrapper artifact bNNNN-llamadart.N '
      'with numeric components of at most 18 digits '
      '(for example $_llamaCppTag).',
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

List<String> _collectDynamicLibraryPaths(
  Directory directory, {
  Set<String> additionalFileNames = const {},
  Set<String>? onlyFileNames,
}) {
  if (!directory.existsSync()) {
    return const [];
  }

  final paths = <String>[];
  for (final entity in directory.listSync(recursive: true)) {
    if (entity is! File) {
      continue;
    }
    final baseName = path.basename(entity.path);
    if (onlyFileNames != null && !onlyFileNames.contains(baseName)) {
      continue;
    }
    final fileName = baseName.toLowerCase();
    final extension = path.extension(entity.path).toLowerCase();
    if (_dynamicLibraryExtensions.contains(extension) ||
        additionalFileNames.contains(path.basename(entity.path)) ||
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
  required _NativeBundleConfig nativeConfig,
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
    // Historical b-tag artifacts and the original v0.2.0 artifact can encode
    // mtmd's literal placeholder as their ELF SONAME. v0.2.0-1 corrected it.
    final needsMtmdSoversionAlias =
        nativeConfig.tag.startsWith('b') || nativeConfig.tag == 'v0.2.0';
    if (lowered == 'libmtmd.so' && needsMtmdSoversionAlias) {
      fileNames.add('${library.fileName}.SOVERSION');
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

  await _downloadRuntimeBundle(
    url: url,
    destination: File(destinationPath),
    description: 'native bundle',
    log: log,
  );
}

Future<void> _downloadRuntimeBundle({
  required String url,
  required File destination,
  required String description,
  required Logger log,
  int maxAttempts = _runtimeBundleDownloadMaxAttempts,
  Duration requestTimeout = _runtimeBundleDownloadRequestTimeout,
  Duration transferTimeout = _runtimeBundleDownloadTransferTimeout,
  Duration retryBaseDelay = _runtimeBundleDownloadRetryBaseDelay,
  bool useCurlFallback = true,
  http.Client Function()? createClient,
  RuntimeBundleDownloadFallbackForTesting? curlFallback,
}) async {
  await destination.parent.create(recursive: true);

  Exception? lastError;
  for (var attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      await _downloadRuntimeBundleOnce(
        url: url,
        destination: destination,
        requestTimeout: requestTimeout,
        transferTimeout: transferTimeout,
        createClient: createClient,
      );
      log.info('Saved $description to ${destination.path}');
      return;
    } on Exception catch (error) {
      lastError = error;
      final isRetryable = _isRetryableRuntimeBundleDownloadError(error);
      if (!isRetryable) {
        if (attempt == 1) {
          rethrow;
        }
        throw Exception(
          'Failed to download $url after $attempt attempts: $error',
        );
      }
      if (attempt == maxAttempts) {
        break;
      }

      final retryDelay = Duration(
        microseconds: retryBaseDelay.inMicroseconds * attempt,
      );
      log.warning(
        '$description download failed ($error); retrying in '
        '${retryDelay.inSeconds}s '
        '(attempt ${attempt + 1}/$maxAttempts).',
      );
      await Future<void>.delayed(retryDelay);
    }
  }

  if (useCurlFallback &&
      lastError != null &&
      await (curlFallback ?? _downloadRuntimeBundleWithCurl)(
        url: url,
        destination: destination,
        description: description,
        log: log,
      )) {
    log.info('Saved $description to ${destination.path}');
    return;
  }

  throw Exception(
    'Failed to download $url after $maxAttempts attempts: $lastError',
  );
}

Future<void> _downloadRuntimeBundleOnce({
  required String url,
  required File destination,
  required Duration requestTimeout,
  required Duration transferTimeout,
  required http.Client Function()? createClient,
}) async {
  final client = (createClient ?? http.Client.new)();
  final temporaryDestination = File('${destination.path}.tmp');
  try {
    if (temporaryDestination.existsSync()) {
      await temporaryDestination.delete();
    }

    final request = http.Request('GET', Uri.parse(url));
    request.headers[HttpHeaders.acceptHeader] = 'application/octet-stream';
    request.headers[HttpHeaders.userAgentHeader] = 'llamadart-build-hook';
    final sendFuture = client.send(request);
    unawaited(sendFuture.then<void>((_) {}, onError: (_, _) {}));
    final response = await sendFuture.timeout(
      requestTimeout,
      onTimeout: () {
        client.close();
        throw TimeoutException(
          'Runtime bundle request timed out after '
          '${requestTimeout.inSeconds}s.',
          requestTimeout,
        );
      },
    );
    if (response.statusCode != 200) {
      throw _RuntimeBundleDownloadHttpException(url, response.statusCode);
    }

    final sink = temporaryDestination.openWrite();
    var sinkClosed = false;
    try {
      await _writeRuntimeBundleResponse(
        stream: response.stream,
        sink: sink,
        timeout: transferTimeout,
      );
      await sink.close();
      sinkClosed = true;
    } finally {
      if (!sinkClosed) {
        try {
          await sink.close();
        } catch (_) {
          // Preserve the original write or close failure; this is cleanup.
        }
      }
    }

    if (destination.existsSync()) {
      await destination.delete();
    }
    await temporaryDestination.rename(destination.path);
  } finally {
    client.close();
    if (temporaryDestination.existsSync()) {
      await temporaryDestination.delete();
    }
  }
}

/// Downloads a runtime bundle through the hardened build-hook download path.
///
/// This is intended for hook tests that need shorter retry delays and timeouts;
/// production code should use the build hook entrypoint.
Future<void> downloadRuntimeBundleForTesting({
  required String url,
  required File destination,
  required String description,
  required Logger log,
  int maxAttempts = _runtimeBundleDownloadMaxAttempts,
  Duration requestTimeout = _runtimeBundleDownloadRequestTimeout,
  Duration transferTimeout = _runtimeBundleDownloadTransferTimeout,
  Duration retryBaseDelay = _runtimeBundleDownloadRetryBaseDelay,
  bool useCurlFallback = false,
  http.Client Function()? createClient,
  RuntimeBundleDownloadFallbackForTesting? curlFallback,
}) {
  return _downloadRuntimeBundle(
    url: url,
    destination: destination,
    description: description,
    log: log,
    maxAttempts: maxAttempts,
    requestTimeout: requestTimeout,
    transferTimeout: transferTimeout,
    retryBaseDelay: retryBaseDelay,
    useCurlFallback: useCurlFallback,
    createClient: createClient,
    curlFallback: curlFallback,
  );
}

Future<void> _writeRuntimeBundleResponse({
  required Stream<List<int>> stream,
  required IOSink sink,
  required Duration timeout,
}) async {
  final completed = Completer<void>();
  late final StreamSubscription<List<int>> subscription;
  subscription = stream.listen(
    (chunk) {
      sink.add(chunk);
    },
    onError: (Object error, StackTrace stackTrace) {
      if (!completed.isCompleted) {
        completed.completeError(error, stackTrace);
      }
    },
    onDone: () {
      if (!completed.isCompleted) {
        completed.complete();
      }
    },
    cancelOnError: true,
  );
  final timeoutTimer = Timer(timeout, () {
    final timeoutError = TimeoutException(
      'Runtime bundle body download timed out after ${timeout.inSeconds}s.',
      timeout,
    );
    final timeoutStackTrace = StackTrace.current;
    unawaited(
      subscription.cancel().catchError((_) {}).whenComplete(() {
        if (!completed.isCompleted) {
          completed.completeError(timeoutError, timeoutStackTrace);
        }
      }),
    );
  });

  try {
    await completed.future;
  } finally {
    timeoutTimer.cancel();
  }
}

Future<bool> _downloadRuntimeBundleWithCurl({
  required String url,
  required File destination,
  required String description,
  required Logger log,
}) async {
  final temporaryDestination = File('${destination.path}.curl.tmp');
  try {
    if (temporaryDestination.existsSync()) {
      await temporaryDestination.delete();
    }

    log.warning(
      'Trying curl fallback for $description after Dart HTTP retries failed.',
    );
    final result = await Process.run('curl', [
      '--fail',
      '--location',
      '--retry',
      '5',
      '--retry-delay',
      '3',
      '--connect-timeout',
      '30',
      '--max-time',
      '600',
      '--silent',
      '--show-error',
      '--header',
      'Accept: application/octet-stream',
      '--header',
      'User-Agent: llamadart-build-hook',
      '--output',
      temporaryDestination.path,
      url,
    ]);
    if (result.exitCode != 0) {
      log.warning(
        'curl fallback failed for $description with exit code '
        '${result.exitCode}: ${result.stderr}',
      );
      return false;
    }

    if (destination.existsSync()) {
      await destination.delete();
    }
    await temporaryDestination.rename(destination.path);
    return true;
  } on ProcessException catch (error) {
    log.warning('curl fallback unavailable for $description: $error');
    return false;
  } finally {
    if (temporaryDestination.existsSync()) {
      await temporaryDestination.delete();
    }
  }
}

bool _isRetryableRuntimeBundleDownloadError(Exception error) {
  if (error is _RuntimeBundleDownloadHttpException) {
    return error.statusCode == 408 ||
        error.statusCode == 429 ||
        (error.statusCode >= 500 && error.statusCode < 600);
  }
  return error is http.ClientException ||
      error is SocketException ||
      error is HandshakeException ||
      error is HttpException ||
      error is TimeoutException;
}

final class _RuntimeBundleDownloadHttpException implements Exception {
  const _RuntimeBundleDownloadHttpException(this.url, this.statusCode);

  final String url;
  final int statusCode;

  @override
  String toString() => 'Failed to download $url ($statusCode).';
}

/// Extracts a native bundle archive through the hardened build-hook path.
///
/// This is intended for hook tests that need to assert extraction behaviour;
/// production code should use the build hook entrypoint.
Future<void> extractArchiveForTesting({
  required String archivePath,
  required String outputDirectory,
  required Logger log,
}) {
  return _extractArchive(
    archivePath: archivePath,
    outputDirectory: outputDirectory,
    log: log,
  );
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

  // An archive may repeat a normalized path (GNU tar emits `./`-prefixed names)
  // and may even switch its kind between repeats, so the whole archive is
  // scanned for traversal and deduplicated before anything touches the disk.
  // Only the last entry for a path decides whether it lands as a directory, a
  // regular file, or a materialized link alias.
  final entriesByArchivePath = <String, ArchiveFile>{};
  final targetPathsByArchivePath = <String, String>{};
  final winningEntryIndexes = <String, int>{};
  final archiveRelativePaths = <String>[];

  for (var index = 0; index < archive.files.length; index++) {
    final file = archive.files[index];
    final relativePath = path.normalize(file.name);
    final targetPath = path.normalize(path.join(outputRoot, relativePath));
    final isInRoot =
        targetPath == outputRoot || path.isWithin(outputRoot, targetPath);

    if (!isInRoot) {
      throw Exception(
        'Archive traversal entry blocked for $archivePath: ${file.name}',
      );
    }

    // `./` directory entries are normal in GNU tar output, but a regular file
    // or symlink named `.` would make extraction delete the output root and
    // replace it with a file, so it is rejected before anything touches disk.
    if (targetPath == outputRoot && !file.isDirectory) {
      throw Exception(
        'Archive root replacement entry blocked for $archivePath: ${file.name}',
      );
    }

    final archiveRelativePath = path.posix.joinAll(path.split(relativePath));
    entriesByArchivePath[archiveRelativePath] = file;
    targetPathsByArchivePath[archiveRelativePath] = targetPath;
    winningEntryIndexes[archiveRelativePath] = index;
    archiveRelativePaths.add(archiveRelativePath);
  }

  // Symbolic links are materialized after the extraction loop so link targets
  // that appear later in the archive still resolve.
  final symbolicLinkPaths = <String>[];

  for (var index = 0; index < archive.files.length; index++) {
    final archiveRelativePath = archiveRelativePaths[index];
    if (winningEntryIndexes[archiveRelativePath] != index) {
      continue;
    }

    final file = archive.files[index];
    final targetPath = targetPathsByArchivePath[archiveRelativePath]!;

    if (file.isDirectory) {
      await _createExtractionDirectory(targetPath);
      continue;
    }

    if (file.isSymbolicLink) {
      symbolicLinkPaths.add(archiveRelativePath);
      continue;
    }

    await _writeExtractionFile(targetPath, file.content as List<int>);
  }

  for (final linkPath in symbolicLinkPaths) {
    final resolved = _resolveArchiveSymlink(
      archivePath: archivePath,
      linkPath: linkPath,
      entriesByArchivePath: entriesByArchivePath,
    );

    final linkFilePath = targetPathsByArchivePath[linkPath]!;

    // Archive symlinks are materialized as regular files holding the resolved
    // target's bytes rather than as OS symlinks: Windows refuses symlink
    // creation without developer mode or elevation, and bundled native assets
    // are copied around by downstream tooling that would not carry a link.
    await _writeExtractionFile(
      linkFilePath,
      resolved.entry.content as List<int>,
    );
    log.fine(
      'Materialized archive symlink $linkPath as a copy of ${resolved.path}.',
    );
  }
}

/// Creates [targetPath] as a directory, replacing a file left by an earlier
/// entry for the same normalized path.
Future<void> _createExtractionDirectory(String targetPath) async {
  final existingType = await FileSystemEntity.type(
    targetPath,
    followLinks: false,
  );
  if (existingType == FileSystemEntityType.file ||
      existingType == FileSystemEntityType.link) {
    await File(targetPath).delete();
  }
  await Directory(targetPath).create(recursive: true);
}

/// Writes [bytes] to [targetPath], replacing a directory left by an earlier
/// entry for the same normalized path.
Future<void> _writeExtractionFile(String targetPath, List<int> bytes) async {
  await Directory(path.dirname(targetPath)).create(recursive: true);
  final existingType = await FileSystemEntity.type(
    targetPath,
    followLinks: false,
  );
  if (existingType == FileSystemEntityType.directory) {
    await Directory(targetPath).delete(recursive: true);
  }
  await File(targetPath).writeAsBytes(bytes);
}

typedef _ResolvedArchiveEntry = ({String path, ArchiveFile entry});

/// Follows an archive-internal symlink chain to the regular file it points at.
///
/// Throws when the chain escapes the archive root, cycles, dangles, or lands on
/// a directory, so a malicious or truncated bundle cannot write outside the
/// extraction root or leave unloadable placeholder libraries behind.
_ResolvedArchiveEntry _resolveArchiveSymlink({
  required String archivePath,
  required String linkPath,
  required Map<String, ArchiveFile> entriesByArchivePath,
}) {
  final visited = <String>{};
  var currentPath = linkPath;
  var current = entriesByArchivePath[currentPath]!;

  while (current.isSymbolicLink) {
    if (!visited.add(currentPath)) {
      throw Exception(
        'Archive symlink cycle blocked for $archivePath: $linkPath',
      );
    }

    final target = current.symbolicLink!;
    final resolvedPath = path.posix.normalize(
      path.posix.join(path.posix.dirname(currentPath), target),
    );
    if (path.posix.isAbsolute(target) ||
        path.isAbsolute(target) ||
        resolvedPath == '..' ||
        resolvedPath.startsWith('../')) {
      throw Exception(
        'Archive symlink traversal blocked for $archivePath: '
        '$linkPath -> $target',
      );
    }

    final next = entriesByArchivePath[resolvedPath];
    if (next == null) {
      throw Exception(
        'Archive symlink target missing in $archivePath: $linkPath -> $target',
      );
    }

    if (next.isDirectory) {
      throw Exception(
        'Archive symlink target is a directory in $archivePath: '
        '$linkPath -> $target',
      );
    }

    currentPath = resolvedPath;
    current = next;
  }

  return (path: currentPath, entry: current);
}
