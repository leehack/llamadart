import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:llamadart_chat_example/models/downloadable_model.dart';
import 'package:llamadart_chat_example/models/image_model_profile.dart';
import 'package:llamadart_chat_example/services/image_model_service_io.dart';
import 'package:llamadart_chat_example/services/model_service_io.dart';

void main() {
  const modelsDir = '/cache/models';
  late FakeManagedAssets assets;
  late IoImageModelService service;

  setUp(() {
    assets = FakeManagedAssets(modelsDir);
    service = IoImageModelService(modelService: assets);
  });

  group('resolve', () {
    test('returns managed paths when every file is available', () async {
      assets.available.addAll([
        ImageModelProfile.sdTurbo.modelSource.filename,
        ImageModelProfile.sdTurbo.taesdSource!.filename,
      ]);

      final installed = await service.resolve(ImageModelProfile.sdTurbo);

      expect(installed, isNotNull);
      expect(installed!.modelPath, p.join(modelsDir, 'sd_turbo-f16-q8_0.gguf'));
      expect(installed.taesdPath, p.join(modelsDir, 'taesd.safetensors'));
    });

    test('returns null when any file is missing', () async {
      assets.available.add(ImageModelProfile.sdTurbo.modelSource.filename);

      expect(await service.resolve(ImageModelProfile.sdTurbo), isNull);
    });
  });

  group('install', () {
    test('downloads every file and reports combined progress', () async {
      final profile = ImageModelProfile.sdTurbo;
      final progress = <double>[];
      var verifications = 0;

      final installed = await service.install(
        profile,
        cancelToken: CancelToken(),
        onProgress: progress.add,
        onVerifying: () => verifications += 1,
      );

      expect(assets.downloaded, [
        profile.modelSource.filename,
        profile.taesdSource!.filename,
      ]);
      expect(verifications, 2);
      final modelShare = profile.modelSource.sizeBytes! / profile.sizeBytes;
      final taesdShare = profile.taesdSource!.sizeBytes! / profile.sizeBytes;
      expect(progress, [
        closeTo(modelShare / 2, 1e-9),
        closeTo(modelShare, 1e-9),
        closeTo(modelShare + taesdShare / 2, 1e-9),
        closeTo(1, 1e-9),
        1,
      ]);
      expect(installed.taesdPath, p.join(modelsDir, 'taesd.safetensors'));
    });

    test('passes the cancel token to each download', () async {
      final cancelToken = CancelToken();

      await service.install(
        ImageModelProfile.sdTurbo,
        cancelToken: cancelToken,
        onProgress: (_) {},
        onVerifying: () {},
      );

      expect(assets.cancelTokens, hasLength(2));
      expect(assets.cancelTokens, everyElement(same(cancelToken)));
    });

    test('fails when a downloaded file does not verify', () async {
      assets.verifyDownloads = false;

      await expectLater(
        service.install(
          ImageModelProfile.sdxs,
          cancelToken: CancelToken(),
          onProgress: (_) {},
          onVerifying: () {},
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  test('delete removes every managed file of the profile', () async {
    await service.delete(ImageModelProfile.sdTurbo);

    expect(assets.deleted, ['sd_turbo-f16-q8_0.gguf', 'taesd.safetensors']);
    expect(assets.deletedFrom, everyElement(modelsDir));
  });
}

class FakeManagedAssets extends ModelServiceIO {
  final String modelsDir;
  final Set<String> available = <String>{};
  final List<String> downloaded = <String>[];
  final List<CancelToken> cancelTokens = <CancelToken>[];
  final List<String> deleted = <String>[];
  final List<String> deletedFrom = <String>[];
  bool verifyDownloads = true;

  FakeManagedAssets(this.modelsDir);

  @override
  Future<String> getModelsDirectory() async => modelsDir;

  @override
  Future<bool> isManagedAssetAvailable(
    String modelsDir,
    ModelAssetSource source, {
    required ModelAssetRole role,
  }) async => available.contains((source as RemoteModelAssetSource).filename);

  @override
  Future<void> downloadManagedAsset({
    required String modelsDir,
    required RemoteModelAssetSource source,
    required ModelAssetRole role,
    required CancelToken cancelToken,
    required void Function(int downloadedBytes, int? totalBytes, bool resumed)
    onProgress,
    void Function()? onVerifying,
  }) async {
    cancelTokens.add(cancelToken);
    final size = source.sizeBytes!;
    onProgress(size ~/ 2, size, false);
    onProgress(size, size, false);
    onVerifying?.call();
    downloaded.add(source.filename);
    if (verifyDownloads) {
      available.add(source.filename);
    }
  }

  @override
  Future<void> deleteManagedAsset(
    String modelsDir,
    ModelAssetSource source,
  ) async {
    deletedFrom.add(modelsDir);
    deleted.add((source as RemoteModelAssetSource).filename);
  }
}
