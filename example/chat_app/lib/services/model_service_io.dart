import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/downloadable_model.dart';
import 'model_service_base.dart';

class ModelServiceIO implements ModelService {
  static const String _hfToken = String.fromEnvironment('HF_TOKEN');
  static const bool _enableParallelRangeDownloads = bool.fromEnvironment(
    'LLAMADART_CHAT_PARALLEL_DOWNLOAD',
    defaultValue: false,
  );
  static const int _parallelThresholdBytes = 500 * 1024 * 1024;
  static const int _parallelMaxParts = 4;

  final Dio _dio = Dio();

  Map<String, Object> _requestHeaders({int? rangeStart}) {
    final headers = <String, Object>{};
    final token = _hfToken.trim();
    if (token.isNotEmpty) {
      headers['authorization'] = 'Bearer $token';
    }
    if (rangeStart != null && rangeStart > 0) {
      headers['range'] = 'bytes=$rangeStart-';
    }
    return headers;
  }

  @override
  Future<String> getModelsDirectory() async {
    final dir = await getApplicationDocumentsDirectory();
    final modelsDir = Directory(p.join(dir.path, 'models'));
    if (!await modelsDir.exists()) {
      await modelsDir.create(recursive: true);
    }
    return modelsDir.path;
  }

  @override
  Future<Set<String>> getDownloadedModels(
    List<DownloadableModel> models,
  ) async {
    final dirPath = await getModelsDirectory();
    final Set<String> downloaded = {};

    for (final model in models) {
      final hasModel = await _isAssetAvailable(
        dirPath,
        model.modelSource,
        role: ModelAssetRole.model,
      );
      final mmprojSource = model.multimodalProjectorSource;
      final hasMmproj =
          mmprojSource == null ||
          await _isAssetAvailable(
            dirPath,
            mmprojSource,
            role: ModelAssetRole.multimodalProjector,
          );

      if (hasModel && hasMmproj) {
        downloaded.add(model.filename);
      }
    }

    return downloaded;
  }

  @override
  Future<void> downloadModel({
    required DownloadableModel model,
    required String modelsDir,
    required CancelToken cancelToken,
    required Function(double progress) onProgress,
    Function(ModelDownloadProgress progress)? onProgressDetail,
    required Function(String filename) onSuccess,
    required Function(dynamic error) onError,
  }) async {
    final modelRemoteSource = model.modelSource is RemoteModelAssetSource
        ? model.modelSource as RemoteModelAssetSource
        : null;
    final mmprojRemoteSource =
        model.multimodalProjectorSource is RemoteModelAssetSource
        ? model.multimodalProjectorSource as RemoteModelAssetSource
        : null;
    final stageCount = [
      modelRemoteSource,
      mmprojRemoteSource,
    ].whereType<RemoteModelAssetSource>().length;
    final modelStageIndex = modelRemoteSource == null ? 0 : 1;
    final mmprojStageIndex = mmprojRemoteSource == null
        ? 0
        : modelRemoteSource == null
        ? 1
        : 2;
    final providedTotalBytes =
        modelRemoteSource == null && mmprojRemoteSource != null
        ? mmprojRemoteSource.sizeBytes
        : (model.sizeBytes > 0 ? model.sizeBytes : null);
    final progressDispatcher = _ProgressDispatcher(
      onProgress: onProgress,
      onProgressDetail: onProgressDetail,
    );
    final aggregate = ModelDownloadProgressTracker(
      includeMmproj: mmprojRemoteSource != null,
      providedTotalBytes: providedTotalBytes,
    );

    try {
      await _validateLocalSource(model.modelSource);
      if (modelRemoteSource != null) {
        final modelSavePath = _assetPath(modelsDir, modelRemoteSource);
        await _downloadFileWithResume(
          url: modelRemoteSource.url,
          savePath: modelSavePath,
          cancelToken: cancelToken,
          onProgress: (downloadedBytes, totalBytes, resumed) {
            aggregate.updateModel(downloadedBytes, totalBytes);
            progressDispatcher.emit(
              aggregate.buildProgress(
                stage: ModelDownloadStage.model,
                stageIndex: modelStageIndex,
                stageCount: stageCount,
                stageDownloadedBytes: downloadedBytes,
                stageTotalBytes: totalBytes,
                resumed: resumed,
              ),
            );
          },
        );
      }

      final mmprojSource = model.multimodalProjectorSource;
      await _validateLocalSource(mmprojSource);
      if (mmprojRemoteSource != null) {
        final mmprojSavePath = _assetPath(modelsDir, mmprojRemoteSource);
        await _downloadFileWithResume(
          url: mmprojRemoteSource.url,
          savePath: mmprojSavePath,
          cancelToken: cancelToken,
          onProgress: (downloadedBytes, totalBytes, resumed) {
            aggregate.updateMmproj(downloadedBytes, totalBytes);
            progressDispatcher.emit(
              aggregate.buildProgress(
                stage: ModelDownloadStage.multimodalProjector,
                stageIndex: mmprojStageIndex,
                stageCount: stageCount,
                stageDownloadedBytes: downloadedBytes,
                stageTotalBytes: totalBytes,
                resumed: resumed,
              ),
            );
          },
        );
      }

      if (stageCount > 0) {
        progressDispatcher.emit(
          aggregate.finalProgress(stageCount: stageCount),
          force: true,
        );
      }

      onSuccess(model.filename);
    } catch (e) {
      onError(e);
    }
  }

