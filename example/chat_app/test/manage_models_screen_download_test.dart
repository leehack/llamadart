import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart_chat_example/models/downloadable_model.dart';
import 'package:llamadart_chat_example/providers/chat_provider.dart';
import 'package:llamadart_chat_example/screens/manage_models_screen.dart';
import 'package:llamadart_chat_example/services/model_service_base.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'mocks.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ManageModelsScreen model download controller wiring', () {
    testWidgets('pause button cancels the active controller download', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final model = _remoteModel();
      final modelService = _HoldingModelService();

      await _pumpScreen(tester, modelService: modelService, models: [model]);

      expect(find.text(model.name), findsOneWidget);
      expect(find.text('Download'), findsOneWidget);

      await tester.tap(find.text('Download'));
      await modelService.downloadStarted.future.timeout(_testTimeout);
      await tester.pump();

      expect(modelService.downloadCalls, 1);
      expect(find.text('Downloading model'), findsOneWidget);
      expect(find.text('25%'), findsOneWidget);

      await tester.tap(find.byTooltip('Pause Download'));
      await tester.pump(const Duration(milliseconds: 150));
      await modelService.downloadCancelled.future.timeout(_testTimeout);
      await tester.pump();

      expect(modelService.lastCancelToken?.isCancelled, isTrue);
      expect(find.text('Paused'), findsOneWidget);
      expect(find.text('25%'), findsOneWidget);
      expect(find.text('Resume Download'), findsOneWidget);
    });

    testWidgets('cancel and discard reports a paused cancellation', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final model = _remoteModel();
      final modelService = _HoldingModelService();

      await _pumpScreen(tester, modelService: modelService, models: [model]);

      await tester.tap(find.text('Download'));
      await modelService.downloadStarted.future.timeout(_testTimeout);
      await tester.pump();

      await tester.tap(find.byTooltip('Cancel & Discard'));
      await tester.pump(const Duration(milliseconds: 150));
      await modelService.downloadCancelled.future.timeout(_testTimeout);
      await tester.pump();

      expect(modelService.lastCancelToken?.isCancelled, isTrue);
      expect(find.text('Download paused: ${model.name}'), findsOneWidget);
      expect(find.text('Download failed. Please retry.'), findsNothing);
    });

    testWidgets('disposing the screen cancels active controller downloads', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final modelService = _HoldingModelService();

      await _pumpScreen(
        tester,
        modelService: modelService,
        models: [_remoteModel()],
      );

      await tester.tap(find.text('Download'));
      await modelService.downloadStarted.future.timeout(_testTimeout);
      await tester.pump();

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 150));
      await modelService.downloadCancelled.future.timeout(_testTimeout);

      expect(modelService.lastCancelToken?.isCancelled, isTrue);
    });
  });
}

const _testTimeout = Duration(seconds: 2);

Future<void> _pumpScreen(
  WidgetTester tester, {
  required _HoldingModelService modelService,
  required List<DownloadableModel> models,
}) async {
  final provider = ChatProvider(
    chatService: MockChatService(),
    settingsService: MockSettingsService(),
  );
  addTearDown(provider.dispose);

  await tester.pumpWidget(
    ChangeNotifierProvider<ChatProvider>.value(
      value: provider,
      child: MaterialApp(
        home: Scaffold(
          body: ManageModelsScreen(
            embeddedPanel: true,
            modelService: modelService,
            initialModels: models,
            showModelLibraryInitially: true,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

DownloadableModel _remoteModel() {
  return const DownloadableModel(
    name: 'Tiny Test Model',
    description: 'Small fake model for screen tests.',
    url: 'https://example.com/tiny.gguf',
    filename: 'tiny.gguf',
    sizeBytes: 10,
  );
}

class _HoldingModelService implements ModelService {
  final Completer<void> downloadStarted = Completer<void>();
  final Completer<void> downloadCancelled = Completer<void>();

  int downloadCalls = 0;
  CancelToken? lastCancelToken;

  @override
  Future<String> getModelsDirectory() async => '/models';

  @override
  Future<Set<String>> getDownloadedModels(
    List<DownloadableModel> models,
  ) async {
    return <String>{};
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
    lastCancelToken = cancelToken;
    onProgress(0.25);
    onProgressDetail?.call(
      ModelDownloadProgress(
        overallProgress: 0.25,
        downloadedBytes: 25,
        totalBytes: 100,
        stage: ModelDownloadStage.model,
        stageIndex: 1,
        stageCount: 1,
        stageDownloadedBytes: 25,
        stageTotalBytes: 100,
      ),
    );
    if (!downloadStarted.isCompleted) {
      downloadStarted.complete();
    }

    while (!cancelToken.isCancelled) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    if (!downloadCancelled.isCompleted) {
      downloadCancelled.complete();
    }
    onError(
      DioException(
        requestOptions: RequestOptions(path: model.url),
        type: DioExceptionType.cancel,
        message: 'Download cancelled.',
      ),
    );
  }

  @override
  Future<void> deleteModel(String modelsDir, DownloadableModel model) async {}
}
