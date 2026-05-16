import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart_chat_example/models/downloadable_model.dart';
import 'package:dio/dio.dart';
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

  const int testDataSize = 1024 * 1024 * 5; // 5 MB
  const int mmprojDataSize = 1024 * 1024 * 2; // 2 MB

  setUp(() async {
    // Generate random test data
    testData = List.generate(testDataSize, (i) => i % 256);
    mmprojData = List.generate(mmprojDataSize, (i) => (i * 7) % 256);
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

        if (request.method == 'HEAD') {
          request.response.headers.contentLength = payloadSize;
          request.response.statusCode = HttpStatus.ok;
          await request.response.close();
        } else if (request.method == 'GET') {
          final rangeHeader = request.headers.value('range');
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

          // Check if client disconnected, though difficult to detect reliably in dart:io instantly
          // We will just stream
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

    expect(tempFile.existsSync(), isTrue);
    expect(tempFile.lengthSync(), greaterThan(0));
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

    // Still incomplete while .download exists.
    await meta.delete();
    downloaded = await service.getDownloadedModels([model]);
    expect(downloaded, isNot(contains(model.filename)));

    // Valid once partial marker is removed.
    await tempFile.delete();
    downloaded = await service.getDownloadedModels([model]);
    expect(downloaded, contains(model.filename));
  });
}

class TestModelService extends ModelServiceIO {
  final Directory testDir;
  TestModelService(this.testDir);

  @override
  Future<String> getModelsDirectory() async {
    return testDir.path;
  }
}