  Future<bool> _isAssetAvailable(
    String modelsDir,
    ModelAssetSource source, {
    required ModelAssetRole role,
  }) async {
    final path = _assetPath(modelsDir, source);
    final file = File(path);
    final partialFile = File('$path.download');
    if (!await file.exists() || await partialFile.exists()) {
      return false;
    }

    if (source is RemoteModelAssetSource && role == ModelAssetRole.model) {
      final legacyMeta = File('$path.meta');
      if (await legacyMeta.exists()) {
        return false;
      }
    }

    return true;
  }

  String _assetPath(String modelsDir, ModelAssetSource source) {
    if (source is LocalModelAssetSource) {
      return source.path;
    }
    return p.join(modelsDir, (source as RemoteModelAssetSource).filename);
  }

  Future<void> _validateLocalSource(ModelAssetSource? source) async {
    if (source is! LocalModelAssetSource) {
      return;
    }
    if (!await File(source.path).exists()) {
      throw FileSystemException(
        'Local model asset does not exist',
        source.path,
      );
    }
  }

  Future<void> _downloadFileWithResume({
    required String url,
    required String savePath,
    required CancelToken cancelToken,
    required void Function(int downloadedBytes, int? totalBytes, bool resumed)
    onProgress,
  }) async {
    final tempFile = File('$savePath.download');
    var allowResume = true;

    final canTryParallel =
        _enableParallelRangeDownloads && !await tempFile.exists();
    if (canTryParallel) {
      final probe = await _probeRemoteFile(url: url, cancelToken: cancelToken);
      if (probe != null && probe.supportsRanges) {
        final totalBytes = probe.contentLength;
        if (totalBytes != null && totalBytes >= _parallelThresholdBytes) {
          final completed = await _downloadFileInParallel(
            url: url,
            savePath: savePath,
            totalBytes: totalBytes,
            cancelToken: cancelToken,
            onProgress: onProgress,
          );
          if (completed) {
            return;
          }
        }
      }
    }

    while (true) {
      final startByte = allowResume && await tempFile.exists()
          ? await tempFile.length()
          : 0;
      final headers = _requestHeaders(
        rangeStart: startByte > 0 ? startByte : null,
      );

      final response = await _dio.get<ResponseBody>(
        url,
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.stream,
          headers: headers.isEmpty ? null : headers,
          validateStatus: (status) =>
              status != null && status >= 200 && status < 500,
        ),
      );

      final statusCode = response.statusCode ?? HttpStatus.internalServerError;
      if (statusCode == HttpStatus.requestedRangeNotSatisfiable &&
          startByte > 0 &&
          await tempFile.exists()) {
        final finalFile = File(savePath);
        if (await finalFile.exists()) {
          await finalFile.delete();
        }
        await tempFile.rename(savePath);
        onProgress(startByte, startByte, true);
        return;
      }

      if (statusCode >= HttpStatus.badRequest) {
        throw DioException.badResponse(
          statusCode: statusCode,
          requestOptions: response.requestOptions,
          response: response,
        );
      }

      final contentRange = _parseContentRange(
        response.headers.value('content-range'),
      );
      final canAppend =
          startByte > 0 &&
          statusCode == HttpStatus.partialContent &&
          contentRange != null &&
          contentRange.start == startByte;

      if (startByte > 0 && !canAppend) {
        if (await tempFile.exists()) {
          await tempFile.delete();
        }

        if (statusCode == HttpStatus.ok) {
          await _consumeResponseBody(
            tempFile: tempFile,
            finalPath: savePath,
            response: response,
            startByte: 0,
            append: false,
            resumed: false,
            onProgress: onProgress,
          );
          return;
        }

        allowResume = false;
        continue;
      }

      await _consumeResponseBody(
        tempFile: tempFile,
        finalPath: savePath,
        response: response,
        startByte: canAppend ? startByte : 0,
        append: canAppend,
        resumed: canAppend,
        onProgress: onProgress,
      );
      return;
    }
  }

  Future<void> _consumeResponseBody({
    required File tempFile,
    required String finalPath,
    required Response<ResponseBody> response,
    required int startByte,
    required bool append,
    required bool resumed,
    required void Function(int downloadedBytes, int? totalBytes, bool resumed)
    onProgress,
  }) async {
    final body = response.data;
    if (body == null) {
      throw DioException(
        requestOptions: response.requestOptions,
        message: 'Download stream was empty for $finalPath',
      );
    }

    final totalBytes = _resolveTotalBytes(
      headers: response.headers,
      statusCode: response.statusCode ?? HttpStatus.ok,
      startByte: startByte,
    );

    var downloadedBytes = startByte;
    final sink = tempFile.openWrite(
      mode: append ? FileMode.append : FileMode.write,
    );
    onProgress(downloadedBytes, totalBytes, resumed);

    try {
      await for (final chunk in body.stream) {
        downloadedBytes += chunk.length;
        sink.add(chunk);
        onProgress(downloadedBytes, totalBytes, resumed);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }

    final finalFile = File(finalPath);
    if (await finalFile.exists()) {
      await finalFile.delete();
    }
    await tempFile.rename(finalPath);
  }

  Future<_RemoteFileProbe?> _probeRemoteFile({
    required String url,
    required CancelToken cancelToken,
  }) async {
    try {
      final headers = _requestHeaders();
      final response = await _dio.head<void>(
        url,
        cancelToken: cancelToken,
        options: Options(
          headers: headers.isEmpty ? null : headers,
          validateStatus: (status) =>
              status != null && status >= 200 && status < 500,
        ),
      );

      final statusCode = response.statusCode ?? HttpStatus.internalServerError;
      if (statusCode >= HttpStatus.badRequest) {
        return null;
      }

      final contentLength = int.tryParse(
        response.headers.value(Headers.contentLengthHeader) ?? '',
      );
      final acceptRanges = (response.headers.value('accept-ranges') ?? '')
          .toLowerCase();
      return _RemoteFileProbe(
        contentLength: contentLength,
        supportsRanges: acceptRanges.contains('bytes'),
      );
    } catch (_) {
      return null;
    }
  }

  Future<bool> _downloadFileInParallel({
    required String url,
    required String savePath,
    required int totalBytes,
    required CancelToken cancelToken,
    required void Function(int downloadedBytes, int? totalBytes, bool resumed)
    onProgress,
  }) async {
    final partCount = _parallelPartCount(totalBytes);
    final ranges = _buildRanges(totalBytes, partCount);
    final partFiles = <File>[
      for (var i = 0; i < ranges.length; i++) File('$savePath.part$i.download'),
    ];
    final partDownloaded = List<int>.filled(ranges.length, 0);
    final tempFile = File('$savePath.download');

    void emitProgress() {
      final downloadedBytes = partDownloaded.fold<int>(0, (sum, n) => sum + n);
      onProgress(downloadedBytes, totalBytes, false);
    }

    emitProgress();

    try {
      await Future.wait([
        for (var i = 0; i < ranges.length; i++)
          _downloadRangePart(
            url: url,
            range: ranges[i],
            output: partFiles[i],
            cancelToken: cancelToken,
            onProgress: (received) {
              partDownloaded[i] = received;
              emitProgress();
            },
          ),
      ], eagerError: true);
    } on _ParallelRangeUnsupportedException {
      await _cleanupFiles(partFiles);
      return false;
    } catch (error) {
      final isCancel =
          error is DioException && error.type == DioExceptionType.cancel;
      if (isCancel) {
        await _persistContiguousPrefix(
          tempFile: tempFile,
          partFiles: partFiles,
          ranges: ranges,
        );
      }
      await _cleanupFiles(partFiles);
      if (!isCancel && await tempFile.exists()) {
        await tempFile.delete();
      }
      rethrow;
    }

    final sink = tempFile.openWrite(mode: FileMode.write);
    try {
      for (final partFile in partFiles) {
        await sink.addStream(partFile.openRead());
      }
      await sink.flush();
    } finally {
      await sink.close();
    }

    await _cleanupFiles(partFiles);

    final finalFile = File(savePath);
    if (await finalFile.exists()) {
      await finalFile.delete();
    }
    await tempFile.rename(savePath);
    onProgress(totalBytes, totalBytes, false);
    return true;
  }

  Future<void> _downloadRangePart({
    required String url,
    required _ByteRange range,
    required File output,
    required CancelToken cancelToken,
    required void Function(int receivedBytes) onProgress,
  }) async {
    final headers = _requestHeaders();
    headers['range'] = 'bytes=${range.start}-${range.end}';

    final response = await _dio.get<ResponseBody>(
      url,
      cancelToken: cancelToken,
      options: Options(
        responseType: ResponseType.stream,
        headers: headers,
        validateStatus: (status) =>
            status != null && status >= 200 && status < 500,
      ),
    );

    final statusCode = response.statusCode ?? HttpStatus.internalServerError;
    if (statusCode >= HttpStatus.badRequest) {
      throw DioException.badResponse(
        statusCode: statusCode,
        requestOptions: response.requestOptions,
        response: response,
      );
    }

    if (statusCode != HttpStatus.partialContent) {
      throw const _ParallelRangeUnsupportedException();
    }

    final contentRange = _parseContentRange(
      response.headers.value('content-range'),
    );
    if (contentRange == null ||
        contentRange.start != range.start ||
        contentRange.end > range.end) {
      throw const _ParallelRangeUnsupportedException();
    }

    final body = response.data;
    if (body == null) {
      throw DioException(
        requestOptions: response.requestOptions,
        message: 'Range stream was empty for ${output.path}',
      );
    }

    var receivedBytes = 0;
    final sink = output.openWrite(mode: FileMode.write);
    onProgress(receivedBytes);
    try {
      await for (final chunk in body.stream) {
        receivedBytes += chunk.length;
        if (receivedBytes > range.length) {
          throw Exception(
            'Range overflow ${range.start}-${range.end}: '
            '$receivedBytes/${range.length}',
          );
        }
        sink.add(chunk);
        onProgress(receivedBytes);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }

    if (receivedBytes < range.length) {
      throw Exception(
        'Incomplete range download ${range.start}-${range.end}: '
        '$receivedBytes/${range.length}',
      );
    }
  }

  Future<void> _persistContiguousPrefix({
    required File tempFile,
    required List<File> partFiles,
    required List<_ByteRange> ranges,
  }) async {
    final sink = tempFile.openWrite(mode: FileMode.write);
    try {
      for (var i = 0; i < partFiles.length; i++) {
        final partFile = partFiles[i];
        if (!await partFile.exists()) {
          break;
        }

        final expectedLength = ranges[i].length;
        final availableLength = await partFile.length();
        if (availableLength <= 0) {
          break;
        }

        final copyLength = availableLength >= expectedLength
            ? expectedLength
            : availableLength;
        await sink.addStream(partFile.openRead(0, copyLength));

        if (availableLength < expectedLength) {
          break;
        }
      }
      await sink.flush();
    } finally {
      await sink.close();
    }

    if (await tempFile.exists() && await tempFile.length() == 0) {
      await tempFile.delete();
    }
  }

  Future<void> _cleanupFiles(List<File> files) async {
    for (final file in files) {
      if (await file.exists()) {
        await file.delete();
      }
    }
  }

  List<_ByteRange> _buildRanges(int totalBytes, int partCount) {
    final ranges = <_ByteRange>[];
    final chunkSize = (totalBytes / partCount).ceil();
    var start = 0;

    for (var i = 0; i < partCount; i++) {
      var end = start + chunkSize - 1;
      if (i == partCount - 1 || end >= totalBytes) {
        end = totalBytes - 1;
      }
      if (start >= totalBytes) {
        break;
      }
      ranges.add(_ByteRange(start: start, end: end));
      start = end + 1;
    }

    return ranges;
  }

  int _parallelPartCount(int totalBytes) {
    if (totalBytes >= 2 * 1024 * 1024 * 1024) {
      return _parallelMaxParts;
    }
    if (totalBytes >= 1024 * 1024 * 1024) {
      return 3;
    }
    return 2;
  }

  int? _resolveTotalBytes({
    required Headers headers,
    required int statusCode,
    required int startByte,
  }) {
    final contentRange = _parseContentRange(headers.value('content-range'));
    if (contentRange?.total != null) {
      return contentRange!.total;
    }

    final contentLength = int.tryParse(
      headers.value(Headers.contentLengthHeader) ?? '',
    );
    if (contentLength == null || contentLength < 0) {
      return null;
    }

    if (statusCode == HttpStatus.partialContent && startByte > 0) {
      return startByte + contentLength;
    }
    return contentLength;
  }

  _ContentRange? _parseContentRange(String? raw) {
    if (raw == null || raw.isEmpty) {
      return null;
    }

    final match = RegExp(r'^bytes\s+(\d+)-(\d+)/(\d+|\*)$').firstMatch(raw);
    if (match == null) {
      return null;
    }

    final start = int.tryParse(match.group(1)!);
    final end = int.tryParse(match.group(2)!);
    final totalToken = match.group(3);
    final total = totalToken == null || totalToken == '*'
        ? null
        : int.tryParse(totalToken);

    if (start == null || end == null) {
      return null;
    }
    return _ContentRange(start: start, end: end, total: total);
  }

  @override
  Future<void> deleteModel(String modelsDir, DownloadableModel model) async {
    await _deleteCachedAsset(modelsDir, model.modelSource);
    final mmprojSource = model.multimodalProjectorSource;
    if (mmprojSource != null) {
      await _deleteCachedAsset(modelsDir, mmprojSource);
    }
  }

  Future<void> _deleteCachedAsset(
    String modelsDir,
    ModelAssetSource source,
  ) async {
    if (source is LocalModelAssetSource) {
      return;
    }

    final path = _assetPath(modelsDir, source);
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
    }

    final tempFile = File('$path.download');
    if (await tempFile.exists()) {
      await tempFile.delete();
    }

    final legacyMeta = File('$path.meta');
    if (await legacyMeta.exists()) {
      await legacyMeta.delete();
    }
  }
}

