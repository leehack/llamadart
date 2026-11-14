import 'dart:async';
import 'dart:io';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:test/test.dart';

void main() {
  for (final localPrimary in <bool>[false, true]) {
    test(
      'managed download cancellation and HTTP failure recover on retry (local=$localPrimary)',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'studio_edge_cache_',
        );
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final firstChunk = Completer<void>();
        final release = Completer<void>();
        var mode = 'slow';
        final bytes = List<int>.generate(128 * 1024, (int i) => i % 251);
        final requests = <Future<void>>[];
        final sub = server.listen((HttpRequest request) {
          requests.add(() async {
            try {
              if (mode == 'failed') {
                request.response.statusCode = HttpStatus.notFound;
                await request.response.close();
                return;
              }
              request.response.contentLength = bytes.length;
              request.response.add(bytes.sublist(0, 4096));
              await request.response.flush();
              if (!firstChunk.isCompleted) firstChunk.complete();
              if (mode == 'slow') await release.future;
              request.response.add(bytes.sublist(4096));
              await request.response.close();
            } on IOException {
              // Cancellation may close the server response before its last write.
            }
          }());
        });
        final adapter = DefaultStudioModelStorageAdapter(
          downloadManager: DefaultModelDownloadManager(
            defaultCacheDirectory: root.path,
          ),
          localScanner: LocalModelScanner(defaultRoots: <String>[root.path]),
        );
        final progress = <StudioModelDownloadProgress>[];
        final progressSub = adapter.progressStream.listen(progress.add);
        addTearDown(() async {
          if (!release.isCompleted) release.complete();
          await adapter.dispose();
          await progressSub.cancel();
          await server.close(force: true);
          await sub.cancel();
          await Future.wait(requests);
          await root.delete(recursive: true);
        });
        final remote = 'http://127.0.0.1:${server.port}/fixture.gguf';
        final local = await File('${root.path}/local.gguf').writeAsBytes(bytes);
        final descriptor = StudioModelDescriptor(
          id: 'acceptance_model',
          name: 'Acceptance model',
          description: 'Tiny fixture',
          category: StudioModelCategory.chat,
          filename: 'fixture.gguf',
          sourceUri: localPrimary ? local.path : remote,
          companions: localPrimary
              ? <StudioModelCompanionAsset>[
                  StudioModelCompanionAsset(
                    role: 'projector',
                    filename: 'fixture.gguf',
                    sourceUri: remote,
                  ),
                ]
              : const <StudioModelCompanionAsset>[],
          sizeBytes: bytes.length,
        );
        final downloading = adapter.ensureDownloaded(descriptor, isWeb: false);
        final cancelled = expectLater(
          downloading,
          throwsA(isA<LlamaException>()),
        );
        await firstChunk.future;
        adapter.cancelDownload(descriptor.id);
        release.complete();
        await cancelled;
        await Future<void>.delayed(Duration.zero);
        expect(progress.last.stage, ModelDownloadTaskStage.cancelled);
        expect(await adapter.isCached(descriptor, isWeb: false), isFalse);
        mode = 'failed';
        await expectLater(
          adapter.ensureDownloaded(descriptor, isWeb: false),
          throwsA(isA<LlamaException>()),
        );
        await Future<void>.delayed(Duration.zero);
        expect(progress.last.stage, ModelDownloadTaskStage.failed);
        expect(await adapter.isCached(descriptor, isWeb: false), isFalse);
        mode = 'ready';
        final result = await adapter.ensureDownloaded(descriptor, isWeb: false);
        await Future<void>.delayed(Duration.zero);
        final resultPath = localPrimary
            ? result.companionSources['projector']!.path!
            : result.primarySource.path!;
        expect(await File(resultPath).readAsBytes(), bytes);
        expect(progress.last.stage, ModelDownloadTaskStage.ready);
        expect(await adapter.isCached(descriptor, isWeb: false), isTrue);
      },
    );
  }
}
