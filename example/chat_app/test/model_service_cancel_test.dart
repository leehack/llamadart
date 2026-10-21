@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart_chat_example/models/downloadable_model.dart';
import 'package:llamadart_chat_example/services/model_service_io.dart';
import 'package:path/path.dart' as p;

// Mock ModelService to override getModelsDirectory
class TestModelService extends ModelServiceIO {
  final Directory testDir;

  TestModelService(this.testDir);

  @override
  Future<String> getModelsDirectory() async {
    return testDir.path;
  }
}

void main() {
  late HttpServer server;
  late Directory tempDir;
  late TestModelService service;

  setUp(() async {
    // Start local server
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest request) async {
      // Simple infinite stream for testing cancellation
      if (request.uri.path == '/large_model.bin') {
        if (request.method == 'HEAD') {
          request.response.headers.contentLength = 1024 * 1024 * 5; // 5MB
          request.response.statusCode = HttpStatus.ok;
          await request.response.close();
        } else if (request.method == 'GET') {
          request.response.headers.contentLength = 1024 * 1024 * 5;
          request.response.statusCode = HttpStatus.ok;
          // Send data slowly
          // We use a periodic timer to push data
          final controller = StreamController<List<int>>();
          int sent = 0;
          Timer.periodic(const Duration(milliseconds: 10), (timer) {
            if (sent >= 1024 * 1024 * 5) {
              timer.cancel();
              controller.close();
              return;
            }
            if (controller.isClosed) {
              timer.cancel();
              return;
            }
            const chunkSize = 1024; // 1KB
            controller.add(List.filled(chunkSize, 0));
            sent += chunkSize;
          });

          await request.response.addStream(controller.stream);
          await request.response.close();
        }
      } else {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      }
    });

    tempDir = await Directory.systemTemp.createTemp(
      'model_service_cancel_test',
    );
    service = TestModelService(tempDir);
  });

  tearDown(() async {
    await server.close(force: true);
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'Download cancellation stops download and preserves partial file',
    () async {
      final modelUrl =
          'http://${server.address.address}:${server.port}/large_model.bin';
      final model = DownloadableModel(
        name: 'Test Model',
        filename: 'large_model.bin',
        url: modelUrl,
        description: 'Test',
        sizeBytes: 1024 * 1024 * 5,
      );

      final cancelToken = CancelToken();

      // Future to wait for some progress before cancelling
      final progressCompleter = Completer<void>();

      final downloadFuture = service.downloadModel(
        model: model,
        modelsDir: tempDir.path,
        cancelToken: cancelToken,
        onProgress: (progress) {
          if (progress > 0.05 && !progressCompleter.isCompleted) {
            progressCompleter.complete();
          }
        },
        onSuccess: (_) {
          fail('Download should have been cancelled');
        },
        onError: (e) {
          if (e is DioException && e.type == DioExceptionType.cancel) {
            // This is now expected as we want to update the UI
            return;
          }
          fail('Should not call onError for other failures: $e');
        },
      );

      // Wait for some progress
      await progressCompleter.future;

      // Cancel the download
      cancelToken.cancel();

      // Wait for the download future to complete
      await downloadFuture;

      // Verify partial temp file exists and final file has not been promoted.
      final partialFile = File(
        p.join(tempDir.path, 'large_model.bin.download'),
      );
      final file = File(p.join(tempDir.path, 'large_model.bin'));
      expect(partialFile.existsSync(), isTrue);
      expect(partialFile.lengthSync(), greaterThan(0));
      expect(file.existsSync(), isFalse);
    },
  );
}