class _ContentRange {
  final int start;
  final int end;
  final int? total;

  const _ContentRange({
    required this.start,
    required this.end,
    required this.total,
  });
}

class _RemoteFileProbe {
  final int? contentLength;
  final bool supportsRanges;

  const _RemoteFileProbe({
    required this.contentLength,
    required this.supportsRanges,
  });
}

class _ByteRange {
  final int start;
  final int end;

  const _ByteRange({required this.start, required this.end});

  int get length => end - start + 1;
}

class _ParallelRangeUnsupportedException implements Exception {
  const _ParallelRangeUnsupportedException();
}

class _ProgressDispatcher {
  static const Duration _minimumEmitInterval = Duration(milliseconds: 140);
  static const double _minimumProgressDelta = 0.005;

  final Function(double progress) onProgress;
  final Function(ModelDownloadProgress progress)? onProgressDetail;

  DateTime? _lastEmitAt;
  double _lastProgress = -1.0;

  _ProgressDispatcher({required this.onProgress, this.onProgressDetail});

  void emit(ModelDownloadProgress progress, {bool force = false}) {
    final now = DateTime.now();
    final nextProgress = progress.overallProgress.clamp(0.0, 1.0);
    final isFinal = nextProgress >= 1.0;
    final progressDelta = (nextProgress - _lastProgress).abs();
    final enoughTimeElapsed =
        _lastEmitAt == null ||
        now.difference(_lastEmitAt!) >= _minimumEmitInterval;
    final shouldEmit =
        force ||
        _lastEmitAt == null ||
        enoughTimeElapsed ||
        progressDelta >= _minimumProgressDelta ||
        isFinal;
    if (!shouldEmit) {
      return;
    }

    _lastEmitAt = now;
    _lastProgress = nextProgress;

    final normalized = ModelDownloadProgress(
      overallProgress: nextProgress,
      downloadedBytes: progress.downloadedBytes,
      totalBytes: progress.totalBytes,
      stage: progress.stage,
      stageIndex: progress.stageIndex,
      stageCount: progress.stageCount,
      stageDownloadedBytes: progress.stageDownloadedBytes,
      stageTotalBytes: progress.stageTotalBytes,
      resumed: progress.resumed,
    );

    onProgress(nextProgress);
    onProgressDetail?.call(normalized);
  }
}

ModelService createModelService() => ModelServiceIO();
