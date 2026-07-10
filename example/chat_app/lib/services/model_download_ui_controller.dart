import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:llamadart/llamadart.dart' hide ModelDownloadProgress;

import 'model_service_base.dart';

/// Owns model-download tasks and their presentation state for the chat app.
class ModelDownloadUiController extends ChangeNotifier {
  final Map<String, ValueNotifier<ModelDownloadUiState>> _uiStateByFile = {};
  final Map<String, int> _lastDownloadedBytes = {};
  final Map<String, DateTime> _lastDownloadSampleAt = {};
  final Map<String, double> _smoothedDownloadRateBytesPerSec = {};
  final Map<String, ModelDownloadController> _downloadControllers = {};
  final Map<String, StreamSubscription<ModelDownloadTaskSnapshot>>
  _downloadSubscriptions = {};
  final StreamController<String> _downloadsFinished =
      StreamController<String>.broadcast(sync: true);
  final List<_QueuedDownloadRequest> _queue = [];
  final Map<String, String> _displayNameByFile = {};
  String? _activeFilename;
  bool _isDisposed = false;

  String? get activeFilename => _activeFilename;

  String? get activeDisplayName =>
      _activeFilename == null ? null : _displayNameByFile[_activeFilename!];

  ModelDownloadUiState? get activeState =>
      _activeFilename == null ? null : _uiStateByFile[_activeFilename!]?.value;

  int get queuedCount => _queue.length;

  int get pendingCount => (_activeFilename == null ? 0 : 1) + _queue.length;

  bool get hasPendingDownloads => pendingCount > 0;

  /// Emits a filename whenever a download succeeds, fails, or is cancelled.
  ///
  /// Screens use this to refresh persistent cache state even when the widget
  /// that started the transfer has already been replaced.
  Stream<String> get downloadsFinished => _downloadsFinished.stream;

  /// Notifies active views that the cached state for [filename] may have changed.
  void notifyDownloadFinished(String filename) {
    if (!_isDisposed && !_downloadsFinished.isClosed) {
      _downloadsFinished.add(filename);
    }
  }

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

  bool isQueued(String filename) {
    return _queue.any((request) => request.filename == filename);
  }

  bool isPending(String filename) {
    return _activeFilename == filename || isQueued(filename);
  }

  Future<bool> enqueueDownload({
    required String filename,
    required String displayName,
  }) {
    if (_isDisposed || isPending(filename)) {
      return Future.value(false);
    }

    final request = _QueuedDownloadRequest(filename: filename);
    _displayNameByFile[filename] = displayName;
    _queue.add(request);
    _startNextDownload();
    _syncQueuedStates();
    _notifyGlobalListeners();
    return request.ready.future;
  }

