@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:llamadart/llamadart.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'engine_test.dart' show MockLlamaBackend;

void main() {
  late Directory directory;
  late ModelFileStore store;
  late MockLlamaBackend backend;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('llamadart_set_model_');
    store = ModelFileStore(
      downloadManager: DefaultModelDownloadManager.appPrivate(
        cacheDirectory: p.join(directory.path, 'cache'),
      ),
    );
    backend = MockLlamaBackend();
  });

  tearDown(() => directory.delete(recursive: true));

  File local(String name) =>
      File(p.join(directory.path, name))..writeAsBytesSync([1, 2, 3]);

  test('load reads a local file whose name holds %2F, and a directory named '
      '%2e, from its path', () async {
    final escapedName = local('a%2Fb.gguf');
    await Directory(p.join(directory.path, '%2e')).create();
    final escapedDirectory = local(p.join('%2e', 'mmproj.gguf'));

    final engine = await LlamaEngine.load(
      LlamaModel(
        ModelSource.path(escapedName.path),
        projector: ModelSource.path(escapedDirectory.path),
      ),
      store: store,
      backend: backend,
    );

    expect(backend.lastModelPath, p.normalize(p.absolute(escapedName.path)));
    expect(
      backend.lastMultimodalProjectorPath,
      p.normalize(p.absolute(escapedDirectory.path)),
    );
    await engine.dispose();
  });

  test('a local file that is missing or fails its checksum throws before the '
      'loaded model is replaced', () async {
    final first = local('first.gguf');
    final second = local('second.gguf');
    final engine = await LlamaEngine.load(
      LlamaModel(ModelSource.path(first.path)),
      store: store,
      backend: backend,
    );

    await expectLater(
      engine.setModel(
        LlamaModel(ModelSource.path(p.join(directory.path, 'missing.gguf'))),
      ),
      throwsA(
        isA<LlamaModelException>().having(
          (error) => error.message,
          'message',
          contains('Local model file does not exist'),
        ),
      ),
    );
    await expectLater(
      engine.setModel(
        LlamaModel(ModelSource.path(second.path)),
        download: ModelLoadOptions(sha256: '0' * 64),
      ),
      throwsA(
        isA<LlamaModelException>().having(
          (error) => error.message,
          'message',
          contains('Checksum mismatch for local model file'),
        ),
      ),
    );

    expect(backend.modelLoadCalls, 1);
    expect(backend.modelFreeCalls, 0);
    expect(engine.isReady, isTrue);

    await engine.setModel(
      LlamaModel(ModelSource.path(second.path)),
      download: ModelLoadOptions(
        sha256:
            '039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81',
      ),
    );
    expect(backend.lastModelPath, p.normalize(p.absolute(second.path)));
    await engine.dispose();
  });

  group('with a download in progress', () {
    late HttpServer server;
    late Completer<void> firstChunkSent;
    late Completer<void> finish;

    setUp(() async {
      firstChunkSent = Completer<void>();
      finish = Completer<void>();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final response = request.response
          ..statusCode = HttpStatus.ok
          ..bufferOutput = false
          ..headers.contentLength = 8;
        try {
          response.add(const [1, 2, 3, 4]);
          await response.flush();
          if (!firstChunkSent.isCompleted) firstChunkSent.complete();
          await finish.future;
          response.add(const [5, 6, 7, 8]);
          await response.close();
        } on Object {
          // The client stopped reading.
        }
      });
    });

    tearDown(() async {
      if (!finish.isCompleted) finish.complete();
      await server.close(force: true);
    });

    ModelSource remote() =>
        ModelSource.url(Uri.parse('http://127.0.0.1:${server.port}/big.gguf'));

    List<String> cachedModels() => [
      for (final file in directory.listSync(recursive: true).whereType<File>())
        if (p.basename(file.path) == 'big.gguf') file.path,
    ];

    test('dispose stops the download: load throws, nothing loads and no '
        'file is cached', () async {
      final engine = LlamaEngine(
        backend,
        modelDownloadManager: store.downloadManager,
      );
      final loading = engine.setModel(LlamaModel(remote()));
      final outcome = expectLater(
        loading,
        throwsA(
          isA<LlamaStateException>().having(
            (error) => error.message,
            'message',
            contains('disposed while loading'),
          ),
        ),
      );
      await firstChunkSent.future;

      await engine.dispose();
      await outcome;
      finish.complete();
      await pumpEventQueue(times: 50);

      expect(backend.modelLoadCalls, 0);
      expect(backend.disposeCalls, 1);
      expect(engine.isReady, isFalse);
      expect(cachedModels(), isEmpty);
    });

    test("the caller's cancel token stops the download and the loaded model "
        'stays', () async {
      final first = local('first.gguf');
      final engine = await LlamaEngine.load(
        LlamaModel(ModelSource.path(first.path)),
        store: store,
        backend: backend,
      );
      final token = ModelDownloadCancelToken();

      final replacing = engine.setModel(
        LlamaModel(remote()),
        download: ModelLoadOptions(cancelToken: token),
      );
      final outcome = expectLater(
        replacing,
        throwsA(isA<LlamaStateException>()),
      );
      await firstChunkSent.future;
      token.cancel();
      finish.complete();
      await outcome;

      expect(backend.modelLoadCalls, 1);
      expect(backend.modelFreeCalls, 0);
      expect(engine.isReady, isTrue);
      expect(cachedModels(), isEmpty);
      await engine.dispose();
    });

    test('the download completes and replaces the loaded model', () async {
      final first = local('first.gguf');
      final engine = await LlamaEngine.load(
        LlamaModel(ModelSource.path(first.path)),
        store: store,
        backend: backend,
      );
      final progress = <ModelDownloadProgress>[];

      final replacing = engine.setModel(
        LlamaModel(remote()),
        onProgress: progress.add,
      );
      await firstChunkSent.future;
      expect(engine.isReady, isTrue);
      expect(backend.modelFreeCalls, 0);
      finish.complete();
      await replacing;

      expect(backend.modelFreeCalls, 1);
      expect(backend.lastModelPath, cachedModels().single);
      expect(progress.last.receivedBytes, 8);
      expect(progress.last.totalBytes, 8);
      await engine.dispose();
    });
  });
}
