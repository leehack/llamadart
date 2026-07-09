import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:llamadart/llamadart.dart' hide ModelDownloadProgress;

import 'model_service_base.dart';

class ModelDownloadUiController {
  final Map<String, ValueNotifier<ModelDownloadUiState>> _uiStateByFile = {};
  final Map<String, int> _lastDownloadedBytes = {};
  final Map<String, DateTime> _lastDownloadSampleAt = {};
  final Map<String, double> _smoothedDownloadRateBytesPerSec = {};
  final Map<String, ModelDownloadController> _downloadControllers = {};
  final Map<String, StreamSubscription<ModelDownloadTaskSnapshot>>
  _downloadSubscriptions = {};

  ValueNotifier<ModelDownloadUiState> listenableFor(String filename) {
    return _uiStateByFile.putIfAbsent(
      filename,
      () => ValueNotifier<ModelDownloadUiState>(const ModelDownloadUiState()),
    );
  }

  ModelDownloadTaskSnapshot? snapshotFor(String filename) {
    return _downloadControllers[filename]?.snapshot;
  }

  bool isRunning(String filename) {
    return _downloadControllers[filename]?.snapshot.isRunning ?? false;
  }

  void registerDownload({
    required String filename,
    required ModelDownloadController controller,
    required StreamSubscription<ModelDownloadTaskSnapshot> subscription,
  }) {
    _downloadControllers[filename] = controller;
    _downloadSubscriptions[filename] = subscription;
  }

  void updateState(
    String filename, {
    bool? isDownloading,
    double? progress,
    ModelDownloadProgress? detail,
    ModelDownloadTaskSnapshot? task,
    bool clearDetail = false,
    bool clearTask = false,
    bool clearProgress = false,
  }) {
    final notifier = listenableFor(filename);
    final current = notifier.value;
    notifier.value = current.copyWith(
      isDownloading: isDownloading,
      progress: clearProgress ? 0.0 : progress,
      detail: detail,
      task: task,
      clearDetail: clearDetail,
      clearTask: clearTask,
    );
  }

  void updateDownloadRate(String filename, ModelDownloadProgress detail) {
    final now = DateTime.now();
    final previousBytes = _lastDownloadedBytes[filename];
    final previousSampleAt = _lastDownloadSampleAt[filename];

    if (previousBytes != null && previousSampleAt != null) {
      final elapsedMs = now.difference(previousSampleAt).inMilliseconds;
      final deltaBytes = detail.downloadedBytes - previousBytes;
      if (elapsedMs > 0 && deltaBytes > 0) {
        final instantRate = (deltaBytes * 1000.0) / elapsedMs;
        final previousRate = _smoothedDownloadRateBytesPerSec[filename];
        _smoothedDownloadRateBytesPerSec[filename] = previousRate == null
            ? instantRate
            : ((previousRate * 0.72) + (instantRate * 0.28));
      }
    }

    _lastDownloadedBytes[filename] = detail.downloadedBytes;
    _lastDownloadSampleAt[filename] = now;
  }

  String? transferLabel(String filename, ModelDownloadProgress detail) {
    final bytesPerSecond = _smoothedDownloadRateBytesPerSec[filename];
    if (bytesPerSecond == null || bytesPerSecond <= 0) {
      return null;
    }

    final speedLabel = _formatByteRate(bytesPerSecond);
    final totalBytes = detail.totalBytes;
    if (totalBytes == null || totalBytes <= 0) {
      return speedLabel;
    }

    final remainingBytes = totalBytes - detail.downloadedBytes;
    if (remainingBytes <= 0) {
      return speedLabel;
    }

    final etaSeconds = (remainingBytes / bytesPerSecond).ceil();
    final etaLabel = _formatEta(Duration(seconds: etaSeconds));
    return '$speedLabel | $etaLabel left';
  }

  void clearTracking(String filename) {
    _lastDownloadedBytes.remove(filename);
    _lastDownloadSampleAt.remove(filename);
    _smoothedDownloadRateBytesPerSec.remove(filename);
  }

  void clearRateTracking() {
    _lastDownloadedBytes.clear();
    _lastDownloadSampleAt.clear();
    _smoothedDownloadRateBytesPerSec.clear();
  }

  void cancel(String filename) {
    _downloadControllers[filename]?.cancel();
  }

  void pauseActiveDownloads() {
    for (final controller in _downloadControllers.values) {
      if (controller.snapshot.isRunning) {
        controller.cancel();
      }
    }
  }

