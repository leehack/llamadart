import 'package:dio/dio.dart';
import '../models/downloadable_model.dart';
import 'model_service_io.dart'
    if (dart.library.js_interop) 'model_service_web.dart';

enum ModelDownloadStage { model, multimodalProjector }

class ModelDownloadProgress {
  final double overallProgress;
  final int downloadedBytes;
  final int? totalBytes;
  final ModelDownloadStage stage;
  final int stageIndex;
  final int stageCount;
  final int stageDownloadedBytes;
  final int? stageTotalBytes;
  final bool resumed;

  const ModelDownloadProgress({
    required this.overallProgress,
    required this.downloadedBytes,
    required this.totalBytes,
    required this.stage,
    required this.stageIndex,
    required this.stageCount,
    required this.stageDownloadedBytes,
    required this.stageTotalBytes,
    this.resumed = false,
  });
}

/// Tracks stage and aggregate download progress across model assets.
class ModelDownloadProgressTracker {
  final bool includeMmproj;
  final int? providedTotalBytes;

  int _modelDownloadedBytes = 0;
  int? _modelTotalBytes;
  int _mmprojDownloadedBytes = 0;
  int? _mmprojTotalBytes;

  ModelDownloadProgressTracker({
    required this.includeMmproj,
    required this.providedTotalBytes,
  });

  int get downloadedBytes =>
      _modelDownloadedBytes + (includeMmproj ? _mmprojDownloadedBytes : 0);

  int? get totalBytes {
    if (_modelTotalBytes != null &&
        (!includeMmproj || _mmprojTotalBytes != null)) {
      return _modelTotalBytes! + (_mmprojTotalBytes ?? 0);
    }
    return providedTotalBytes;
  }

  void updateModel(int downloadedBytes, int? totalBytes) {
    _modelDownloadedBytes = downloadedBytes;
    if (totalBytes != null) {
      _modelTotalBytes = totalBytes;
    }
  }

  void updateMmproj(int downloadedBytes, int? totalBytes) {
    _mmprojDownloadedBytes = downloadedBytes;
    if (totalBytes != null) {
      _mmprojTotalBytes = totalBytes;
    }
  }

  ModelDownloadProgress buildProgress({
    required ModelDownloadStage stage,
    required int stageIndex,
    required int stageCount,
    required int stageDownloadedBytes,
    required int? stageTotalBytes,
    required bool resumed,
  }) {
    final resolvedTotalBytes = totalBytes;
    final overallProgress = _overallProgress(
      stage: stage,
      stageDownloadedBytes: stageDownloadedBytes,
      stageTotalBytes: stageTotalBytes,
      resolvedTotalBytes: resolvedTotalBytes,
    );

    return ModelDownloadProgress(
      overallProgress: overallProgress,
      downloadedBytes: downloadedBytes,
      totalBytes: resolvedTotalBytes,
      stage: stage,
      stageIndex: stageIndex,
      stageCount: stageCount,
      stageDownloadedBytes: stageDownloadedBytes,
      stageTotalBytes: stageTotalBytes,
      resumed: resumed,
    );
  }

  ModelDownloadProgress finalProgress({required int stageCount}) {
    final stage = includeMmproj
        ? ModelDownloadStage.multimodalProjector
        : ModelDownloadStage.model;
    final stageDownloadedBytes = includeMmproj
        ? _mmprojDownloadedBytes
        : _modelDownloadedBytes;
    final stageTotalBytes = includeMmproj
        ? _mmprojTotalBytes
        : _modelTotalBytes;

    return ModelDownloadProgress(
      overallProgress: 1.0,
      downloadedBytes: downloadedBytes,
      totalBytes: totalBytes,
      stage: stage,
      stageIndex: stageCount,
      stageCount: stageCount,
      stageDownloadedBytes: stageDownloadedBytes,
      stageTotalBytes: stageTotalBytes,
      resumed: false,
    );
  }

  double _overallProgress({
    required ModelDownloadStage stage,
    required int stageDownloadedBytes,
    required int? stageTotalBytes,
    required int? resolvedTotalBytes,
  }) {
    if (resolvedTotalBytes != null && resolvedTotalBytes > 0) {
      return (downloadedBytes / resolvedTotalBytes).clamp(0.0, 1.0);
    }

    if (!includeMmproj) {
      if (stageTotalBytes != null && stageTotalBytes > 0) {
        return (stageDownloadedBytes / stageTotalBytes).clamp(0.0, 1.0);
      }
      return stageDownloadedBytes > 0 ? 0.01 : 0.0;
    }

    final stageProgress = stageTotalBytes != null && stageTotalBytes > 0
        ? (stageDownloadedBytes / stageTotalBytes).clamp(0.0, 1.0)
        : 0.0;

    if (stage == ModelDownloadStage.model) {
      return (stageProgress * 0.5).clamp(0.0, 0.5);
    }
    return (0.5 + (stageProgress * 0.5)).clamp(0.5, 1.0);
  }
}

abstract class WebCachePrefetchModelService {
  Future<bool> supportsWebCachePrefetch();
}

abstract class ModelService {
  factory ModelService() => createModelService();

  Future<String> getModelsDirectory();

  Future<Set<String>> getDownloadedModels(List<DownloadableModel> models);

  Future<void> downloadModel({
    required DownloadableModel model,
    required String modelsDir,
    required CancelToken cancelToken,
    required Function(double progress) onProgress,
    Function(ModelDownloadProgress progress)? onProgressDetail,
    required Function(String filename) onSuccess,
    required Function(dynamic error) onError,
  });

  Future<void> deleteModel(String modelsDir, DownloadableModel model);
}
