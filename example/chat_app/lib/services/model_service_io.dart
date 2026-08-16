import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:llamadart/llamadart.dart' as llama;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/downloadable_model.dart';
import 'model_service_base.dart';

class ModelServiceIO implements ModelService {
  static const int _integrityStampVersion = 1;
  static const int _downloadProvenanceVersion = 2;
  static const List<Duration> _defaultRetryDelays = <Duration>[
    Duration(milliseconds: 500),
    Duration(seconds: 1),
    Duration(seconds: 2),
  ];
  static const String _hfToken = String.fromEnvironment('HF_TOKEN');
  static const bool _enableParallelRangeDownloads = bool.fromEnvironment(
    'LLAMADART_CHAT_PARALLEL_DOWNLOAD',
    defaultValue: false,
  );
  static const int _parallelThresholdBytes = 500 * 1024 * 1024;
  static const int _parallelMaxParts = 4;

  final Dio _dio;
  final List<Duration> _retryDelays;
  final Future<String> Function(File file, CancelToken? cancelToken)
  _fileSha256;
  final Map<String, _VerifiedRemoteAsset> _verifiedRemoteAssets = {};

  ModelServiceIO({
    Future<String> Function(File file, CancelToken? cancelToken)? fileSha256,
    Dio? dio,
    List<Duration>? retryDelays,
  }) : _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 30),
               receiveTimeout: const Duration(seconds: 60),
             ),
           ),
       _retryDelays = List<Duration>.unmodifiable(
         retryDelays ?? _defaultRetryDelays,
       ),
       _fileSha256 = fileSha256 ?? _computeFileSha256;

  static Future<String> _computeFileSha256(
    File file,
    CancelToken? cancelToken,
  ) async {
    final digestSink = _DigestSink();
    final inputSink = sha256.startChunkedConversion(digestSink);
    await for (final chunk in file.openRead()) {
      _throwIfCancelled(cancelToken, file.path);
      inputSink.add(chunk);
    }
    _throwIfCancelled(cancelToken, file.path);
    inputSink.close();
    return digestSink.digest.toString();
  }

  Map<String, Object> _requestHeaders({int? rangeStart, String? ifRange}) {
    final headers = <String, Object>{};
    final token = _hfToken.trim();
    if (token.isNotEmpty) {
      headers['authorization'] = 'Bearer $token';
    }
    if (rangeStart != null && rangeStart > 0) {
      headers['range'] = 'bytes=$rangeStart-';
      if (ifRange != null && ifRange.isNotEmpty) {
        headers['if-range'] = ifRange;
      }
    }
    return headers;
  }

  @override
  Future<String> getModelsDirectory() async {
    final modelsDir = Directory(await _defaultModelsDirectory());
    if (!await modelsDir.exists()) {
      await modelsDir.create(recursive: true);
    }
    return modelsDir.path;
  }

  /// Resolves the managed-cache path for one native model asset.
  String resolveManagedAssetPath(String modelsDir, ModelAssetSource source) =>
      _assetPath(modelsDir, source);

  /// Checks one native model asset using the same integrity and partial-file
  /// rules as the main model library.
  Future<bool> isManagedAssetAvailable(
    String modelsDir,
    ModelAssetSource source, {
    required ModelAssetRole role,
  }) => _isAssetAvailable(modelsDir, source, role: role);

  /// Downloads and verifies one native model asset with resumable transfer
  /// provenance.
  Future<void> downloadManagedAsset({
    required String modelsDir,
    required RemoteModelAssetSource source,
    required ModelAssetRole role,
    required CancelToken cancelToken,
    required void Function(int downloadedBytes, int? totalBytes, bool resumed)
    onProgress,
    void Function()? onVerifying,
  }) async {
    if (await _isAssetAvailable(modelsDir, source, role: role)) {
      final size = await File(_assetPath(modelsDir, source)).length();
      onProgress(size, source.sizeBytes ?? size, false);
      return;
    }
    await _downloadFileWithResume(
      source: source,
      savePath: _assetPath(modelsDir, source),
      cancelToken: cancelToken,
      onProgress: onProgress,
    );
    onVerifying?.call();
    await _verifyDownloadedRemoteAsset(modelsDir, source, cancelToken);
  }

  /// Deletes one managed native model asset and its integrity metadata.
  Future<void> deleteManagedAsset(String modelsDir, ModelAssetSource source) =>
      _deleteCachedAsset(modelsDir, source);

  Future<String> _defaultModelsDirectory() async {
    if (Platform.isAndroid || Platform.isIOS) {
      final dir = await getApplicationCacheDirectory();
      return p.join(dir.path, 'models');
    }

    try {
      return llama.DefaultModelDownloadManager.auto().defaultCacheDirectory;
    } catch (_) {
      final dir = await getApplicationCacheDirectory();
      return p.join(dir.path, 'models');
    }
  }

  @override
  Future<Set<String>> getDownloadedModels(
    List<DownloadableModel> models,
  ) async {
    final dirPath = await getModelsDirectory();
    final Set<String> downloaded = {};

    for (final model in models) {
      final cacheState = await _modelCacheState(model, dirPath);
      if (cacheState.isReady) {
        downloaded.add(model.filename);
      }
    }

    return downloaded;
  }

  @override
  Future<ModelProfileCacheState> getModelCacheState(
    DownloadableModel model,
  ) async {
    final dirPath = await getModelsDirectory();
    return _modelCacheState(model, dirPath);
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
    final progressDispatcher = _ProgressDispatcher(
      onProgress: onProgress,
      onProgressDetail: onProgressDetail,
    );

    try {
      await _validateLocalSource(model.modelSource);
      final modelNeedsDownload =
          modelRemoteSource != null &&
          !await _isAssetAvailable(
            modelsDir,
            modelRemoteSource,
            role: ModelAssetRole.model,
          );

      final mmprojSource = model.multimodalProjectorSource;
      await _validateLocalSource(mmprojSource);
      final mmprojNeedsDownload =
          mmprojRemoteSource != null &&
          !await _isAssetAvailable(
            modelsDir,
            mmprojRemoteSource,
            role: ModelAssetRole.multimodalProjector,
          );

      final stageCount = [
        if (modelNeedsDownload) modelRemoteSource,
        if (mmprojNeedsDownload) mmprojRemoteSource,
      ].whereType<RemoteModelAssetSource>().length;
      final modelStageIndex = modelNeedsDownload ? 1 : 0;
      final mmprojStageIndex = mmprojNeedsDownload
          ? (modelNeedsDownload ? 2 : 1)
          : 0;
      final aggregate = ModelDownloadProgressTracker(
        includeMmproj: mmprojNeedsDownload,
        providedTotalBytes: _providedDownloadTotalBytes(
          model: model,
          modelSource: modelRemoteSource,
          modelNeedsDownload: modelNeedsDownload,
          mmprojSource: mmprojRemoteSource,
          mmprojNeedsDownload: mmprojNeedsDownload,
        ),
      );

      if (modelNeedsDownload) {
        final source = modelRemoteSource;
        final modelSavePath = _assetPath(modelsDir, source);
        await _downloadFileWithResume(
          source: source,
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
        await _verifyDownloadedRemoteAsset(modelsDir, source, cancelToken);
      }

      if (mmprojNeedsDownload) {
        final source = mmprojRemoteSource;
        final mmprojSavePath = _assetPath(modelsDir, source);
        await _downloadFileWithResume(
          source: source,
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
        await _verifyDownloadedRemoteAsset(modelsDir, source, cancelToken);
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

  Future<ModelProfileCacheState> _modelCacheState(
    DownloadableModel model,
    String modelsDir,
  ) async {
    final modelSource = model.modelSource;
    final mmprojSource = model.multimodalProjectorSource;
    return ModelProfileCacheState(
      model: ModelAssetCacheState(
        role: ModelAssetRole.model,
        label: modelSource.displayName,
        isAvailable: await _isAssetAvailable(
          modelsDir,
          modelSource,
          role: ModelAssetRole.model,
        ),
      ),
      multimodalProjector: mmprojSource == null
          ? null
          : ModelAssetCacheState(
              role: ModelAssetRole.multimodalProjector,
              label: mmprojSource.displayName,
              isAvailable: await _isAssetAvailable(
                modelsDir,
                mmprojSource,
                role: ModelAssetRole.multimodalProjector,
              ),
            ),
    );
  }

  int? _providedDownloadTotalBytes({
    required DownloadableModel model,
    required RemoteModelAssetSource? modelSource,
    required bool modelNeedsDownload,
    required RemoteModelAssetSource? mmprojSource,
    required bool mmprojNeedsDownload,
  }) {
    if (modelNeedsDownload && mmprojNeedsDownload && model.sizeBytes > 0) {
      return model.sizeBytes;
    }
    if (modelNeedsDownload) {
      return modelSource?.sizeBytes ??
          (model.sizeBytes > 0 ? model.sizeBytes : null);
    }
    if (mmprojNeedsDownload) {
      return mmprojSource?.sizeBytes;
    }
    return null;
  }

  Future<bool> _isAssetAvailable(
    String modelsDir,
    ModelAssetSource source, {
    required ModelAssetRole role,
  }) async {
    final path = _assetPath(modelsDir, source);
    if (source is RemoteModelAssetSource) {
      await _discardStalePartial(path, source);
    }
    final file = File(path);
    final partialFile = File('$path.download');
    if (!await file.exists()) {
      if (source is RemoteModelAssetSource) {
        await _clearVerifiedRemoteAsset(path);
      }
      return false;
    }
    if (await partialFile.exists()) {
      return false;
    }

    if (source is RemoteModelAssetSource && role == ModelAssetRole.model) {
      final legacyMeta = File('$path.meta');
      if (await legacyMeta.exists()) {
        return false;
      }
    }

    if (source is RemoteModelAssetSource &&
        !await _hasExpectedIntegrity(file, source)) {
      return false;
    }

    return true;
  }

  Future<bool> _hasExpectedIntegrity(
    File file,
    RemoteModelAssetSource source, {
    CancelToken? cancelToken,
  }) async {
    final expectedSha256 = source.sha256?.trim().toLowerCase();
    if (expectedSha256 == null || expectedSha256.isEmpty) {
      return true;
    }

    final stat = await file.stat();
    final expectedBytes = source.sizeBytes;
    if (expectedBytes != null && stat.size != expectedBytes) {
      await _clearVerifiedRemoteAsset(file.path);
      return false;
    }

    final cached = _verifiedRemoteAssets[file.path];
    if (cached != null && cached.matches(stat, source, expectedSha256)) {
      return true;
    }

    final persisted = await _readVerifiedRemoteAsset(file.path);
    if (persisted != null && persisted.matches(stat, source, expectedSha256)) {
      _verifiedRemoteAssets[file.path] = persisted;
      return true;
    }

    final String actualSha256;
    final FileStat verifiedStat;
    try {
      actualSha256 = (await _fileSha256(file, cancelToken)).toLowerCase();
      _throwIfCancelled(cancelToken, file.path);
      verifiedStat = await file.stat();
    } on FileSystemException {
      await _clearVerifiedRemoteAsset(file.path);
      return false;
    }
    if (!_sameFileState(stat, verifiedStat)) {
      await _clearVerifiedRemoteAsset(file.path);
      return false;
    }
    if (actualSha256 != expectedSha256) {
      await _clearVerifiedRemoteAsset(file.path);
      return false;
    }
    final verified = _VerifiedRemoteAsset(
      sourceCacheKey: source.cacheKey,
      size: verifiedStat.size,
      modifiedMicros: verifiedStat.modified.microsecondsSinceEpoch,
      changedMicros: verifiedStat.changed.microsecondsSinceEpoch,
      sha256: actualSha256,
    );
    _verifiedRemoteAssets[file.path] = verified;
    await _persistVerifiedRemoteAsset(file.path, verified);
    return true;
  }

  bool _sameFileState(FileStat first, FileStat second) {
    return first.size == second.size &&
        first.modified == second.modified &&
        first.changed == second.changed;
  }

  File _integrityStampFile(String path) {
    return File('$path.llamadart-integrity.json');
  }

  Future<_VerifiedRemoteAsset?> _readVerifiedRemoteAsset(String path) async {
    final stamp = await _readJsonMap(_integrityStampFile(path));
    if (stamp == null || stamp['version'] != _integrityStampVersion) {
      return null;
    }
    try {
      return _VerifiedRemoteAsset.fromJson(stamp);
    } on Object {
      return null;
    }
  }

  Future<void> _persistVerifiedRemoteAsset(
    String path,
    _VerifiedRemoteAsset verified,
  ) async {
    try {
      await _writeJsonAtomically(_integrityStampFile(path), {
        'version': _integrityStampVersion,
        ...verified.toJson(),
      });
    } catch (_) {
      // The stamp is an optimization only. A future process can safely hash
      // the artifact again if metadata cannot be persisted.
    }
  }

  Future<void> _clearVerifiedRemoteAsset(String path) async {
    _verifiedRemoteAssets.remove(path);
    await _deleteIfExists(_integrityStampFile(path));
  }

  Future<void> _verifyDownloadedRemoteAsset(
    String modelsDir,
    RemoteModelAssetSource source,
    CancelToken cancelToken,
  ) async {
    final expectedSha256 = source.sha256?.trim();
    if (expectedSha256 == null || expectedSha256.isEmpty) {
      return;
    }
    final file = File(_assetPath(modelsDir, source));
    if (await file.exists() &&
        await _hasExpectedIntegrity(file, source, cancelToken: cancelToken)) {
      return;
    }
    if (await file.exists()) {
      await file.delete();
    }
    await _clearVerifiedRemoteAsset(file.path);
    throw StateError(
      'SHA-256 verification failed for ${source.displayName}. '
      'The incomplete download was discarded; retry the download.',
    );
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

  File _downloadProvenanceFile(String path) {
    return File('$path.download.source.json');
  }

  Future<_DownloadProvenance?> _discardStalePartial(
    String savePath,
    RemoteModelAssetSource source,
  ) async {
    final tempFile = File('$savePath.download');
    final provenanceFile = _downloadProvenanceFile(savePath);
    if (!await tempFile.exists()) {
      await _deleteIfExists(provenanceFile);
      return null;
    }

    final provenance = await _readDownloadProvenance(provenanceFile);
    final partialLength = await tempFile.length();
    if (provenance == null ||
        !provenance.matchesSource(source) ||
        provenance.partialIsInvalid(partialLength)) {
      await tempFile.delete();
      await _deleteIfExists(provenanceFile);
      return null;
    }
    return provenance;
  }

  Future<_DownloadProvenance?> _readDownloadProvenance(File file) async {
    final data = await _readJsonMap(file);
    if (data == null || data['version'] != _downloadProvenanceVersion) {
      return null;
    }
    try {
      return _DownloadProvenance.fromJson(data);
    } on Object {
      return null;
    }
  }

  Future<void> _writeDownloadProvenance(
    String savePath,
    _DownloadProvenance provenance,
  ) async {
    await _writeJsonAtomically(_downloadProvenanceFile(savePath), {
      'version': _downloadProvenanceVersion,
      ...provenance.toJson(),
    });
  }

  Future<Map<String, Object?>?> _readJsonMap(File file) async {
    try {
      if (!await file.exists()) {
        return null;
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) {
        return null;
      }
      return decoded.map(
        (key, value) => MapEntry(key.toString(), value as Object?),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeJsonAtomically(
    File destination,
    Map<String, Object?> data,
  ) async {
    await destination.parent.create(recursive: true);
    final temporary = File(
      '${destination.path}.tmp.$pid.${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await temporary.writeAsString(jsonEncode(data), flush: true);
      if (await destination.exists()) {
        await destination.delete();
      }
      await temporary.rename(destination.path);
    } finally {
      await _deleteIfExists(temporary);
    }
  }

  Future<void> _deleteIfExists(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } on FileSystemException {
      // Cleanup is best effort. Callers still validate metadata before reuse.
    }
  }

  Future<void> _downloadFileWithResume({
    required RemoteModelAssetSource source,
    required String savePath,
    required CancelToken cancelToken,
    required void Function(int downloadedBytes, int? totalBytes, bool resumed)
    onProgress,
  }) async {
    final existingProvenance = await _discardStalePartial(savePath, source);
    if (existingProvenance == null) {
      await _writeDownloadProvenance(
        savePath,
        _DownloadProvenance.fromSource(source),
      );
    }
    var completed = false;
    var retryIndex = 0;
    try {
      while (true) {
        try {
          await _downloadFile(
            source: source,
            savePath: savePath,
            cancelToken: cancelToken,
            onProgress: onProgress,
          );
          completed = true;
          break;
        } catch (error) {
          if (cancelToken.isCancelled ||
              retryIndex >= _retryDelays.length ||
              !_isRetryableDownloadError(error)) {
            rethrow;
          }
          await _waitForRetry(
            _retryDelays[retryIndex],
            cancelToken,
            source.filename,
          );
          retryIndex++;
        }
      }
    } finally {
      if (completed) {
        await _deleteIfExists(_downloadProvenanceFile(savePath));
      }
    }
  }

  Future<void> _downloadFile({
    required RemoteModelAssetSource source,
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
      final probe = await _probeRemoteFile(
        url: source.url,
        cancelToken: cancelToken,
      );
      if (probe != null && probe.supportsRanges) {
        final totalBytes = probe.contentLength;
        final canBindRepresentation =
            probe.validator != null ||
            _hasCryptographicOrImmutableSafety(source);
        if (totalBytes != null &&
            totalBytes >= _parallelThresholdBytes &&
            canBindRepresentation) {
          await _writeDownloadProvenance(
            savePath,
            _DownloadProvenance.fromSource(source).withRepresentation(
              validator: probe.validator,
              totalBytes: totalBytes,
            ),
          );
          final completed = await _downloadFileInParallel(
            url: source.url,
            savePath: savePath,
            totalBytes: totalBytes,
            validator: probe.validator,
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
      final provenance = await _readDownloadProvenance(
        _downloadProvenanceFile(savePath),
      );
      final candidateStartByte = allowResume && await tempFile.exists()
          ? await tempFile.length()
          : 0;
      final canResume =
          candidateStartByte > 0 &&
          provenance != null &&
          provenance.canAttemptResume(
            source,
            partialLength: candidateStartByte,
          );
      final startByte = canResume ? candidateStartByte : 0;
      if (candidateStartByte > 0 && !canResume) {
        await tempFile.delete();
      }
      final headers = _requestHeaders(
        rangeStart: startByte > 0 ? startByte : null,
        ifRange: startByte > 0 ? provenance?.validator?.value : null,
      );

      final response = await _dio.get<ResponseBody>(
        source.url,
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
        final unsatisfiedTotal = _parseUnsatisfiedContentRangeTotal(
          response.headers.value('content-range'),
        );
        final validatorMatches = _responseValidatorMatches(
          response.headers,
          provenance?.validator,
        );
        final hasIndependentCompletionProof =
            provenance?.validator != null ||
            (provenance?.expectedSha256?.isNotEmpty ?? false);
        var canTrustCompletePartial =
            unsatisfiedTotal == startByte &&
            provenance != null &&
            provenance.totalBytes == startByte &&
            hasIndependentCompletionProof &&
            provenance.canAttemptResume(source, partialLength: startByte) &&
            validatorMatches;
        final expectedSha256 = provenance?.expectedSha256;
        if (canTrustCompletePartial &&
            expectedSha256 != null &&
            expectedSha256.isNotEmpty) {
          canTrustCompletePartial =
              (await _fileSha256(tempFile, cancelToken)).toLowerCase() ==
              expectedSha256;
        }
        if (canTrustCompletePartial) {
          final finalFile = File(savePath);
          if (await finalFile.exists()) {
            await finalFile.delete();
          }
          await tempFile.rename(savePath);
          onProgress(startByte, startByte, true);
          return;
        }
        await tempFile.delete();
        await _writeDownloadProvenance(
          savePath,
          _DownloadProvenance.fromSource(source),
        );
        allowResume = false;
        continue;
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
          contentRange.start == startByte &&
          _responseValidatorMatches(response.headers, provenance?.validator) &&
          _responseTotalMatches(contentRange.total, provenance?.knownTotal);

      if (startByte == 0) {
        final responseTotal = _resolveTotalBytes(
          headers: response.headers,
          statusCode: statusCode,
          startByte: 0,
        );
        final responseValidator = _preferredResponseValidator(response.headers);
        await _writeDownloadProvenance(
          savePath,
          _DownloadProvenance.fromSource(source).withRepresentation(
            validator: responseValidator,
            totalBytes: responseTotal,
          ),
        );
      }

      if (startByte > 0 && !canAppend) {
        if (await tempFile.exists()) {
          await tempFile.delete();
        }

        if (statusCode == HttpStatus.ok) {
          await _writeDownloadProvenance(
            savePath,
            _DownloadProvenance.fromSource(source).withRepresentation(
              validator: _preferredResponseValidator(response.headers),
              totalBytes: _resolveTotalBytes(
                headers: response.headers,
                statusCode: statusCode,
                startByte: 0,
              ),
            ),
          );
          await _consumeResponseBody(
            tempFile: tempFile,
            finalPath: savePath,
            response: response,
            startByte: 0,
            expectedTotalBytes: provenance?.knownTotal ?? source.sizeBytes,
            append: false,
            resumed: false,
            onProgress: onProgress,
          );
          return;
        }

        allowResume = false;
        await _writeDownloadProvenance(
          savePath,
          _DownloadProvenance.fromSource(source),
        );
        continue;
      }

      await _consumeResponseBody(
        tempFile: tempFile,
        finalPath: savePath,
        response: response,
        startByte: canAppend ? startByte : 0,
        expectedTotalBytes: provenance?.knownTotal ?? source.sizeBytes,
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
    required int? expectedTotalBytes,
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

    final responseTotalBytes = _resolveTotalBytes(
      headers: response.headers,
      statusCode: response.statusCode ?? HttpStatus.ok,
      startByte: startByte,
    );
    final normalizedExpectedTotal =
        expectedTotalBytes != null && expectedTotalBytes > 0
        ? expectedTotalBytes
        : null;
    final totalBytes = responseTotalBytes ?? normalizedExpectedTotal;

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

    if (totalBytes != null && downloadedBytes != totalBytes) {
      throw DioException(
        requestOptions: response.requestOptions,
        type: DioExceptionType.connectionError,
        message:
            'Download stream ended at $downloadedBytes of $totalBytes bytes.',
      );
    }

    final finalFile = File(finalPath);
    if (await finalFile.exists()) {
      await finalFile.delete();
    }
    await tempFile.rename(finalPath);
  }

  bool _isRetryableDownloadError(Object error) {
    if (error is SocketException || error is HttpException) {
      return true;
    }
    if (error is! DioException) {
      return false;
    }
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.connectionError:
        return true;
      case DioExceptionType.badResponse:
        final statusCode = error.response?.statusCode;
        return statusCode == HttpStatus.requestTimeout ||
            statusCode == HttpStatus.tooManyRequests ||
            (statusCode != null && statusCode >= 500 && statusCode < 600);
      case DioExceptionType.unknown:
        return error.error is SocketException || error.error is HttpException;
      case DioExceptionType.badCertificate:
      case DioExceptionType.cancel:
        return false;
    }
  }

  Future<void> _waitForRetry(
    Duration delay,
    CancelToken cancelToken,
    String filename,
  ) async {
    if (cancelToken.isCancelled) {
      throw _cancelledDownload(filename);
    }
    await Future.any<void>([
      Future<void>.delayed(delay),
      cancelToken.whenCancel.then<void>((_) {}),
    ]);
    if (cancelToken.isCancelled) {
      throw _cancelledDownload(filename);
    }
  }

  static void _throwIfCancelled(CancelToken? cancelToken, String filename) {
    if (cancelToken?.isCancelled ?? false) {
      throw _cancelledDownload(filename);
    }
  }

  static DioException _cancelledDownload(String filename) => DioException(
    requestOptions: RequestOptions(path: filename),
    type: DioExceptionType.cancel,
    message: 'Model download was cancelled.',
  );

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
        validator: _preferredResponseValidator(response.headers),
      );
    } catch (_) {
      return null;
    }
  }

  Future<bool> _downloadFileInParallel({
    required String url,
    required String savePath,
    required int totalBytes,
    required _HttpRepresentationValidator? validator,
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
            totalBytes: totalBytes,
            validator: validator,
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
    required int totalBytes,
    required _HttpRepresentationValidator? validator,
    required File output,
    required CancelToken cancelToken,
    required void Function(int receivedBytes) onProgress,
  }) async {
    final headers = _requestHeaders();
    headers['range'] = 'bytes=${range.start}-${range.end}';
    if (validator != null) {
      headers['if-range'] = validator.value;
    }

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
        contentRange.end > range.end ||
        contentRange.total != totalBytes ||
        !_responseValidatorMatches(response.headers, validator)) {
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

  bool _hasCryptographicOrImmutableSafety(RemoteModelAssetSource source) {
    final expectedSha256 = source.sha256?.trim();
    if (expectedSha256 != null && expectedSha256.isNotEmpty) {
      return true;
    }
    final uri = Uri.tryParse(source.url);
    if (uri == null) {
      return false;
    }
    final segments = uri.pathSegments;
    final resolveIndex = segments.indexOf('resolve');
    if (resolveIndex < 0 || resolveIndex + 1 >= segments.length) {
      return false;
    }
    final revision = segments[resolveIndex + 1];
    return RegExp(r'^[0-9a-fA-F]{40,64}$').hasMatch(revision);
  }

  _HttpRepresentationValidator? _preferredResponseValidator(Headers headers) {
    final etag = headers.value(HttpHeaders.etagHeader)?.trim();
    if (etag != null &&
        etag.isNotEmpty &&
        !etag.toUpperCase().startsWith('W/')) {
      return _HttpRepresentationValidator(
        kind: _HttpValidatorKind.strongEtag,
        value: etag,
      );
    }
    final lastModified = headers.value(HttpHeaders.lastModifiedHeader)?.trim();
    if (lastModified != null && lastModified.isNotEmpty) {
      return _HttpRepresentationValidator(
        kind: _HttpValidatorKind.lastModified,
        value: lastModified,
      );
    }
    return null;
  }

  bool _responseValidatorMatches(
    Headers headers,
    _HttpRepresentationValidator? expected,
  ) {
    if (expected == null) {
      return true;
    }
    final actual = switch (expected.kind) {
      _HttpValidatorKind.strongEtag =>
        headers.value(HttpHeaders.etagHeader)?.trim(),
      _HttpValidatorKind.lastModified =>
        headers.value(HttpHeaders.lastModifiedHeader)?.trim(),
    };
    return actual == expected.value;
  }

  bool _responseTotalMatches(int? actual, int? expected) {
    return expected == null || actual == expected;
  }

  int? _parseUnsatisfiedContentRangeTotal(String? raw) {
    if (raw == null || raw.isEmpty) {
      return null;
    }
    final match = RegExp(r'^bytes\s+\*/(\d+)$').firstMatch(raw);
    return match == null ? null : int.tryParse(match.group(1)!);
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
    await _clearVerifiedRemoteAsset(path);
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
    }

    final tempFile = File('$path.download');
    if (await tempFile.exists()) {
      await tempFile.delete();
    }

    await _deleteIfExists(_downloadProvenanceFile(path));

    final legacyMeta = File('$path.meta');
    if (await legacyMeta.exists()) {
      await legacyMeta.delete();
    }
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? _digest;

  Digest get digest =>
      _digest ?? (throw StateError('SHA-256 conversion did not complete.'));

  @override
  void add(Digest data) {
    _digest = data;
  }

  @override
  void close() {}
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
  final _HttpRepresentationValidator? validator;

  const _RemoteFileProbe({
    required this.contentLength,
    required this.supportsRanges,
    required this.validator,
  });
}

enum _HttpValidatorKind { strongEtag, lastModified }

class _HttpRepresentationValidator {
  final _HttpValidatorKind kind;
  final String value;

  const _HttpRepresentationValidator({required this.kind, required this.value});

  factory _HttpRepresentationValidator.fromJson(Map<String, Object?> data) {
    return _HttpRepresentationValidator(
      kind: _HttpValidatorKind.values.byName(data['kind'] as String),
      value: data['value'] as String,
    );
  }

  Map<String, Object?> toJson() => {'kind': kind.name, 'value': value};
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

class _VerifiedRemoteAsset {
  final String sourceCacheKey;
  final int size;
  final int modifiedMicros;
  final int changedMicros;
  final String sha256;

  const _VerifiedRemoteAsset({
    required this.sourceCacheKey,
    required this.size,
    required this.modifiedMicros,
    required this.changedMicros,
    required this.sha256,
  });

  factory _VerifiedRemoteAsset.fromJson(Map<String, Object?> data) {
    return _VerifiedRemoteAsset(
      sourceCacheKey: data['sourceCacheKey'] as String,
      size: data['size'] as int,
      modifiedMicros: data['modifiedMicros'] as int,
      changedMicros: data['changedMicros'] as int,
      sha256: data['sha256'] as String,
    );
  }

  bool matches(
    FileStat stat,
    RemoteModelAssetSource source,
    String expectedSha256,
  ) {
    return sourceCacheKey == source.cacheKey &&
        size == stat.size &&
        modifiedMicros == stat.modified.microsecondsSinceEpoch &&
        changedMicros == stat.changed.microsecondsSinceEpoch &&
        sha256 == expectedSha256;
  }

  Map<String, Object?> toJson() => {
    'sourceCacheKey': sourceCacheKey,
    'size': size,
    'modifiedMicros': modifiedMicros,
    'changedMicros': changedMicros,
    'sha256': sha256,
  };
}

class _DownloadProvenance {
  final String sourceCacheKey;
  final String? expectedSha256;
  final int? expectedSizeBytes;
  final _HttpRepresentationValidator? validator;
  final int? totalBytes;

  const _DownloadProvenance({
    required this.sourceCacheKey,
    required this.expectedSha256,
    required this.expectedSizeBytes,
    required this.validator,
    required this.totalBytes,
  });

  factory _DownloadProvenance.fromSource(RemoteModelAssetSource source) {
    return _DownloadProvenance(
      sourceCacheKey: source.cacheKey,
      expectedSha256: source.sha256?.trim().toLowerCase(),
      expectedSizeBytes: source.sizeBytes,
      validator: null,
      totalBytes: null,
    );
  }

  factory _DownloadProvenance.fromJson(Map<String, Object?> data) {
    return _DownloadProvenance(
      sourceCacheKey: data['sourceCacheKey'] as String,
      expectedSha256: data['expectedSha256'] as String?,
      expectedSizeBytes: data['expectedSizeBytes'] as int?,
      validator: data['validator'] is Map
          ? _HttpRepresentationValidator.fromJson(
              (data['validator'] as Map).map(
                (key, value) => MapEntry(key.toString(), value as Object?),
              ),
            )
          : null,
      totalBytes: data['totalBytes'] as int?,
    );
  }

  bool matchesSource(RemoteModelAssetSource source) {
    final expected = _DownloadProvenance.fromSource(source);
    return sourceCacheKey == expected.sourceCacheKey &&
        expectedSha256 == expected.expectedSha256 &&
        expectedSizeBytes == expected.expectedSizeBytes;
  }

  bool partialIsInvalid(int partialLength) {
    final total = knownTotal;
    return partialLength <= 0 || (total != null && partialLength > total);
  }

  bool canAttemptResume(
    RemoteModelAssetSource source, {
    required int partialLength,
  }) {
    if (!matchesSource(source) || partialIsInvalid(partialLength)) {
      return false;
    }
    if (knownTotal == null) {
      return false;
    }
    return validator != null ||
        (expectedSha256?.isNotEmpty ?? false) ||
        _isImmutableRevision(source.url);
  }

  int? get knownTotal => totalBytes ?? expectedSizeBytes;

  _DownloadProvenance withRepresentation({
    required _HttpRepresentationValidator? validator,
    required int? totalBytes,
  }) {
    return _DownloadProvenance(
      sourceCacheKey: sourceCacheKey,
      expectedSha256: expectedSha256,
      expectedSizeBytes: expectedSizeBytes,
      validator: validator,
      totalBytes: totalBytes,
    );
  }

  static bool _isImmutableRevision(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) {
      return false;
    }
    final segments = uri.pathSegments;
    final resolveIndex = segments.indexOf('resolve');
    if (resolveIndex < 0 || resolveIndex + 1 >= segments.length) {
      return false;
    }
    return RegExp(r'^[0-9a-fA-F]{40,64}$').hasMatch(segments[resolveIndex + 1]);
  }

  Map<String, Object?> toJson() => {
    'sourceCacheKey': sourceCacheKey,
    'expectedSha256': expectedSha256,
    'expectedSizeBytes': expectedSizeBytes,
    'validator': validator?.toJson(),
    'totalBytes': totalBytes,
  };
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
