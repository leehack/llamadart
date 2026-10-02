import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/core/speech/speech_model_loader.dart';
import 'package:test/test.dart';

void main() {
  group('resolveSpeechModelFiles', () {
    test('resolves files in order and combines their progress', () async {
      final manager = _FakeDownloadManager();
      final progress = <ModelDownloadProgress>[];
      final download = ModelLoadOptions(cacheDirectory: '/models');

      final paths = await resolveSpeechModelFiles(
        engineName: 'SpeechToTextEngine',
        sources: [
          ModelSource.parse('https://example.com/model.tflite'),
          ModelSource.parse('https://example.com/tokenizer.json'),
        ],
        download: download,
        onProgress: progress.add,
        store: ModelFileStore(downloadManager: manager),
        assetType: 'speech model',
      );

      expect(paths, ['/cache/model.tflite', '/cache/tokenizer.json']);
      expect(manager.options, everyElement(same(download)));
      expect(
        [for (final p in progress) (p.receivedBytes, p.totalBytes)],
        [(50, null), (100, null), (150, 200), (200, 200)],
      );
    });

    test('gives local files only the cancel token', () async {
      final manager = _FakeDownloadManager();
      final token = ModelDownloadCancelToken();

      await resolveSpeechModelFiles(
        engineName: 'SpeechToTextEngine',
        sources: [ModelSource.path('/models/model.tflite')],
        download: ModelLoadOptions(cacheDirectory: '/x', cancelToken: token),
        onProgress: null,
        store: ModelFileStore(downloadManager: manager),
        assetType: 'speech model',
      );

      expect(manager.options.single.cacheDirectory, isNull);
      expect(manager.options.single.cancelToken, same(token));
    });

    test('stops after a file when the load is cancelled', () async {
      final token = ModelDownloadCancelToken();
      final manager = _FakeDownloadManager(onEnsure: token.cancel);

      await expectLater(
        resolveSpeechModelFiles(
          engineName: 'SpeechToTextEngine',
          sources: [
            ModelSource.parse('https://example.com/model.tflite'),
            ModelSource.parse('https://example.com/tokenizer.json'),
          ],
          download: ModelLoadOptions(cancelToken: token),
          onProgress: null,
          store: ModelFileStore(downloadManager: manager),
          assetType: 'speech model',
        ),
        throwsA(
          isA<LlamaStateException>().having(
            (error) => error.message,
            'message',
            'SpeechToTextEngine model loading was cancelled.',
          ),
        ),
      );
      expect(manager.options, hasLength(1));
    });

    test('rejects one checksum for several files', () async {
      await expectLater(
        resolveSpeechModelFiles(
          engineName: 'SpeechToTextEngine',
          sources: [
            ModelSource.parse('https://example.com/model.tflite'),
            ModelSource.parse('https://example.com/tokenizer.json'),
          ],
          download: ModelLoadOptions(sha256: 'a' * 64),
          onProgress: null,
          store: ModelFileStore(downloadManager: _FakeDownloadManager()),
          assetType: 'speech model',
        ),
        throwsA(
          isA<LlamaUnsupportedException>().having(
            (error) => error.message,
            'message',
            startsWith('SpeechToTextEngine.load loads 2 files'),
          ),
        ),
      );
    });
  });

  group('SpeechFilesProgress', () {
    test('reports fraction-only progress as a fraction of all files', () {
      final progress = <ModelDownloadProgress>[];
      final files = SpeechFilesProgress(progress.add, fileCount: 2);

      files.file(1)!(const ModelDownloadProgress.fraction(0.5));

      expect(progress.single.fraction, 0.75);
    });

    test('keeps the total unknown while an earlier size is unknown', () {
      final progress = <ModelDownloadProgress>[];
      final files = SpeechFilesProgress(progress.add, fileCount: 2);

      files.file(1)!(
        const ModelDownloadProgress(receivedBytes: 4, totalBytes: 8),
      );

      expect(progress.single.receivedBytes, 4);
      expect(progress.single.totalBytes, isNull);
    });

    test('passes one file through unchanged', () {
      final progress = <ModelDownloadProgress>[];
      final files = SpeechFilesProgress(progress.add, fileCount: 1);

      files.file(0)!(
        const ModelDownloadProgress(receivedBytes: 3, totalBytes: 9),
      );

      expect(progress.single.receivedBytes, 3);
      expect(progress.single.totalBytes, 9);
    });

    test('does nothing without a callback', () {
      final files = SpeechFilesProgress(null, fileCount: 2);

      expect(files.file(0), isNull);
      files.resolved(0, 10);
    });
  });

  test('rejectMultiFileSha256 allows a checksum for one file', () {
    rejectMultiFileSha256(
      'TextToSpeechEngine',
      ModelLoadOptions(sha256: 'a' * 64),
      fileCount: 1,
    );
    expect(
      () => rejectMultiFileSha256(
        'TextToSpeechEngine',
        ModelLoadOptions(sha256: 'a' * 64),
        fileCount: 2,
      ),
      throwsA(isA<LlamaUnsupportedException>()),
    );
  });
}

class _FakeDownloadManager implements ModelDownloadManager {
  final void Function()? onEnsure;
  final List<ModelLoadOptions> options = <ModelLoadOptions>[];

  _FakeDownloadManager({this.onEnsure});

  @override
  Future<ModelCacheEntry> ensureModel(
    ModelSource source, {
    ModelLoadOptions options = ModelLoadOptions.defaults,
    ModelDownloadProgressCallback? onProgress,
  }) async {
    this.options.add(options);
    onEnsure?.call();
    onProgress?.call(
      const ModelDownloadProgress(receivedBytes: 50, totalBytes: 100),
    );
    final fileName = source.fileName;
    final now = DateTime.utc(2026);
    return ModelCacheEntry(
      sourceCanonicalKey: fileName,
      cacheKey: fileName,
      fileName: fileName,
      filePath: '/cache/$fileName',
      createdAt: now,
      updatedAt: now,
      bytes: 100,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
