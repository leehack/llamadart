import 'dart:io';

/// File name suffix of the LiteRT-LM GPU program cache.
const String liteRtLmProgramCacheSuffix = '_mldrift_program_cache.bin';

/// Deletes LiteRT-LM GPU program cache files larger than [maxBytes].
///
/// Only regular files directly inside [directory] whose name ends with
/// [liteRtLmProgramCacheSuffix] are considered; links are skipped. Each
/// deletion is reported through [onDeleted] with the file path and its size in
/// bytes. File system errors are reported through [onError] and never thrown.
void pruneLiteRtLmProgramCaches(
  String directory,
  int maxBytes, {
  void Function(String path, int bytes)? onDeleted,
  void Function(String path, Object error)? onError,
}) {
  final List<FileSystemEntity> entries;
  try {
    final dir = Directory(directory);
    if (!dir.existsSync()) {
      return;
    }
    entries = dir.listSync(followLinks: false);
  } on FileSystemException catch (error) {
    onError?.call(directory, error);
    return;
  }

  for (final entry in entries) {
    if (entry is! File ||
        !entry.uri.pathSegments.last.endsWith(liteRtLmProgramCacheSuffix)) {
      continue;
    }
    try {
      final stat = entry.statSync();
      if (stat.type != FileSystemEntityType.file || stat.size <= maxBytes) {
        continue;
      }
      entry.deleteSync();
      onDeleted?.call(entry.path, stat.size);
    } on FileSystemException catch (error) {
      onError?.call(entry.path, error);
    }
  }
}
