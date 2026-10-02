@TestOn('browser')
library;

import 'package:test/test.dart';

import 'package:llamadart/llamadart.dart';

void main() {
  test('the web reports image generation unsupported', () {
    final capabilities = ImageGenerationEngine.runtimeCapabilities();

    expect(capabilities.isSupported, isFalse);
    expect(capabilities.unsupportedReason, contains('web'));
  });

  test('checkRuntime reports the same reason on the web', () async {
    final capabilities = await ImageGenerationEngine.checkRuntime();

    expect(capabilities.isSupported, isFalse);
    expect(
      capabilities.unsupportedReason,
      ImageGenerationEngine.runtimeCapabilities().unsupportedReason,
    );
  });

  test('load throws LlamaUnsupportedException on the web before anything '
      'downloads', () async {
    final downloads = _RecordingDownloads();

    for (final model in [
      ImageGenerationModel(ModelSource.parse('hf://owner/sdxs@main/sdxs.gguf')),
      ImageGenerationModel(
        ModelSource.path('flux.gguf'),
        components: [ImageModelComponent.auto(ModelSource.path('ae.gguf'))],
      ),
    ]) {
      await expectLater(
        ImageGenerationEngine.load(
          model,
          store: ModelFileStore(downloadManager: downloads),
        ),
        throwsA(
          isA<LlamaUnsupportedException>().having(
            (error) => error.message,
            'message',
            contains('not available on the web'),
          ),
        ),
      );
    }
    expect(downloads.requested, isEmpty);
  });
}

final class _RecordingDownloads extends ThrowingModelDownloadManager {
  final List<ModelSource> requested = [];

  @override
  Future<ModelCacheEntry> ensureModel(
    ModelSource source, {
    ModelLoadOptions options = ModelLoadOptions.defaults,
    ModelDownloadProgressCallback? onProgress,
  }) {
    requested.add(source);
    return super.ensureModel(source, options: options, onProgress: onProgress);
  }
}
