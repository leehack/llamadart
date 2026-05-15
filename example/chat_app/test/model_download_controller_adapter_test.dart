import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart' as llama;
import 'package:llamadart_chat_example/models/downloadable_model.dart';
import 'package:llamadart_chat_example/services/model_download_controller_adapter.dart';
import 'package:llamadart_chat_example/services/model_service_base.dart';

void main() {
  group('ChatAppModelDownloadManager', () {
    test(
      'returns cached entries without calling the chat app downloader',
      () async {
        final model = _remoteModel();
        final service = _FakeModelService(downloadedFiles: {model.filename});
        final manager = ChatAppModelDownloadManager(
          modelService: service,
          model: model,
          modelsDir: '/models',
        );

        final entry = await manager.ensureModel(manager.source);

        expect(service.downloadCalls, 0);
        expect(service.getDownloadedCalls, 1);
        expect(entry.cacheKey, manager.source.cacheKey);
        expect(entry.fileName, model.filename);
        expect(entry.filePath, '/models/${model.filename}');
      },
    );

    test(
      'rejects checksum options instead of reporting unverified ready',
      () async {
        final model = _remoteModel();
        final service = _FakeModelService(downloadedFiles: {model.filename});
        final manager = ChatAppModelDownloadManager(
          modelService: service,
          model: model,
          modelsDir: '/models',
        );

        await expectLater(
          manager.ensureModel(
            manager.source,
            options: llama.ModelLoadOptions(sha256: 'a' * 64),
          ),
          throwsA(isA<UnsupportedError>()),
        );

        expect(service.downloadCalls, 0);
      },
    );

    test(
      'refresh downloads through the chat app service and forwards progress',
      () async {
        final model = _remoteModel();
        final detail = ModelDownloadProgress(
          overallProgress: 0.5,
          downloadedBytes: 5,
          totalBytes: 10,
          stage: ModelDownloadStage.model,
          stageIndex: 1,
          stageCount: 1,
          stageDownloadedBytes: 5,
          stageTotalBytes: 10,
        );
        final service = _FakeModelService(
          downloadedFiles: {model.filename},
          progressDetails: [detail],
        );
        final appDetails = <ModelDownloadProgress>[];
        final controllerProgress = <llama.ModelDownloadProgress>[];
        final manager = ChatAppModelDownloadManager(
          modelService: service,
          model: model,
          modelsDir: '/models',
          onProgressDetail: appDetails.add,
        );

        final entry = await manager.ensureModel(
          manager.source,
          options: llama.ModelLoadOptions(
            cachePolicy: llama.ModelCachePolicy.refresh,
          ),
          onProgress: controllerProgress.add,
        );

        expect(service.downloadCalls, 1);
        expect(service.lastModel, same(model));
        expect(service.lastModelsDir, '/models');
        expect(service.lastCancelToken, isNotNull);
        expect(appDetails, [same(detail)]);
        expect(controllerProgress.single.fraction, 0.5);
        expect(entry.filePath, '/models/${model.filename}');
      },
    );

    test(
      'bridges controller cancellation into the chat app Dio cancel token',
      () async {
        final model = _remoteModel();
        final service = _FakeModelService(waitForCancellation: true);
        final manager = ChatAppModelDownloadManager(
          modelService: service,
          model: model,
          modelsDir: '/models',
        );
        final controller = llama.ModelDownloadController(manager: manager);
        addTearDown(controller.dispose);

        final task = controller.start(manager.source);
        await service.downloadStarted.future;

        controller.cancel();

        await expectLater(task, throwsA(isA<DioException>()));
        expect(service.lastCancelToken?.isCancelled, isTrue);
        expect(
          controller.snapshot.stage,
          llama.ModelDownloadTaskStage.cancelled,
        );
      },
    );
  });
}

DownloadableModel _remoteModel() {
  return const DownloadableModel(
    name: 'Tiny Test Model',
    description: 'Small fake model for adapter tests.',
    url: 'https://example.com/tiny.gguf?token=secret',
    filename: 'tiny.gguf',
    sizeBytes: 10,
  );
}

class _FakeModelService implements ModelService {
  _FakeModelService({
    Set<String>? downloadedFiles,
    this.progressDetails = const <ModelDownloadProgress>[],
    this.waitForCancellation = false,
  }) : downloadedFiles = downloadedFiles ?? <String>{};

  final Set<String> downloadedFiles;
  final List<ModelDownloadProgress> progressDetails;
  final bool waitForCancellation;
  final Completer<void> downloadStarted = Completer<void>();

  int getDownloadedCalls = 0;
  int downloadCalls = 0;
  DownloadableModel? lastModel;
  String? lastModelsDir;
  CancelToken? lastCancelToken;

  @override
  Future<String> getModelsDirectory() async => '/models';

  @override
  Future<Set<String>> getDownloadedModels(
    List<DownloadableModel> models,
  ) async {
    getDownloadedCalls += 1;
    return models
        .where((model) => downloadedFiles.contains(model.filename))
        .map((model) => model.filename)
        .toSet();
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
    downloadCalls += 1;
    lastModel = model;
    lastModelsDir = modelsDir;
    lastCancelToken = cancelToken;
    if (!downloadStarted.isCompleted) {
      downloadStarted.complete();
    }

    if (waitForCancellation) {
      while (!cancelToken.isCancelled) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      onError(
        DioException(
          requestOptions: RequestOptions(path: model.url),
          type: DioExceptionType.cancel,
          message: 'Download cancelled.',
        ),
      );
      return;
    }

    for (final detail in progressDetails) {
      onProgressDetail?.call(detail);
    }
    downloadedFiles.add(model.filename);
    onSuccess(model.filename);
  }

  @override
  Future<void> deleteModel(String modelsDir, DownloadableModel model) async {
    downloadedFiles.remove(model.filename);
  }
}