  Future<void> disposeDownload(
    String filename, {
    ModelDownloadController? controller,
    StreamSubscription<ModelDownloadTaskSnapshot>? subscription,
  }) async {
    final currentSubscription = _downloadSubscriptions[filename];
    if (subscription == null || identical(currentSubscription, subscription)) {
      await _downloadSubscriptions.remove(filename)?.cancel();
    } else {
      await subscription.cancel();
    }

    final currentController = _downloadControllers[filename];
    if (controller == null || identical(currentController, controller)) {
      await _downloadControllers.remove(filename)?.dispose();
    } else {
      await controller.dispose();
    }
  }

  Future<void> disposeDownloads() async {
    for (final subscription in _downloadSubscriptions.values) {
      await subscription.cancel();
    }
    _downloadSubscriptions.clear();
    for (final controller in _downloadControllers.values) {
      await controller.dispose();
    }
    _downloadControllers.clear();
  }

  void clearUiState() {
    for (final notifier in _uiStateByFile.values) {
      notifier.dispose();
    }
    _uiStateByFile.clear();
  }

  void dispose() {
    pauseActiveDownloads();
    for (final subscription in _downloadSubscriptions.values) {
      unawaited(subscription.cancel());
    }
    _downloadSubscriptions.clear();
    for (final controller in _downloadControllers.values) {
      unawaited(controller.dispose());
    }
    _downloadControllers.clear();
    clearUiState();
    clearRateTracking();
  }
}

class ModelDownloadUiState {
  final bool isDownloading;
  final double progress;
  final ModelDownloadProgress? detail;
  final ModelDownloadTaskSnapshot? task;

  const ModelDownloadUiState({
    this.isDownloading = false,
    this.progress = 0.0,
    this.detail,
    this.task,
  });

  ModelDownloadUiState copyWith({
    bool? isDownloading,
    double? progress,
    ModelDownloadProgress? detail,
    ModelDownloadTaskSnapshot? task,
    bool clearDetail = false,
    bool clearTask = false,
  }) {
    final normalizedProgress =
        ((progress ?? this.progress).clamp(0.0, 1.0) as num).toDouble();

    return ModelDownloadUiState(
      isDownloading: isDownloading ?? this.isDownloading,
      progress: normalizedProgress,
      detail: clearDetail ? null : (detail ?? this.detail),
      task: clearTask ? null : (task ?? this.task),
    );
  }
}

String downloadStageLabel(ModelDownloadProgress detail, {required bool isWeb}) {
  final actionText = detail.resumed
      ? (isWeb ? 'Resuming cache' : 'Resuming')
      : (isWeb ? 'Caching' : 'Downloading');
  final stageText = switch (detail.stage) {
    ModelDownloadStage.model => '$actionText model',
    ModelDownloadStage.multimodalProjector => '$actionText mmproj',
  };

  if (detail.stageCount > 1) {
    return '$stageText (${detail.stageIndex}/${detail.stageCount})';
  }
  return stageText;
}

String? downloadTaskLabel(
  ModelDownloadTaskSnapshot? task, {
  required bool isWeb,
}) {
  if (task == null) {
    return null;
  }
  return switch (task.stage) {
    ModelDownloadTaskStage.idle => null,
    ModelDownloadTaskStage.resolving => 'Resolving model',
    ModelDownloadTaskStage.checkingCache => 'Checking cache',
    ModelDownloadTaskStage.downloading =>
      isWeb ? 'Caching model' : 'Downloading model',
    ModelDownloadTaskStage.verifying => 'Verifying model',
    ModelDownloadTaskStage.ready => 'Ready',
    ModelDownloadTaskStage.failed => task.errorMessage ?? 'Download failed',
    ModelDownloadTaskStage.cancelled => 'Paused',
  };
}

String _formatByteRate(double bytesPerSecond) {
  if (bytesPerSecond >= 1024 * 1024 * 1024) {
    return '${(bytesPerSecond / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB/s';
  }
  if (bytesPerSecond >= 1024 * 1024) {
    return '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(2)} MB/s';
  }
  if (bytesPerSecond >= 1024) {
    return '${(bytesPerSecond / 1024).toStringAsFixed(1)} KB/s';
  }
  return '${bytesPerSecond.toStringAsFixed(0)} B/s';
}

String _formatEta(Duration duration) {
  if (duration.inHours > 0) {
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    return '${duration.inHours}h ${minutes}m';
  }
  if (duration.inMinutes > 0) {
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '${duration.inMinutes}m ${seconds}s';
  }
  return '${duration.inSeconds}s';
}
