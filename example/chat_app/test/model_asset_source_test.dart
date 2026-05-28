import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart_chat_example/models/downloadable_model.dart';

void main() {
  group('Model asset sources', () {
    test('remote model and local mmproj remain independent assets', () {
      final profile = DownloadableModel.fromSources(
        name: 'Mixed VLM',
        description: 'Remote model with local projector',
        modelSource: RemoteModelAssetSource(
          url: 'https://example.com/model.gguf?download=true',
          filename: 'model.gguf',
          sizeBytes: 1024,
        ),
        multimodalProjectorSource: LocalModelAssetSource(
          '/models/custom-mmproj.gguf',
        ),
        supportsVision: true,
        sizeBytes: 1024,
      );

      expect(profile.modelSource, isA<RemoteModelAssetSource>());
      expect(profile.multimodalProjectorSource, isA<LocalModelAssetSource>());
      expect(profile.url, 'https://example.com/model.gguf?download=true');
      expect(profile.filename, 'model.gguf');
      expect(profile.mmprojUrl, isNull);
      expect(profile.mmprojFilename, 'custom-mmproj.gguf');
      expect(
        profile.modelSource.cacheKey,
        isNot(profile.multimodalProjectorSource!.cacheKey),
      );
    });

    test('remote cache keys keep full URL identity without storing tokens', () {
      const first = RemoteModelAssetSource(
        url: 'https://example.com/model.gguf?token=secret-one',
        filename: 'model.gguf',
      );
      const second = RemoteModelAssetSource(
        url: 'https://example.com/model.gguf?token=secret-two',
        filename: 'model.gguf',
      );

      expect(first.cacheKey, isNot(second.cacheKey));
      expect(first.cacheKey, hasLength(64));
      expect(first.cacheKey, isNot(contains('secret-one')));
      expect(first.cacheKey, isNot(contains('model.gguf')));
    });

    test(
      'remote canonical keys are unambiguous when values contain delimiters',
      () {
        const first = RemoteModelAssetSource(
          url: 'https://example.com/model.gguf',
          filename: 'projector#v1.gguf',
        );
        const second = RemoteModelAssetSource(
          url: 'https://example.com/model.gguf#projector',
          filename: 'v1.gguf',
        );

        expect(first.canonicalKey, isNot(second.canonicalKey));
        expect(first.cacheKey, isNot(second.cacheKey));
      },
    );

    test('legacy constructor maps model and projector to remote sources', () {
      final profile = DownloadableModel(
        name: 'Remote VLM',
        description: 'Remote model and projector',
        url: 'https://example.com/model.gguf',
        filename: 'model.gguf',
        mmprojUrl: 'https://cdn.example.net/mmproj.gguf',
        mmprojFilename: 'mmproj.gguf',
        sizeBytes: 2048,
        supportsVision: true,
      );

      expect(profile.modelSource, isA<RemoteModelAssetSource>());
      expect(profile.multimodalProjectorSource, isA<RemoteModelAssetSource>());
      expect(profile.url, 'https://example.com/model.gguf');
      expect(profile.mmprojUrl, 'https://cdn.example.net/mmproj.gguf');
      expect(profile.mmprojFilename, 'mmproj.gguf');
    });

    test('platform-specific web source can differ from native source', () {
      final profile = DownloadableModel.fromSources(
        id: 'litert-gemma',
        name: 'Gemma LiteRT',
        description: 'Platform-specific LiteRT-LM model',
        modelSource: const RemoteModelAssetSource(
          url: 'https://example.com/gemma-native.litertlm?download=true',
          filename: 'gemma-native.litertlm',
          sizeBytes: 2588147712,
        ),
        webModelSource: const RemoteModelAssetSource(
          url: 'https://example.com/gemma-web.litertlm?download=true',
          filename: 'gemma-web.litertlm',
          sizeBytes: 2008432640,
        ),
        sizeBytes: 2588147712,
        webSizeBytes: 2008432640,
      );

      expect(profile.filename, 'gemma-native.litertlm');
      expect(
        profile.modelSourceFor(web: false).loadReference,
        'https://example.com/gemma-native.litertlm?download=true',
      );
      expect(
        profile.modelSourceFor(web: true).loadReference,
        'https://example.com/gemma-web.litertlm?download=true',
      );
      expect(profile.filenameFor(web: false), 'gemma-native.litertlm');
      expect(profile.filenameFor(web: true), 'gemma-web.litertlm');
      expect(profile.sizeBytesFor(web: false), 2588147712);
      expect(profile.sizeBytesFor(web: true), 2008432640);
    });
  });
}
