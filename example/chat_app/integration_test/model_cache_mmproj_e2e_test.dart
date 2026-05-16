@Tags(['local-only', 'e2e'])
@Timeout(Duration(minutes: 30))
/// Local-only chat app E2E for the model/mmproj download-cache-load path.
///
/// This downloads the default LFM2-VL 450M model and its mmproj, so it is
/// intentionally skipped by default. Run it manually with:
///
/// ```bash
/// cd example/chat_app
/// flutter test --run-skipped -t local-only \
///   integration_test/model_cache_mmproj_e2e_test.dart -d <device>
/// ```
library;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:llamadart/llamadart.dart' show GpuBackend, LlamaLogLevel;
import 'package:path/path.dart' as p;

import 'package:llamadart_chat_example/models/chat_settings.dart';
import 'package:llamadart_chat_example/models/downloadable_model.dart';
import 'package:llamadart_chat_example/services/chat_service.dart';
import 'package:llamadart_chat_example/services/model_service_base.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'downloads, caches, and loads tiny multimodal model + mmproj',
    (tester) async {
      final model = DownloadableModel.defaultModels.firstWhere(
        (candidate) => candidate.name == 'LFM2-VL 450M',
      );
      expect(model.multimodalProjectorSource, isNotNull);

      final service = ModelService();
      final modelsDir = await service.getModelsDirectory();

      await service.deleteModel(modelsDir, model);
      var downloaded = await service.getDownloadedModels([model]);
      expect(downloaded.contains(model.filename), isFalse);

      final stages = <ModelDownloadStage>{};
      final progressEvents = <ModelDownloadProgress>[];
      Object? downloadError;
      String? successFilename;

      await service.downloadModel(
        model: model,
        modelsDir: modelsDir,
        cancelToken: CancelToken(),
        onProgress: (_) {},
        onProgressDetail: (detail) {
          stages.add(detail.stage);
          progressEvents.add(detail);
          debugPrint(
            'E2E download ${detail.stage.name} '
            '${(detail.overallProgress * 100).toStringAsFixed(1)}% '
            '${detail.stageDownloadedBytes}/${detail.stageTotalBytes ?? -1}',
          );
        },
        onSuccess: (filename) {
          successFilename = filename;
        },
        onError: (error) {
          downloadError = error;
        },
      );

      expect(downloadError, isNull);
      expect(successFilename, model.filename);
      expect(stages, contains(ModelDownloadStage.model));
      expect(stages, contains(ModelDownloadStage.multimodalProjector));
      expect(progressEvents.last.overallProgress, 1.0);

      downloaded = await service.getDownloadedModels([model]);
      expect(downloaded, contains(model.filename));

      final modelSource = model.modelSource;
      final mmprojSource = model.multimodalProjectorSource!;
      final modelLoadRef = kIsWeb || modelSource is LocalModelAssetSource
          ? modelSource.loadReference
          : p.join(modelsDir, model.filename);
      final mmprojLoadRef = kIsWeb || mmprojSource is LocalModelAssetSource
          ? mmprojSource.loadReference
          : p.join(modelsDir, mmprojSource.displayName);

      final chatService = ChatService();
      try {
        await chatService.init(
          ChatSettings(
            modelPath: modelLoadRef,
            mmprojPath: mmprojLoadRef,
            preferredBackend: GpuBackend.cpu,
            gpuLayers: 0,
            contextSize: 512,
            maxTokens: 32,
            nativeLogLevel: LlamaLogLevel.warn,
          ),
          eagerLoadMultimodalProjector: true,
          onProgress: (progress) =>
              debugPrint('E2E load ${(progress * 100).toStringAsFixed(1)}%'),
        );

        expect(chatService.engine.isReady, isTrue);
        expect(await chatService.engine.supportsVision, isTrue);
      } finally {
        await chatService.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 30)),
  );
}