  void completeActiveDownload(String filename) {
    if (_activeFilename != filename) {
      return;
    }
    _activeFilename = null;
    _displayNameByFile.remove(filename);
    updateState(
      filename,
      isDownloading: false,
      clearQueue: true,
      notifyGlobalListeners: false,
    );
    _startNextDownload();
    _syncQueuedStates();
    _notifyGlobalListeners();
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
    bool? isQueued,
    int? queuePosition,
    bool clearQueue = false,
    bool notifyGlobalListeners = true,
  }) {
    if (_isDisposed) {
      return;
    }
    final notifier = listenableFor(filename);
    final current = notifier.value;
    notifier.value = current.copyWith(
      isDownloading: isDownloading,
      progress: clearProgress ? 0.0 : progress,
      detail: detail,
      task: task,
      clearDetail: clearDetail,
      clearTask: clearTask,
      isQueued: isQueued,
      queuePosition: queuePosition,
      clearQueue: clearQueue,
    );
    if (notifyGlobalListeners) {
      _notifyGlobalListeners();
    }
  }

  void updateDownloadRate(String filename, ModelDownloadProgress detail) {
    if (_isDisposed) {
      return;
    }
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
    final queuedIndex = _queue.indexWhere(
      (request) => request.filename == filename,
    );
    if (queuedIndex >= 0) {
      final request = _queue.removeAt(queuedIndex);
      _displayNameByFile.remove(filename);
      if (!request.ready.isCompleted) {
        request.ready.complete(false);
      }
      updateState(
        filename,
        isDownloading: false,
        clearProgress: true,
        clearDetail: true,
        clearTask: true,
        clearQueue: true,
        notifyGlobalListeners: false,
      );
      _syncQueuedStates();
      _notifyGlobalListeners();
      return;
    }
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
    _clearQueuedDownloads();
    for (final subscription in _downloadSubscriptions.values) {
      await subscription.cancel();
    }
    _downloadSubscriptions.clear();
    for (final controller in _downloadControllers.values) {
      await controller.dispose();
    }
    _downloadControllers.clear();
    _notifyGlobalListeners();
  }

  void clearUiState() {
    for (final notifier in _uiStateByFile.values) {
      notifier.value = const ModelDownloadUiState();
    }
    _notifyGlobalListeners();
  }

  void _startNextDownload() {
    if (_isDisposed || _activeFilename != null || _queue.isEmpty) {
      return;
    }
    final request = _queue.removeAt(0);
    _activeFilename = request.filename;
    updateState(
      request.filename,
      isDownloading: true,
      clearQueue: true,
      notifyGlobalListeners: false,
    );
    if (!request.ready.isCompleted) {
      request.ready.complete(true);
    }
  }

  void _syncQueuedStates() {
    for (var index = 0; index < _queue.length; index += 1) {
      final request = _queue[index];
      updateState(
        request.filename,
        isDownloading: false,
        isQueued: true,
        queuePosition: index + 1,
        notifyGlobalListeners: false,
      );
    }
  }

  void _clearQueuedDownloads() {
    final queued = List<_QueuedDownloadRequest>.from(_queue);
    _queue.clear();
    for (final request in queued) {
      _displayNameByFile.remove(request.filename);
      if (!request.ready.isCompleted) {
        request.ready.complete(false);
      }
      updateState(
        request.filename,
        isDownloading: false,
        clearProgress: true,
        clearDetail: true,
        clearTask: true,
        clearQueue: true,
        notifyGlobalListeners: false,
      );
    }
  }

  void _notifyGlobalListeners() {
    if (!_isDisposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    if (_isDisposed) {
      return;
    }
    _isDisposed = true;
    pauseActiveDownloads();
    _clearQueuedDownloads();
    for (final subscription in _downloadSubscriptions.values) {
      unawaited(subscription.cancel());
    }
    _downloadSubscriptions.clear();
    for (final controller in _downloadControllers.values) {
      unawaited(controller.dispose());
    }
    _downloadControllers.clear();
    for (final notifier in _uiStateByFile.values) {
      notifier.dispose();
    }
    _uiStateByFile.clear();
    clearRateTracking();
    unawaited(_downloadsFinished.close());
    super.dispose();
  }
}

class _QueuedDownloadRequest {
  final String filename;
  final Completer<bool> ready = Completer<bool>();

  _QueuedDownloadRequest({required this.filename});
}

class ModelDownloadUiState {
  final bool isDownloading;
  final double progress;
  final ModelDownloadProgress? detail;
  final ModelDownloadTaskSnapshot? task;
  final bool isQueued;
  final int? queuePosition;

  const ModelDownloadUiState({
    this.isDownloading = false,
    this.progress = 0.0,
    this.detail,
    this.task,
    this.isQueued = false,
    this.queuePosition,
  });

  ModelDownloadUiState copyWith({
    bool? isDownloading,
    double? progress,
    ModelDownloadProgress? detail,
    ModelDownloadTaskSnapshot? task,
    bool clearDetail = false,
    bool clearTask = false,
    bool? isQueued,
    int? queuePosition,
    bool clearQueue = false,
  }) {
    final normalizedProgress =
        ((progress ?? this.progress).clamp(0.0, 1.0) as num).toDouble();

    return ModelDownloadUiState(
      isDownloading: isDownloading ?? this.isDownloading,
      progress: normalizedProgress,
      detail: clearDetail ? null : (detail ?? this.detail),
      task: clearTask ? null : (task ?? this.task),
      isQueued: clearQueue ? false : (isQueued ?? this.isQueued),
      queuePosition: clearQueue ? null : (queuePosition ?? this.queuePosition),
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
