import 'dart:io';

import 'package:archive/archive.dart';
import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;

import 'package:llamadart/src/hook/native_bundle_config.dart';

const _llamaCppTag = 'b9371';
const _nativeRepoSlug = 'leehack/llamadart-native';
const _baseUrl =
    'https://github.com/$_nativeRepoSlug/releases/download/$_llamaCppTag';

const _packageName = 'llamadart';
const _thirdPartyDir = 'third_party';
const _binDir = 'bin';
const _dartToolDir = '.dart_tool';
const _cacheBaseDir = 'llamadart';
const _bundleCacheDir = 'native_bundles';
const _reportDir = 'llamadart_bin';
const _allowLegacyLocalBundleEnv = 'LLAMADART_ALLOW_LEGACY_LOCAL_BUNDLES';

const _dynamicLibraryExtensions = {'.so', '.dylib', '.dll'};
final _windowsCudartPattern = RegExp(r'^cudart64(?:[_-]?\d+)?\.dll$');
final _windowsCublasPattern = RegExp(r'^cublas64(?:[_-]?\d+)?\.dll$');
final _linuxVersionedSoPattern = RegExp(r'\.so\.\d+$');

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
    final bundleDir = await _acquireBundleDirectory(
      packageRoot: pkgRoot,
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

    if (!usedAssetNames.contains(_packageName)) {
      throw Exception(
        'Primary asset package:$_packageName/$_packageName was not emitted.',
      );
    }
  });
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

Future<Directory> _acquireBundleDirectory({
  required String packageRoot,
  required String bundle,
  required Logger log,
}) async {
  final allowLegacyLocalBundles = _isLegacyLocalBundleEnabled();

  final cacheDir = path.join(
    packageRoot,
    _dartToolDir,
    _cacheBaseDir,
    _bundleCacheDir,
    _llamaCppTag,
    bundle,
  );
  final extractedDir = Directory(path.join(cacheDir, 'extracted'));
  final archiveName = 'llamadart-native-$bundle-$_llamaCppTag.tar.gz';
  final archivePath = path.join(cacheDir, archiveName);
  final archiveFile = File(archivePath);

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
  required String assetName,
  required String destinationPath,
  required Logger log,
}) async {
  final url = '$_baseUrl/$assetName';
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
