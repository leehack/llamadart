import 'dart:io' if (dart.library.js_interop) '../stub/io_stub.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../models/downloadable_model.dart';

class ModelService {
  final Dio _dio = Dio();

  Future<String> getModelsDirectory() async {
    final dir = await getApplicationDocumentsDirectory();
    final modelsDir = Directory(p.join(dir.path, 'models'));
    if (!modelsDir.existsSync()) {
      modelsDir.createSync(recursive: true);
    }
    return modelsDir.path;
  }

  Future<Set<String>> getDownloadedModels(
    List<DownloadableModel> models,
  ) async {
    final modelsDirPath = await getModelsDirectory();
    final downloaded = <String>{};

    for (var model in models) {
      final file = File(p.join(modelsDirPath, model.filename));
      if (file.existsSync() && file.lengthSync() > 0) {
        downloaded.add(model.filename);
      }
    }
    return downloaded;
  }

  Future<void> downloadModel({
    required DownloadableModel model,
    required String modelsDir,
    required Function(double) onProgress,
    required Function(String) onSuccess,
    required Function(dynamic) onError,
  }) async {
    final savePath = p.join(modelsDir, model.filename);

    try {
      await _dio.download(
        model.url,
        savePath,
        onReceiveProgress: (received, total) {
          if (total != -1) {
            onProgress(received / total);
          }
        },
      );
      onSuccess(model.filename);
    } catch (e) {
      final file = File(savePath);
      if (file.existsSync()) {
        file.deleteSync();
      }
      onError(e);
    }
  }

  Future<void> deleteModel(String modelsDir, String filename) async {
    final path = p.join(modelsDir, filename);
    final file = File(path);
    if (file.existsSync()) {
      await file.delete();
    }
  }
}
