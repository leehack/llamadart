import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;

/// Service for managing model downloads and local paths.
class ModelService {
  /// The directory where models are cached.
  final String cacheDir;

  /// Creates a model service with an optional [cacheDir].
  ModelService([String? cacheDir])
      : cacheDir = cacheDir ?? path.join(Directory.current.path, 'models');

  /// Ensures the model at [urlOrPath] is available locally.
  /// If it's a URL, it downloads it. If it's a path, it verifies existence.
  Future<File> ensureModel(String urlOrPath) async {
    if (urlOrPath.startsWith('http')) {
      return await _downloadModel(urlOrPath);
    }

    final file = File(urlOrPath);
    if (!file.existsSync()) {
      throw Exception('Model file not found at: $urlOrPath');
    }
    return file;
  }

  Future<File> _downloadModel(String url) async {
    final name = url.split('/').last.split('?').first;
    final file = File(path.join(cacheDir, name));

    if (file.existsSync() && file.lengthSync() > 0) {
      return file;
    }

    if (!file.parent.existsSync()) {
      file.parent.createSync(recursive: true);
    }

    print('Downloading model: $name');
    final client = http.Client();
    try {
      final request = http.Request('GET', Uri.parse(url));
      final response = await client.send(request);

      if (response.statusCode != 200) {
        throw Exception('Failed to download model: ${response.statusCode}');
      }

      final contentLength = response.contentLength ?? 0;
      var downloaded = 0;
      final sink = file.openWrite();

      await response.stream.listen(
        (chunk) {
          sink.add(chunk);
          downloaded += chunk.length;
          if (contentLength > 0) {
            final progress =
                (downloaded / contentLength * 100).toStringAsFixed(1);
            stdout.write('\rProgress: $progress%');
          } else {
            stdout.write(
                '\rDownloaded: ${(downloaded / 1024 / 1024).toStringAsFixed(1)} MB');
          }
        },
        onDone: () async {
          await sink.close();
          print('\nDownload complete.');
        },
        onError: (e) {
          sink.close();
          if (file.existsSync()) file.deleteSync();
          throw e;
        },
      ).asFuture();

      return file;
    } finally {
      client.close();
    }
  }
}
