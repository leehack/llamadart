import 'dart:io';

import 'package:llamadart/llamadart.dart';
import 'package:path/path.dart' as path;

/// Resolves a model path or downloads a model URL into local cache.
class ModelService {
  /// Creates a model service with optional custom [cacheDir].
  ModelService([String? cacheDir]) : this._(cacheDir ?? _defaultCacheDir());

  ModelService._(String resolvedCacheDir)
    : cacheDir = resolvedCacheDir,
      _downloadManager = DefaultModelDownloadManager(
        defaultCacheDirectory: resolvedCacheDir,
      );

  static String _defaultCacheDir() =>
      path.join(Directory.current.path, 'models');

  /// Directory where downloaded model files are cached.
  final String cacheDir;

  final ModelDownloadManager _downloadManager;

  /// Ensures [urlOrPath] exists locally, downloading when needed.
  Future<File> ensureModel(String urlOrPath) async {
    final source = ModelSource.parse(urlOrPath);
    if (source.isLocal) {
      final file = File(source.path!);
      if (!file.existsSync()) {
        throw Exception('Model file not found at: ${source.path}');
      }
      return file;
    }

    stdout.writeln(
      'Resolving model download/cache entry: ${source.displayName}',
    );
    final entry = await _downloadManager.ensureModel(
      source,
      onProgress: (progress) {
        final fraction = progress.fraction;
        if (fraction != null) {
          stdout.write('\rProgress: ${(fraction * 100).toStringAsFixed(1)}%');
        } else {
          final mb = (progress.receivedBytes / 1024 / 1024).toStringAsFixed(1);
          stdout.write('\rDownloaded: $mb MB');
        }
      },
    );
    stdout.writeln('\nModel ready: ${entry.filePath}');
    return File(entry.filePath);
  }
}
