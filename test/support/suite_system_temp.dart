import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';

/// Name of the cache directory LiteRT-LM services create in the system temp
/// directory when `ModelParams.liteRtLmCacheDir` is unset.
const String liteRtLmTempCacheDirectoryName = 'llamadart_litert_lm';

/// Points [Directory.systemTemp] of this isolate at a directory the suite
/// owns, from `setUpAll` to `tearDownAll`, and returns a getter for it.
///
/// LiteRT-LM services prune the program caches of their default cache
/// directory in the system temp directory, which apps share; a suite that
/// loads models with no cache directory must never reach the real one. After
/// the suite, the real directory must still hold every file it held before.
/// Isolates the suite spawns keep the real system temp directory.
Directory Function() useSuiteSystemTemp() {
  final realCacheRoot = Directory(
    '${Directory.systemTemp.path}${Platform.pathSeparator}'
    '$liteRtLmTempCacheDirectoryName',
  );
  late Directory root;
  late Set<String> realCacheFiles;
  IOOverrides? previous;

  setUpAll(() {
    realCacheFiles = _fileNames(realCacheRoot);
    root = Directory.systemTemp.createTempSync('llamadart_suite_temp_');
    // The root zone sees only the global overrides, not those of a zone
    // the suite runs in, which must not become global.
    previous = Zone.root.run(() => IOOverrides.current);
    IOOverrides.global = _SystemTempOverrides(root);
  });

  tearDownAll(() async {
    IOOverrides.global = previous;
    expect(
      realCacheFiles.difference(_fileNames(realCacheRoot)),
      isEmpty,
      reason: 'files deleted from ${realCacheRoot.path}',
    );
    await deleteSuiteRoot(root);
  });

  return () => root;
}

/// Deletes [root]. On Windows, LiteRT-LM keeps the XNNPack caches it wrote
/// open after its engines are disposed, until the process exits: when only
/// those resist, everything else is deleted now and [deleteAfterExit] removes
/// [root] once this process has exited. Any other undeletable file throws.
///
/// [isWindows] and [delete] replace the host checks in tests.
Future<void> deleteSuiteRoot(
  Directory root, {
  bool? isWindows,
  void Function(FileSystemEntity entity) delete = _deleteRecursively,
  Future<void> Function(Directory root) deleteAfterExit =
      deleteAfterProcessExit,
}) async {
  try {
    delete(root);
    return;
  } on FileSystemException {
    if (!(isWindows ?? Platform.isWindows)) rethrow;
    final undeletable = <String>[];
    for (final file
        in root
            .listSync(recursive: true, followLinks: false)
            .whereType<File>()) {
      try {
        delete(file);
      } on FileSystemException {
        if (!file.path.endsWith('.xnnpack_cache')) undeletable.add(file.path);
      }
    }
    if (undeletable.isNotEmpty) rethrow;
  }
  try {
    delete(root);
  } on FileSystemException {
    await deleteAfterExit(root);
  }
}

void _deleteRecursively(FileSystemEntity entity) =>
    entity.deleteSync(recursive: true);

/// Starts a detached Windows PowerShell that deletes [root] after this
/// process exits and releases the files it holds open.
Future<void> deleteAfterProcessExit(Directory root) => Process.start(
  'powershell.exe',
  suiteRootReaperArguments(root.path, pid),
  mode: ProcessStartMode.detached,
);

/// PowerShell arguments that wait for [processId] to exit, then delete
/// [rootPath], retrying for a minute while scanners briefly hold its files.
List<String> suiteRootReaperArguments(String rootPath, int processId) => [
  '-NoProfile',
  '-NonInteractive',
  '-Command',
  'Wait-Process -Id $processId -ErrorAction SilentlyContinue; '
      "\$root = '${rootPath.replaceAll("'", "''")}'; "
      'foreach (\$attempt in 1..60) { '
      'try { Remove-Item -LiteralPath \$root -Recurse -Force -ErrorAction Stop; '
      'exit 0 } catch { if (-not (Test-Path -LiteralPath \$root)) { exit 0 }; '
      '\$failure = \$_; Start-Sleep -Seconds 1 } }; '
      'Write-Error \$failure; exit 1',
];

Set<String> _fileNames(Directory dir) {
  if (!dir.existsSync()) return <String>{};
  return {
    for (final entry in dir.listSync(followLinks: false))
      if (entry is File) entry.uri.pathSegments.last,
  };
}

final class _SystemTempOverrides extends IOOverrides {
  _SystemTempOverrides(this.root);

  final Directory root;

  @override
  Directory getSystemTempDirectory() => root;
}
