import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart_chat_example/models/downloadable_model.dart';
import 'package:llamadart_chat_example/services/model_service_base.dart';
import 'package:llamadart_chat_example/services/model_service_io.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tempDir;
  late HttpServer server;
  late String baseUrl;
  late ModelService service;
  late List<int> testData;
  late List<int> mmprojData;
  late Map<String, int> getRequestCountByPath;
  late List<String?> modelRangeHeaders;
  late List<String?> modelIfRangeHeaders;
  late int transientModelFailuresRemaining;
  late int truncatedModelResponsesRemaining;
  late int chunkedModelResponsesRemaining;

  const stableEtag = '"model-v1"';

  const int testDataSize = 1024 * 1024 * 5; // 5 MB
  const int mmprojDataSize = 1024 * 1024 * 2; // 2 MB

  setUp(() async {
    // Generate random test data
    testData = List.generate(testDataSize, (i) => i % 256);
    mmprojData = List.generate(mmprojDataSize, (i) => (i * 7) % 256);
    getRequestCountByPath = <String, int>{};
    modelRangeHeaders = <String?>[];
    modelIfRangeHeaders = <String?>[];
    transientModelFailuresRemaining = 0;
    truncatedModelResponsesRemaining = 0;
    chunkedModelResponsesRemaining = 0;
    tempDir = await Directory.systemTemp.createTemp('model_service_test');
    service = TestModelService(tempDir);

    // Start local server
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    baseUrl = 'http://${server.address.address}:${server.port}';

    server.listen((HttpRequest request) async {
      final path = request.uri.path;
      if (path == '/model.gguf' || path == '/mmproj.gguf') {
        final payload = path == '/model.gguf' ? testData : mmprojData;
        final payloadSize = payload.length;
        request.response.headers.set(HttpHeaders.etagHeader, stableEtag);

        if (request.method == 'HEAD') {
          request.response.headers.contentLength = payloadSize;
          request.response.statusCode = HttpStatus.ok;
          await request.response.close();
        } else if (request.method == 'GET') {
          getRequestCountByPath[path] = (getRequestCountByPath[path] ?? 0) + 1;
          final rangeHeader = request.headers.value('range');
          if (path == '/model.gguf') {
            modelRangeHeaders.add(rangeHeader);
            modelIfRangeHeaders.add(request.headers.value('if-range'));
          }
          if (path == '/model.gguf' && transientModelFailuresRemaining > 0) {
            transientModelFailuresRemaining--;
            request.response.statusCode = HttpStatus.serviceUnavailable;
            await request.response.close();
            return;
          }
          int start = 0;
          int end = payloadSize - 1;
          var isPartial = false;

          if (rangeHeader != null) {
            final match = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(rangeHeader);
            if (match != null) {
              start = int.parse(match.group(1)!);
              final endToken = match.group(2);
              if (endToken != null && endToken.isNotEmpty) {
                end = int.parse(endToken);
              }
              isPartial = true;
            }
          }

          if (start >= payloadSize) {
            request.response.statusCode =
                HttpStatus.requestedRangeNotSatisfiable;
            await request.response.close();
            return;
          }

          if (path == '/model.gguf' &&
              !isPartial &&
              truncatedModelResponsesRemaining > 0) {
            truncatedModelResponsesRemaining--;
            request.response.statusCode = HttpStatus.ok;
            request.response.headers.chunkedTransferEncoding = true;
            request.response.add(payload.sublist(0, payloadSize ~/ 3));
            await request.response.close();
            return;
          }

          if (path == '/model.gguf' &&
              !isPartial &&
              chunkedModelResponsesRemaining > 0) {
            chunkedModelResponsesRemaining--;
            request.response.statusCode = HttpStatus.ok;
            request.response.headers.chunkedTransferEncoding = true;
            request.response.add(payload);
            await request.response.close();
            return;
          }

          request.response.headers.contentLength = end - start + 1;
          if (isPartial) {
            request.response.headers.set(
              'Content-Range',
              'bytes $start-$end/$payloadSize',
            );
            request.response.statusCode = HttpStatus.partialContent;
          } else {
            request.response.statusCode = HttpStatus.ok;
          }

          // Stream the data
          final stream = Stream.fromIterable([payload.sublist(start, end + 1)]);
          await request.response.addStream(stream);
          await request.response.close();
        } else {
          request.response.statusCode = HttpStatus.methodNotAllowed;
          await request.response.close();
        }
      } else {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      }
    });
  });

  tearDown(() async {
    await server.close(force: true);
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('Full download works correctly', () async {
    final model = DownloadableModel(
      name: 'Test Model',
      description: 'Test',
      url: '$baseUrl/model.gguf',
      filename: 'model.gguf',
      sizeBytes: testDataSize,
    );

    await service.downloadModel(
      model: model,
      modelsDir: tempDir.path,
      cancelToken: CancelToken(),
      onProgress: (p) {},
      onSuccess: (path) {},
      onError: (e) => fail('Download failed: $e'),
    );

    final file = File(p.join(tempDir.path, 'model.gguf'));
    expect(file.existsSync(), isTrue);
    expect(file.lengthSync(), testDataSize);
    expect(file.readAsBytesSync(), testData);
  });

  test('transient server failure retries automatically', () async {
    transientModelFailuresRemaining = 1;
    service = TestModelService(
      tempDir,
      retryDelays: const <Duration>[Duration.zero],
    );
    final model = DownloadableModel(
      name: 'Retry Model',
      description: 'Test',
      url: '$baseUrl/model.gguf',
      filename: 'retry-model.gguf',
      sizeBytes: testDataSize,
    );

    await service.downloadModel(
      model: model,
      modelsDir: tempDir.path,
      cancelToken: CancelToken(),
      onProgress: (_) {},
      onSuccess: (_) {},
      onError: (error) => fail('Automatic retry failed: $error'),
    );

    expect(getRequestCountByPath['/model.gguf'], 2);
    expect(
      File(p.join(tempDir.path, model.filename)).readAsBytesSync(),
      testData,
    );
  });

  test('transient server failures stop after configured retries', () async {
    transientModelFailuresRemaining = 10;
    service = TestModelService(
      tempDir,
      retryDelays: const <Duration>[Duration.zero, Duration.zero],
    );
    final model = DownloadableModel(
      name: 'Retry Exhaustion Model',
      description: 'Test',
      url: '$baseUrl/model.gguf',
      filename: 'retry-exhaustion-model.gguf',
      sizeBytes: testDataSize,
    );
    Object? failure;

    await service.downloadModel(
      model: model,
      modelsDir: tempDir.path,
      cancelToken: CancelToken(),
      onProgress: (_) {},
      onSuccess: (_) => fail('Exhausted retry unexpectedly completed.'),
      onError: (error) => failure = error,
    );

    expect(failure, isA<DioException>());
    expect((failure! as DioException).response?.statusCode, 503);
    expect(getRequestCountByPath['/model.gguf'], 3);
    expect(File(p.join(tempDir.path, model.filename)).existsSync(), isFalse);
  });

  test(
    'unknown-size chunked response completes without false truncation',
    () async {
      chunkedModelResponsesRemaining = 1;
      final model = DownloadableModel(
        name: 'Unknown Size Model',
        description: 'Test',
        url: '$baseUrl/model.gguf',
        filename: 'unknown-size-model.gguf',
        sizeBytes: 0,
      );

      await service.downloadModel(
        model: model,
        modelsDir: tempDir.path,
        cancelToken: CancelToken(),
        onProgress: (_) {},
        onSuccess: (_) {},
        onError: (error) => fail('Chunked download failed: $error'),
      );

      expect(getRequestCountByPath['/model.gguf'], 1);
      expect(
        File(p.join(tempDir.path, model.filename)).readAsBytesSync(),
        testData,
      );
    },
  );

  test('cancellation interrupts transient retry backoff', () async {
    transientModelFailuresRemaining = 10;
    service = TestModelService(
      tempDir,
      retryDelays: const <Duration>[Duration(seconds: 30)],
    );
    final model = DownloadableModel(
      name: 'Cancelled Retry Model',
      description: 'Test',
      url: '$baseUrl/model.gguf',
      filename: 'cancelled-retry-model.gguf',
      sizeBytes: testDataSize,
    );
    final cancelToken = CancelToken();
    Object? failure;

    final download = service.downloadModel(
      model: model,
      modelsDir: tempDir.path,
      cancelToken: cancelToken,
      onProgress: (_) {},
      onSuccess: (_) => fail('Cancelled retry unexpectedly completed.'),
      onError: (error) => failure = error,
    );
    while ((getRequestCountByPath['/model.gguf'] ?? 0) == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    cancelToken.cancel('test cancellation');
    await download.timeout(const Duration(seconds: 1));

    expect(failure, isA<DioException>());
    expect((failure! as DioException).type, DioExceptionType.cancel);
    expect(getRequestCountByPath['/model.gguf'], 1);
  });

  test(
    'truncated stream keeps its partial and resumes automatically',
    () async {
      truncatedModelResponsesRemaining = 1;
      service = TestModelService(
        tempDir,
        retryDelays: const <Duration>[Duration.zero],
      );
      final model = DownloadableModel(
        name: 'Truncated Model',
        description: 'Test',
        url: '$baseUrl/model.gguf',
        filename: 'truncated-model.gguf',
        sizeBytes: testDataSize,
      );

      await service.downloadModel(
        model: model,
        modelsDir: tempDir.path,
        cancelToken: CancelToken(),
        onProgress: (_) {},
        onSuccess: (_) {},
        onError: (error) => fail('Truncated-stream retry failed: $error'),
      );

      expect(getRequestCountByPath['/model.gguf'], 2);
      expect(modelRangeHeaders.first, isNull);
      expect(modelRangeHeaders.last, startsWith('bytes='));
      expect(modelIfRangeHeaders.last, stableEtag);
      expect(
        File(p.join(tempDir.path, model.filename)).readAsBytesSync(),
        testData,
      );
      expect(
        File(p.join(tempDir.path, '${model.filename}.download')).existsSync(),
        isFalse,
      );
    },
  );

  test('verified remote download enforces the catalog SHA-256', () async {
    final model = DownloadableModel.fromSources(
      name: 'Verified model',
      description: 'Test',
      modelSource: RemoteModelAssetSource(
        url: '$baseUrl/model.gguf',
        filename: 'verified-model.gguf',
        sizeBytes: testDataSize,
        sha256: sha256.convert(testData).toString(),
      ),
      sizeBytes: testDataSize,
    );

    Object? failure;
    await service.downloadModel(
      model: model,
      modelsDir: tempDir.path,
      cancelToken: CancelToken(),
      onProgress: (_) {},
      onSuccess: (_) {},
      onError: (error) => failure = error,
    );

    expect(failure, isNull);
    expect((await service.getModelCacheState(model)).isReady, isTrue);
  });

  test('cancellation interrupts integrity verification', () async {
    final verificationStarted = Completer<void>();
    service = TestModelService(
      tempDir,
      fileSha256: (file, cancelToken) async {
        if (!verificationStarted.isCompleted) {
          verificationStarted.complete();
        }
        await cancelToken!.whenCancel;
        return sha256.convert(await file.readAsBytes()).toString();
      },
    );
    final model = DownloadableModel.fromSources(
      name: 'Cancelled Verification Model',
      description: 'Test',
      modelSource: RemoteModelAssetSource(
        url: '$baseUrl/model.gguf',
        filename: 'cancelled-verification-model.gguf',
        sizeBytes: testDataSize,
        sha256: sha256.convert(testData).toString(),
      ),
      sizeBytes: testDataSize,
    );
    final cancelToken = CancelToken();
    Object? failure;

    final download = service.downloadModel(
      model: model,
      modelsDir: tempDir.path,
      cancelToken: cancelToken,
      onProgress: (_) {},
      onSuccess: (_) => fail('Cancelled verification unexpectedly completed.'),
      onError: (error) => failure = error,
    );
    await verificationStarted.future.timeout(const Duration(seconds: 2));
    cancelToken.cancel('test verification cancellation');
    await download.timeout(const Duration(seconds: 1));

    expect(failure, isA<DioException>());
    expect((failure! as DioException).type, DioExceptionType.cancel);
    expect(
      File(p.join(tempDir.path, model.filename)).readAsBytesSync(),
      testData,
    );

    final resumedService = TestModelService(tempDir);
    await resumedService.downloadModel(
      model: model,
      modelsDir: tempDir.path,
      cancelToken: CancelToken(),
      onProgress: (_) {},
      onSuccess: (_) {},
      onError: (error) => fail('Verification resume failed: $error'),
    );
    expect(getRequestCountByPath['/model.gguf'], 1);
  });

  test(
    'persisted integrity stamp avoids rehashing unchanged catalog assets',
    () async {
      final source = RemoteModelAssetSource(
        url: '$baseUrl/model.gguf?revision=one',
        filename: 'persisted-verification.gguf',
        sizeBytes: testDataSize,
        sha256: sha256.convert(testData).toString(),
      );
      final model = DownloadableModel.fromSources(
        name: 'Persisted verification',
        description: 'Test',
        modelSource: source,
        sizeBytes: testDataSize,
      );
      final file = File(p.join(tempDir.path, source.filename));
      await file.writeAsBytes(testData);

      var digestCalls = 0;
      Future<String> countDigest(File input, CancelToken? cancelToken) async {
        digestCalls += 1;
        return (await sha256.bind(input.openRead()).first).toString();
      }

      final first = TestModelService(tempDir, fileSha256: countDigest);
      expect((await first.getModelCacheState(model)).isReady, isTrue);
      expect(digestCalls, 1);

      final restarted = TestModelService(tempDir, fileSha256: countDigest);
      expect((await restarted.getModelCacheState(model)).isReady, isTrue);
      expect(digestCalls, 1);

      final revisedSource = RemoteModelAssetSource(
        url: '$baseUrl/model.gguf?revision=two',
        filename: source.filename,
        sizeBytes: source.sizeBytes,
        sha256: source.sha256,
      );
      final revisedModel = DownloadableModel.fromSources(
        name: model.name,
        description: model.description,
        modelSource: revisedSource,
        sizeBytes: model.sizeBytes,
      );
      final revisedService = TestModelService(tempDir, fileSha256: countDigest);
      expect(
        (await revisedService.getModelCacheState(revisedModel)).isReady,
        isTrue,
      );
      expect(digestCalls, 2);

      final corrupted = List<int>.from(testData)..[0] ^= 0xff;
      await file.writeAsBytes(corrupted);
      await file.setLastModified(
        DateTime.now().add(const Duration(seconds: 2)),
      );
      final changedService = TestModelService(tempDir, fileSha256: countDigest);
      expect(
        (await changedService.getModelCacheState(revisedModel)).isReady,
        isFalse,
      );
      expect(digestCalls, 3);
    },
  );

  test('failed catalog checksum discards the downloaded asset', () async {
    final model = DownloadableModel.fromSources(
      name: 'Invalid verified model',
      description: 'Test',
      modelSource: RemoteModelAssetSource(
        url: '$baseUrl/model.gguf',
        filename: 'invalid-verified-model.gguf',
        sizeBytes: testDataSize,
        sha256: List<String>.filled(64, '0').join(),
      ),
      sizeBytes: testDataSize,
    );

    Object? failure;
    await service.downloadModel(
      model: model,
      modelsDir: tempDir.path,
      cancelToken: CancelToken(),
      onProgress: (_) {},
      onSuccess: (_) {},
      onError: (error) => failure = error,
    );

    expect(failure, isA<StateError>());
    expect(
      File(p.join(tempDir.path, 'invalid-verified-model.gguf')).existsSync(),
      isFalse,
    );
  });

  test('Multimodal download reports staged combined progress', () async {
    final model = DownloadableModel(
      name: 'Test VLM',
      description: 'Test',
      url: '$baseUrl/model.gguf',
      filename: 'vlm-model.gguf',
      mmprojUrl: '$baseUrl/mmproj.gguf',
      mmprojFilename: 'vlm-mmproj.gguf',
      sizeBytes: testDataSize + mmprojDataSize,
      supportsVision: true,
    );

    final updates = <ModelDownloadProgress>[];

    await service.downloadModel(
      model: model,
      modelsDir: tempDir.path,
      cancelToken: CancelToken(),
      onProgress: (_) {},
      onProgressDetail: updates.add,
      onSuccess: (_) {},
      onError: (e) => fail('Download failed: $e'),
    );

    final modelFile = File(p.join(tempDir.path, 'vlm-model.gguf'));
    final mmprojFile = File(p.join(tempDir.path, 'vlm-mmproj.gguf'));
    expect(modelFile.existsSync(), isTrue);
    expect(mmprojFile.existsSync(), isTrue);
    expect(modelFile.lengthSync(), testDataSize);
    expect(mmprojFile.lengthSync(), mmprojDataSize);

    expect(updates, isNotEmpty);
    expect(updates.any((u) => u.stage == ModelDownloadStage.model), isTrue);
    expect(
      updates.any((u) => u.stage == ModelDownloadStage.multimodalProjector),
      isTrue,
    );
    expect(updates.last.stageCount, 2);
    expect(updates.last.overallProgress, closeTo(1.0, 0.0001));
  });

  test(
    'Multimodal download skips cached model when mmproj is missing',
    () async {
      final model = DownloadableModel(
        name: 'Partially cached VLM',
        description: 'Test',
        url: '$baseUrl/model.gguf',
        filename: 'cached-vlm-model.gguf',
        mmprojUrl: '$baseUrl/mmproj.gguf',
        mmprojFilename: 'cached-vlm-mmproj.gguf',
        sizeBytes: testDataSize + mmprojDataSize,
        supportsVision: true,
      );
      await File(p.join(tempDir.path, model.filename)).writeAsBytes(testData);

      final before = await service.getModelCacheState(model);
      expect(before.model.isAvailable, isTrue);
      expect(before.multimodalProjector?.isAvailable, isFalse);
      expect(before.hasPartialAssets, isTrue);

      final updates = <ModelDownloadProgress>[];

      await service.downloadModel(
        model: model,
        modelsDir: tempDir.path,
        cancelToken: CancelToken(),
        onProgress: (_) {},
        onProgressDetail: updates.add,
        onSuccess: (_) {},
        onError: (e) => fail('Download failed: $e'),
      );

      expect(getRequestCountByPath['/model.gguf'] ?? 0, 0);
      expect(getRequestCountByPath['/mmproj.gguf'] ?? 0, 1);
      expect(
        updates.where((u) => u.stage == ModelDownloadStage.model),
        isEmpty,
      );
      expect(
        updates.every(
          (u) =>
              u.stage == ModelDownloadStage.multimodalProjector &&
              u.stageIndex == 1 &&
              u.stageCount == 1,
        ),
        isTrue,
      );

      final after = await service.getModelCacheState(model);
      expect(after.isReady, isTrue);
      expect(
        await service.getDownloadedModels([model]),
        contains(model.filename),
      );
    },
  );

  test(
    'Local model with remote mmproj reports a single projector stage',
    () async {
      final localModel = File(p.join(tempDir.path, 'local-model.gguf'));
      await localModel.writeAsBytes(testData);
      final model = DownloadableModel.fromSources(
        name: 'Local model remote projector',
        description: 'Test',
        modelSource: LocalModelAssetSource(localModel.path),
        multimodalProjectorSource: RemoteModelAssetSource(
          url: '$baseUrl/mmproj.gguf',
          filename: 'remote-mmproj.gguf',
          sizeBytes: mmprojDataSize,
        ),
        supportsVision: true,
      );

      final updates = <ModelDownloadProgress>[];

      await service.downloadModel(
        model: model,
        modelsDir: tempDir.path,
        cancelToken: CancelToken(),
        onProgress: (_) {},
        onProgressDetail: updates.add,
        onSuccess: (_) {},
        onError: (e) => fail('Download failed: $e'),
      );

      expect(
        updates.where((u) => u.stage == ModelDownloadStage.model),
        isEmpty,
      );
      final projectorUpdates = updates
          .where((u) => u.stage == ModelDownloadStage.multimodalProjector)
          .toList();
      expect(projectorUpdates, isNotEmpty);
      expect(projectorUpdates.every((u) => u.stageIndex == 1), isTrue);
      expect(projectorUpdates.every((u) => u.stageCount == 1), isTrue);
      expect(updates.last.overallProgress, closeTo(1.0, 0.0001));
    },
  );

  test('Resume functionality works', () async {
    final model = DownloadableModel(
      name: 'Test Model',
      description: 'Test',
      url: '$baseUrl/model.gguf',
      filename: 'model.gguf',
      sizeBytes: testDataSize, // 5MB
    );

    // 1. Start download but cancel it halfway
    // We simulate this by throwing an error inside onProgress or interrupting
    // Since we can't easily interrupt the Future from outside without cancellation token support (which we didn't implement fully exposed),
    // we will rely on a trick: we will close the server or similar? No, ModelService catches errors.
    // Actually, we can hack the service to accept a cancellation token or just rely on the fact that if we throw in onProgress, it might propagate?
    // Wait, onProgress is a callback. If we throw there, `_downloadFileParallel` calls `onProgress`. It might not catch it if it's sync.
    // Let's modify ModelService to panic in onProgress if we want to simulate crash.

    bool simulatedCrash = false;
    try {
      await service.downloadModel(
        model: model,
        modelsDir: tempDir.path,
        cancelToken: CancelToken(),
        onProgress: (val) {
          if (val > 0.3 && !simulatedCrash) {
            simulatedCrash = true;
            throw Exception("Simulated Crash");
          }
        },
        onSuccess: (_) {},
        onError: (e) {
          // Expected to fail here
        },
      );
    } catch (_) {}

    // Verify partial state uses the temp file.
    final file = File(p.join(tempDir.path, 'model.gguf'));
    final tempFile = File(p.join(tempDir.path, 'model.gguf.download'));
    final provenanceFile = File(
      p.join(tempDir.path, 'model.gguf.download.source.json'),
    );

    expect(tempFile.existsSync(), isTrue);
    expect(tempFile.lengthSync(), greaterThan(0));
    expect(provenanceFile.existsSync(), isTrue);
    expect(simulatedCrash, isTrue);

    // 2. Resume download
    await service.downloadModel(
      model: model,
      modelsDir: tempDir.path,
      cancelToken: CancelToken(),
      onProgress: (p) {},
      onSuccess: (path) {},
      onError: (e) => fail('Resume failed: $e'),
    );

    // Verify final state
    expect(file.existsSync(), isTrue);
    expect(file.lengthSync(), testDataSize);
    expect(file.readAsBytesSync(), testData);
    expect(tempFile.existsSync(), isFalse); // Should be cleaned up
    expect(provenanceFile.existsSync(), isFalse);
    expect(modelRangeHeaders.whereType<String>(), isNotEmpty);
    expect(modelIfRangeHeaders.whereType<String>(), contains(stableEtag));
  });

  test('resume rejects a partial created for a different source', () async {
    final oldModel = DownloadableModel(
      name: 'Old source',
      description: 'Test',
      url: '$baseUrl/model.gguf?revision=old',
      filename: 'revision-bound.gguf',
      sizeBytes: testDataSize,
    );

    var simulatedCrash = false;
    await service.downloadModel(
      model: oldModel,
      modelsDir: tempDir.path,
      cancelToken: CancelToken(),
      onProgress: (progress) {
        if (progress > 0.3 && !simulatedCrash) {
          simulatedCrash = true;
          throw Exception('Simulated crash');
        }
      },
      onSuccess: (_) {},
      onError: (_) {},
    );

    final tempFile = File(p.join(tempDir.path, 'revision-bound.gguf.download'));
    final provenanceFile = File(
      p.join(tempDir.path, 'revision-bound.gguf.download.source.json'),
    );
    expect(simulatedCrash, isTrue);
    expect(tempFile.existsSync(), isTrue);
    expect(provenanceFile.existsSync(), isTrue);

    final newModel = DownloadableModel(
      name: 'New source',
      description: 'Test',
      url: '$baseUrl/model.gguf?revision=new',
      filename: oldModel.filename,
      sizeBytes: testDataSize,
    );
    await service.downloadModel(
      model: newModel,
      modelsDir: tempDir.path,
      cancelToken: CancelToken(),
      onProgress: (_) {},
      onSuccess: (_) {},
      onError: (error) => fail('Fresh download failed: $error'),
    );

    expect(modelRangeHeaders.last, isNull);
    expect(
      File(p.join(tempDir.path, newModel.filename)).readAsBytesSync(),
      testData,
    );
    expect(tempFile.existsSync(), isFalse);
    expect(provenanceFile.existsSync(), isFalse);
  });

  test(
    'same URL changed ETag restarts instead of mixing representations',
    () async {
      final mutableData = List<int>.generate(64 * 1024, (i) => i % 251);
      final replacementData = List<int>.generate(
        mutableData.length,
        (i) => (i * 17) % 251,
      );
      var currentData = mutableData;
      var currentEtag = '"mutable-v1"';
      final rangeHeaders = <String?>[];
      final ifRangeHeaders = <String?>[];
      final mutableServer = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => mutableServer.close(force: true));
      mutableServer.listen((request) async {
        final range = request.headers.value(HttpHeaders.rangeHeader);
        final ifRange = request.headers.value('if-range');
        rangeHeaders.add(range);
        ifRangeHeaders.add(ifRange);
        request.response.headers.set(HttpHeaders.etagHeader, currentEtag);

        var start = 0;
        final validatorMatches = ifRange == null || ifRange == currentEtag;
        if (range != null && validatorMatches) {
          start = int.parse(
            RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!,
          );
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-${currentData.length - 1}/${currentData.length}',
          );
        } else {
          request.response.statusCode = HttpStatus.ok;
        }
        request.response.headers.contentLength = currentData.length - start;
        await request.response.addStream(
          Stream<List<int>>.fromIterable([currentData.sublist(start)]),
        );
        await request.response.close();
      });
      final mutableUrl =
          'http://${mutableServer.address.address}:${mutableServer.port}/model.gguf';
      final model = DownloadableModel(
        name: 'Mutable model',
        description: 'Test',
        url: mutableUrl,
        filename: 'same-url-changed-etag.gguf',
        sizeBytes: mutableData.length,
      );

      var crashed = false;
      await service.downloadModel(
        model: model,
        modelsDir: tempDir.path,
        cancelToken: CancelToken(),
        onProgress: (progress) {
          if (progress > 0.25 && !crashed) {
            crashed = true;
            throw Exception('Simulated crash');
          }
        },
        onSuccess: (_) {},
        onError: (_) {},
      );
      expect(crashed, isTrue);

      currentData = replacementData;
      currentEtag = '"mutable-v2"';
      await service.downloadModel(
        model: model,
        modelsDir: tempDir.path,
        cancelToken: CancelToken(),
        onProgress: (_) {},
        onSuccess: (_) {},
        onError: (error) => fail('Replacement download failed: $error'),
      );

      expect(rangeHeaders.whereType<String>(), isNotEmpty);
      expect(ifRangeHeaders.whereType<String>(), contains('"mutable-v1"'));
      expect(
        File(p.join(tempDir.path, model.filename)).readAsBytesSync(),
        replacementData,
      );
    },
  );

  test(
    'mutable source without validator restarts without a Range request',
    () async {
      final unsafeData = List<int>.generate(32 * 1024, (i) => i % 239);
      final rangeHeaders = <String?>[];
      final unsafeServer = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => unsafeServer.close(force: true));
      unsafeServer.listen((request) async {
        rangeHeaders.add(request.headers.value(HttpHeaders.rangeHeader));
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentLength = unsafeData.length;
        await request.response.addStream(
          Stream<List<int>>.fromIterable([unsafeData]),
        );
        await request.response.close();
      });
      final unsafeUrl =
          'http://${unsafeServer.address.address}:${unsafeServer.port}/model.gguf';
      final model = DownloadableModel(
        name: 'Unsafe mutable model',
        description: 'Test',
        url: unsafeUrl,
        filename: 'unsafe-mutable.gguf',
        sizeBytes: unsafeData.length,
      );

      var crashed = false;
      await service.downloadModel(
        model: model,
        modelsDir: tempDir.path,
        cancelToken: CancelToken(),
        onProgress: (progress) {
          if (progress > 0.25 && !crashed) {
            crashed = true;
            throw Exception('Simulated crash');
          }
        },
        onSuccess: (_) {},
        onError: (_) {},
      );
      await service.downloadModel(
        model: model,
        modelsDir: tempDir.path,
        cancelToken: CancelToken(),
        onProgress: (_) {},
        onSuccess: (_) {},
        onError: (error) => fail('Restart failed: $error'),
      );

      expect(rangeHeaders.whereType<String>(), isEmpty);
      expect(
        File(p.join(tempDir.path, model.filename)).readAsBytesSync(),
        unsafeData,
      );
    },
  );

  test('unsafe 416 never promotes an arbitrary partial', () async {
    final fullData = List<int>.generate(16 * 1024, (i) => i % 227);
    var requestCount = 0;
    final rangeHeaders = <String?>[];
    final rangeServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => rangeServer.close(force: true));
    rangeServer.listen((request) async {
      requestCount += 1;
      final range = request.headers.value(HttpHeaders.rangeHeader);
      rangeHeaders.add(range);
      if (range != null && requestCount == 1) {
        request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes */${fullData.length}',
        );
        await request.response.close();
        return;
      }
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentLength = fullData.length;
      await request.response.addStream(
        Stream<List<int>>.fromIterable([fullData]),
      );
      await request.response.close();
    });
    final revision = List<String>.filled(40, 'a').join();
    final rangeUrl =
        'http://${rangeServer.address.address}:${rangeServer.port}/resolve/$revision/model.gguf';
    final model = DownloadableModel(
      name: 'Unsafe 416 model',
      description: 'Test',
      url: rangeUrl,
      filename: 'unsafe-416.gguf',
      sizeBytes: fullData.length,
    );
    final partial = File(p.join(tempDir.path, '${model.filename}.download'));
    await partial.writeAsBytes(List<int>.filled(fullData.length, 0x7f));
    final source = model.modelSource as RemoteModelAssetSource;
    await File(
      p.join(tempDir.path, '${model.filename}.download.source.json'),
    ).writeAsString(
      jsonEncode({
        'version': 2,
        'sourceCacheKey': source.cacheKey,
        'expectedSha256': null,
        'expectedSizeBytes': fullData.length,
        'validator': null,
        'totalBytes': fullData.length,
      }),
    );

    await service.downloadModel(
      model: model,
      modelsDir: tempDir.path,
      cancelToken: CancelToken(),
      onProgress: (_) {},
      onSuccess: (_) {},
      onError: (error) => fail('416 recovery failed: $error'),
    );

    expect(rangeHeaders.first, isNotNull);
    expect(rangeHeaders.last, isNull);
    expect(
      File(p.join(tempDir.path, model.filename)).readAsBytesSync(),
      fullData,
    );
  });

  test('Remote model can depend on local mmproj availability', () async {
    final localMmproj = File(p.join(tempDir.path, 'local-mmproj.gguf'));
    final model = DownloadableModel.fromSources(
      name: 'Mixed Source VLM',
      description: 'Test',
      modelSource: RemoteModelAssetSource(
        url: '$baseUrl/model.gguf',
        filename: 'mixed-model.gguf',
        sizeBytes: testDataSize,
      ),
      multimodalProjectorSource: LocalModelAssetSource(localMmproj.path),
      sizeBytes: testDataSize,
      supportsVision: true,
    );

    await File(p.join(tempDir.path, 'mixed-model.gguf')).writeAsBytes(testData);

    var downloaded = await service.getDownloadedModels([model]);
    expect(downloaded, isNot(contains(model.filename)));

    await localMmproj.writeAsBytes(mmprojData);
    downloaded = await service.getDownloadedModels([model]);
    expect(downloaded, contains(model.filename));

    await service.deleteModel(tempDir.path, model);
    expect(
      File(p.join(tempDir.path, 'mixed-model.gguf')).existsSync(),
      isFalse,
    );
    expect(localMmproj.existsSync(), isTrue);
  });

  test('Incomplete download is not marked as downloaded', () async {
    final model = DownloadableModel(
      name: 'Existing Model',
      description: 'Test',
      url: '$baseUrl/model.gguf',
      filename: 'existing.gguf',
      sizeBytes: testDataSize,
    );

    // Create fake complete file with legacy/incomplete markers.
    final file = File(p.join(tempDir.path, 'existing.gguf'));
    final meta = File(p.join(tempDir.path, 'existing.gguf.meta'));
    final tempFile = File(p.join(tempDir.path, 'existing.gguf.download'));
    await file.create();
    await file.writeAsBytes(testData); // Full size
    await meta.create(); // Legacy partial marker
    await tempFile.writeAsBytes(
      testData.sublist(0, 1024),
    ); // Active partial marker

    var downloaded = await service.getDownloadedModels([model]);
    expect(downloaded, isNot(contains(model.filename)));

    // An unbound legacy partial is discarded rather than resumed.
    expect(tempFile.existsSync(), isFalse);
    await meta.delete();
    downloaded = await service.getDownloadedModels([model]);
    expect(downloaded, contains(model.filename));
  });
}

class TestModelService extends ModelServiceIO {
  final Directory testDir;
  TestModelService(this.testDir, {super.fileSha256, super.retryDelays});

  @override
  Future<String> getModelsDirectory() async {
    return testDir.path;
  }
}
