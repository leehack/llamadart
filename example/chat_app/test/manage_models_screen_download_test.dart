import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart_chat_example/models/downloadable_model.dart';
import 'package:llamadart_chat_example/providers/chat_provider.dart';
import 'package:llamadart_chat_example/screens/manage_models_screen.dart';
import 'package:llamadart_chat_example/services/model_download_ui_controller.dart';
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
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
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
        expect(find.textContaining('Keep the app open'), findsOneWidget);

        await tester.tap(find.byTooltip('Pause Download'));
        await tester.pump(const Duration(milliseconds: 150));
        await modelService.downloadCancelled.future.timeout(_testTimeout);
        await tester.pump();

        expect(modelService.lastCancelToken?.isCancelled, isTrue);
        expect(find.text('Paused'), findsOneWidget);
        expect(find.text('25%'), findsOneWidget);
        expect(find.text('Resume Download'), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets(
      'mobile lifecycle pause does not deliberately cancel downloads',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final model = _remoteModel();
        final modelService = _HoldingModelService();

        await _pumpScreen(tester, modelService: modelService, models: [model]);

        await tester.tap(find.text('Download'));
        await modelService.downloadStarted.future.timeout(_testTimeout);
        await tester.pump();

        final state = tester.state(find.byType(ManageModelsScreen)) as dynamic;
        state.didChangeAppLifecycleState(AppLifecycleState.paused);
        await tester.pump(const Duration(milliseconds: 150));

        expect(modelService.lastCancelToken?.isCancelled, isFalse);
        expect(modelService.downloadCancelled.isCompleted, isFalse);
        expect(find.text('Downloading model'), findsOneWidget);
        expect(find.text('25%'), findsOneWidget);

        state.didChangeAppLifecycleState(AppLifecycleState.hidden);
        await tester.pump(const Duration(milliseconds: 150));

        expect(modelService.lastCancelToken?.isCancelled, isFalse);
        expect(modelService.downloadCancelled.isCompleted, isFalse);
        expect(find.text('Downloading model'), findsOneWidget);
        expect(find.text('25%'), findsOneWidget);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 150));
        await modelService.downloadCancelled.future.timeout(_testTimeout);
      },
    );

    testWidgets('mobile download guidance is hidden on desktop platforms', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        SharedPreferences.setMockInitialValues({});
        final model = _remoteModel();
        final modelService = _HoldingModelService();

        await _pumpScreen(tester, modelService: modelService, models: [model]);

        await tester.tap(find.text('Download'));
        await modelService.downloadStarted.future.timeout(_testTimeout);
        await tester.pump();

        expect(find.text('Downloading model'), findsOneWidget);
        expect(find.text('25%'), findsOneWidget);
        expect(find.textContaining('Keep the app open'), findsNothing);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 150));
        await modelService.downloadCancelled.future.timeout(_testTimeout);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
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

    testWidgets(
      'app-owned download continues when the transient screen is replaced',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final model = _remoteModel();
        final modelService = _HoldingModelService();
        final downloadUi = ModelDownloadUiController();
        addTearDown(downloadUi.dispose);

        await _pumpScreen(
          tester,
          modelService: modelService,
          models: [model],
          downloadUiController: downloadUi,
        );

        await tester.tap(find.text('Download'));
        await modelService.downloadStarted.future.timeout(_testTimeout);
        await tester.pump();

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 150));

        expect(modelService.lastCancelToken?.isCancelled, isFalse);
        expect(modelService.downloadCancelled.isCompleted, isFalse);

        await _pumpScreen(
          tester,
          modelService: modelService,
          models: [model],
          downloadUiController: downloadUi,
        );

        expect(find.text('Downloading model'), findsOneWidget);
        expect(find.text('25%'), findsOneWidget);

        String? finishedFilename;
        final finishedSubscription = downloadUi.downloadsFinished.listen(
          (filename) => finishedFilename = filename,
        );
        addTearDown(finishedSubscription.cancel);
        await tester.tap(find.byTooltip('Pause Download'));
        await tester.pump(const Duration(milliseconds: 150));
        await modelService.downloadCancelled.future.timeout(_testTimeout);
        expect(finishedFilename, model.filename);
      },
    );

    testWidgets(
      'replacement screen refreshes when app-owned download completes',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final model = _remoteModel();
        final modelService = _HoldingModelService();
        final downloadUi = ModelDownloadUiController();
        addTearDown(downloadUi.dispose);

        await _pumpScreen(
          tester,
          modelService: modelService,
          models: [model],
          downloadUiController: downloadUi,
        );

        await tester.tap(find.text('Download'));
        await modelService.downloadStarted.future.timeout(_testTimeout);
        await tester.pump();

        await _pumpScreen(
          tester,
          modelService: modelService,
          models: [model],
          downloadUiController: downloadUi,
        );
        expect(find.text('Downloading model'), findsOneWidget);

        String? finishedFilename;
        final finishedSubscription = downloadUi.downloadsFinished.listen(
          (filename) => finishedFilename = filename,
        );
        addTearDown(finishedSubscription.cancel);
        modelService.completeDownload();
        await tester.pump(const Duration(milliseconds: 20));
        await modelService.downloadCompleted.future.timeout(_testTimeout);
        await tester.pump(const Duration(milliseconds: 300));

        expect(finishedFilename, model.filename);
        expect(find.text('Use this model'), findsOneWidget);
        expect(find.text('Downloading model'), findsNothing);
      },
    );

    testWidgets(
      'selection warns when runtime lacks advertised vision support',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final model = _remoteVisionModel();
        final modelService = _HoldingModelService(
          downloadedFiles: {model.filename},
        );
        final provider = ChatProvider(
          chatService: MockChatService(engine: _NoVisionEngine()),
          settingsService: MockSettingsService(),
        );
        addTearDown(provider.dispose);

        await _pumpScreen(
          tester,
          modelService: modelService,
          models: [model],
          provider: provider,
        );

        expect(find.text('Use this model'), findsOneWidget);

        await tester.ensureVisible(find.text('Use this model'));
        await tester.pump();
        await tester.tap(find.text('Use this model'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(
          find.textContaining(
            'active runtime/projector did not report vision support',
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets('delete refreshes other profiles that share cached assets', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final sharedMmproj = const RemoteModelAssetSource(
        url: 'https://example.com/shared-mmproj.gguf',
        filename: 'shared-mmproj.gguf',
      );
      final first = DownloadableModel.fromSources(
        id: 'first-vlm',
        name: 'First VLM',
        description: 'First profile with shared projector.',
        modelSource: const RemoteModelAssetSource(
          url: 'https://example.com/first.gguf',
          filename: 'first.gguf',
        ),
        multimodalProjectorSource: sharedMmproj,
        supportsVision: true,
      );
      final second = DownloadableModel.fromSources(
        id: 'second-vlm',
        name: 'Second VLM',
        description: 'Second profile with shared projector.',
        modelSource: const RemoteModelAssetSource(
          url: 'https://example.com/second.gguf',
          filename: 'second.gguf',
        ),
        multimodalProjectorSource: sharedMmproj,
        supportsVision: true,
      );
      final modelService = _HoldingModelService(
        cachedAssetKeys: {
          (first.modelSource as RemoteModelAssetSource).cacheKey,
          (second.modelSource as RemoteModelAssetSource).cacheKey,
          sharedMmproj.cacheKey,
        },
      );

      await _pumpScreen(
        tester,
        modelService: modelService,
        models: [first, second],
      );

      expect(find.text('First VLM'), findsOneWidget);
      expect(find.text('Second VLM'), findsOneWidget);
      expect(
        find.text(
          'Model cached; mmproj missing. Download will fetch only missing assets.',
        ),
        findsNothing,
      );

      await tester.tap(find.byTooltip('Delete model and mmproj').first);
      await tester.pumpAndSettle();

      expect(modelService.deleteCalls, 1);
      expect(
        find.text(
          'Model cached; mmproj missing. Download will fetch only missing assets.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('signed custom URLs require confirmation before saving', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final modelService = _HoldingModelService();

      await _pumpScreen(tester, modelService: modelService, models: []);

      await tester.tap(find.text('Add GGUF (HF)'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'GGUF URL (Hugging Face)'),
        'https://huggingface.co/owner/repo/resolve/main/model.gguf?token=secret',
      );

      await tester.tap(find.text('Add model'));
      await tester.pumpAndSettle();

      expect(find.text('Save credentialed URL?'), findsOneWidget);
      final warningDialog = find.ancestor(
        of: find.text('Save credentialed URL?'),
        matching: find.byType(AlertDialog),
      );
      expect(
        find.descendant(
          of: warningDialog,
          matching: find.textContaining('token=secret'),
        ),
        findsNothing,
      );

      await tester.tap(find.text('Review URL'));
      await tester.pumpAndSettle();

      var prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('custom_hf_models_v1'), isNull);
      expect(find.text('Add Hugging Face GGUF'), findsOneWidget);

      await tester.tap(find.text('Add model'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save anyway'));
      await tester.pumpAndSettle();

      prefs = await SharedPreferences.getInstance();
      final entries = prefs.getStringList('custom_hf_models_v1');
      expect(entries, hasLength(1));
      final saved = jsonDecode(entries!.single) as Map<String, dynamic>;
      expect(
        saved['url'],
        'https://huggingface.co/owner/repo/resolve/main/model.gguf?token=secret',
      );
      expect(find.text('Added model.gguf'), findsOneWidget);
    });
  });
}

const _testTimeout = Duration(seconds: 2);

Future<void> _pumpScreen(
  WidgetTester tester, {
  required _HoldingModelService modelService,
  required List<DownloadableModel> models,
  ChatProvider? provider,
  ModelDownloadUiController? downloadUiController,
}) async {
  final effectiveProvider =
      provider ??
      ChatProvider(
        chatService: MockChatService(),
        settingsService: MockSettingsService(),
      );
  if (provider == null) {
    addTearDown(effectiveProvider.dispose);
  }

  await tester.pumpWidget(
    ChangeNotifierProvider<ChatProvider>.value(
      value: effectiveProvider,
      child: MaterialApp(
        home: Scaffold(
          body: ManageModelsScreen(
            embeddedPanel: true,
            modelService: modelService,
            initialModels: models,
            showModelLibraryInitially: true,
            downloadUiController: downloadUiController,
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

DownloadableModel _remoteVisionModel() {
  return const DownloadableModel(
    name: 'Tiny Vision Model',
    description: 'Small fake VLM for screen tests.',
    url: 'https://example.com/tiny-vlm.gguf',
    filename: 'tiny-vlm.gguf',
    mmprojUrl: 'https://example.com/tiny-mmproj.gguf',
    mmprojFilename: 'tiny-mmproj.gguf',
    sizeBytes: 20,
    supportsVision: true,
  );
}

class _HoldingModelService implements ModelService {
  _HoldingModelService({
    Set<String>? downloadedFiles,
    Set<String>? cachedAssetKeys,
  }) : downloadedFiles = downloadedFiles ?? <String>{},
       cachedAssetKeys = cachedAssetKeys?.toSet();

  final Completer<void> downloadStarted = Completer<void>();
  final Completer<void> downloadCancelled = Completer<void>();
  final Completer<void> downloadCompleted = Completer<void>();
  final Completer<void> _finishDownload = Completer<void>();
  final Set<String> downloadedFiles;
  final Set<String>? cachedAssetKeys;

  int downloadCalls = 0;
  int deleteCalls = 0;
  CancelToken? lastCancelToken;

  void completeDownload() {
    if (!_finishDownload.isCompleted) {
      _finishDownload.complete();
    }
  }

  @override
  Future<String> getModelsDirectory() async => '/models';

  @override
  Future<Set<String>> getDownloadedModels(
    List<DownloadableModel> models,
  ) async {
    return models.where(_isProfileReady).map((model) => model.filename).toSet();
  }

  @override
  Future<ModelProfileCacheState> getModelCacheState(
    DownloadableModel model,
  ) async {
    final mmprojSource = model.multimodalProjectorSource;
    return ModelProfileCacheState(
      model: ModelAssetCacheState(
        role: ModelAssetRole.model,
        label: model.modelSource.displayName,
        isAvailable: _isAssetAvailable(model, model.modelSource),
      ),
      multimodalProjector: mmprojSource == null
          ? null
          : ModelAssetCacheState(
              role: ModelAssetRole.multimodalProjector,
              label: mmprojSource.displayName,
              isAvailable: _isAssetAvailable(model, mmprojSource),
            ),
    );
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

    while (!cancelToken.isCancelled && !_finishDownload.isCompleted) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    if (_finishDownload.isCompleted && !cancelToken.isCancelled) {
      downloadedFiles.add(model.filename);
      onProgress(1);
      onSuccess(model.filename);
      if (!downloadCompleted.isCompleted) {
        downloadCompleted.complete();
      }
      return;
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
  Future<void> deleteModel(String modelsDir, DownloadableModel model) async {
    deleteCalls += 1;
    final keys = cachedAssetKeys;
    if (keys == null) {
      downloadedFiles.remove(model.filename);
      return;
    }

    for (final source in _remoteSourcesFor(model)) {
      keys.remove(source.cacheKey);
    }
  }

  bool _isProfileReady(DownloadableModel model) {
    final keys = cachedAssetKeys;
    if (keys == null) {
      return downloadedFiles.contains(model.filename);
    }
    final sources = _assetSourcesFor(model);
    return sources.every(
      (source) =>
          source is RemoteModelAssetSource && keys.contains(source.cacheKey),
    );
  }

  bool _isAssetAvailable(DownloadableModel model, ModelAssetSource source) {
    final keys = cachedAssetKeys;
    if (keys == null) {
      return downloadedFiles.contains(model.filename);
    }
    return source is RemoteModelAssetSource && keys.contains(source.cacheKey);
  }

  List<ModelAssetSource> _assetSourcesFor(DownloadableModel model) {
    final mmprojSource = model.multimodalProjectorSource;
    return <ModelAssetSource>[model.modelSource, ?mmprojSource];
  }

  List<RemoteModelAssetSource> _remoteSourcesFor(DownloadableModel model) {
    return _assetSourcesFor(
      model,
    ).whereType<RemoteModelAssetSource>().toList(growable: false);
  }
}

class _NoVisionEngine extends MockLlamaEngine {
  @override
  Future<bool> get supportsVision async => false;

  @override
  Future<bool> get supportsAudio async => false;
}
