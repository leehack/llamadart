import 'dart:io';

import 'package:llamadart/llamadart.dart';

/// Service for managing model downloads and local paths.
class ModelService {
  /// Creates a model service with an optional [cacheDir].
  ModelService([String? cacheDir])
    : _downloadManager = DefaultModelDownloadManager(
        defaultCacheDirectory: cacheDir,
      );

  final DefaultModelDownloadManager _downloadManager;

  /// The directory where models are cached.
  String get cacheDir => _downloadManager.defaultCacheDirectory;

  /// Ensures the model at [urlOrPath] is available locally.
  ///
  /// Supports local filesystem paths, HTTP(S) URLs, and `hf://` Hugging Face
  /// sources. Remote sources are resolved through the package-managed model
  /// cache and returned as local files for native loading.
  Future<File> ensureModel(String urlOrPath) async {
    final source = ModelSource.parse(urlOrPath);
    if (source.isLocal) {
      final file = File(source.path!);
      if (!file.existsSync()) {
        throw Exception('Model file not found at: ${source.path}');
      }
      return file;
    }

    final entry = await _downloadManager.ensureModel(
      source,
      onProgress: (progress) {
        final fraction = progress.fraction;
        if (fraction != null) {
          final percent = (fraction * 100).toStringAsFixed(1);
          stdout.write('\rProgress: $percent%');
        } else {
          final mb = (progress.receivedBytes / 1024 / 1024).toStringAsFixed(1);
          stdout.write('\rDownloaded: $mb MB');
        }
      },
    );
    stdout.writeln('\nDownload complete.');
    return File(entry.filePath);
  }
}
