import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart_chat_example/models/chat_settings.dart';
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
    testWidgets('focus request reveals and highlights the active model', (
      tester,
    ) async {
      final model = _remoteModel();
      SharedPreferences.setMockInitialValues({});

      await _pumpScreen(
        tester,
        modelService: _HoldingModelService(),
        models: [model],
        showModelLibraryInitially: false,
        focusModelFilename: model.filename,
        focusRequestId: 1,
      );

      expect(find.text('Model library'), findsOneWidget);
      final highlightedCard = find.byKey(
        ValueKey('model-card-highlight-${model.filename}'),
      );
      expect(highlightedCard, findsOneWidget);
      final container = tester.widget<AnimatedContainer>(highlightedCard);
      final decoration = container.decoration! as BoxDecoration;
      expect(decoration.border, isNotNull);
    });

    testWidgets('uncached custom model can be removed from library', (
      tester,
    ) async {
      final model = _remoteModel();
      SharedPreferences.setMockInitialValues({
        'custom_hf_models_v1': [
          jsonEncode({
            'name': model.name,
            'description': model.description,
            'url': model.url,
            'filename': model.filename,
            'sizeBytes': model.sizeBytes,
          }),
        ],
      });

      await _pumpScreen(
        tester,
        modelService: _HoldingModelService(),
        models: const [],
      );

      expect(find.text(model.name), findsOneWidget);
      await tester.tap(find.byTooltip('Model actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove from library'));
      await tester.pumpAndSettle();

      expect(find.text('Remove from library?'), findsOneWidget);
      expect(find.text('Delete files & remove'), findsNothing);
      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      await tester.pumpAndSettle();

      expect(find.text(model.name), findsNothing);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('custom_hf_models_v1'), isEmpty);
    });

    testWidgets('built-in ASR replaces a stale custom entry by filename', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        final asr = DownloadableModel.defaultModels.singleWhere(
          (model) => model.name == 'Qwen3-ASR 0.6B',
        );
        SharedPreferences.setMockInitialValues({
          'custom_hf_models_v1': <String>[
            jsonEncode(<String, Object>{
              'name': 'Old custom ASR',
              'description': 'Temporary entry used before the built-in preset.',
              'url': 'https://example.com/old-asr.gguf',
              'filename': asr.filename,
              'sizeBytes': asr.sizeBytes,
            }),
          ],
        });

        await _pumpScreen(
          tester,
          modelService: _HoldingModelService(
            downloadedFiles: <String>{asr.filename},
          ),
          models: <DownloadableModel>[asr],
        );

        expect(find.text(asr.name), findsOneWidget);
        expect(find.text('Old custom ASR'), findsNothing);
        expect(find.text('Downloaded'), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    for (final platform in <TargetPlatform>[
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.linux,
    ]) {
      testWidgets('Qwen3-ASR is available on native ${platform.name}', (
        tester,
      ) async {
        debugDefaultTargetPlatformOverride = platform;
        try {
          final asr = DownloadableModel.defaultModels.singleWhere(
            (model) => model.name == 'Qwen3-ASR 0.6B',
          );
          SharedPreferences.setMockInitialValues({});

          await _pumpScreen(
            tester,
            modelService: _HoldingModelService(),
            models: <DownloadableModel>[asr],
          );

          expect(find.text(asr.name), findsOneWidget);
          expect(find.text('All platforms'), findsOneWidget);
          expect(find.text('Download Model + Projector'), findsOneWidget);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }

    testWidgets('selected multimodal model waits for models directory', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final directory = Completer<String>();
      final model = _remoteVisionModel();
      final provider = ChatProvider(
        chatService: MockChatService(),
        settingsService: MockSettingsService(),
        initialSettings: ChatSettings(modelPath: '/models/${model.filename}'),
      );
      addTearDown(provider.dispose);

      await _pumpScreen(
        tester,
        modelService: _HoldingModelService(
          modelsDirectoryFuture: directory.future,
        ),
        models: [model],
        provider: provider,
        settle: false,
      );

      expect(tester.takeException(), isNull);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      directory.complete('/models');
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text(model.name), findsOneWidget);
    });

    testWidgets('desktop-only presets are hidden on mobile', (tester) async {
      final mobileModel = _remoteModel();
      const desktopModel = DownloadableModel(
        name: 'Desktop Test Model',
        description: 'Large fake desktop model.',
        url: 'https://example.com/desktop.gguf',
        filename: 'desktop.gguf',
        sizeBytes: 20,
        availability: ModelAvailability.nativeDesktop,
      );

      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        SharedPreferences.setMockInitialValues({});
        await _pumpScreen(
          tester,
          modelService: _HoldingModelService(),
          models: [mobileModel, desktopModel],
        );

        expect(find.text(mobileModel.name), findsOneWidget);
        expect(find.text(desktopModel.name), findsNothing);

        await tester.tap(find.widgetWithText(ChoiceChip, 'Desktop'));
        await tester.pumpAndSettle();
        expect(find.text(desktopModel.name), findsOneWidget);
        expect(find.text('Available on desktop'), findsOneWidget);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
        await _pumpScreen(
          tester,
          modelService: _HoldingModelService(),
          models: [mobileModel, desktopModel],
        );

        expect(find.text(desktopModel.name), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('downloaded models are promoted ahead of catalog order', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final available = _remoteModel();
      final downloaded = _secondRemoteModel();

      await _pumpScreen(
        tester,
        modelService: _HoldingModelService(
          downloadedFiles: {downloaded.filename},
        ),
        models: [available, downloaded],
      );

      expect(find.text('1 downloaded · 2 total'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text(downloaded.name)).dy,
        lessThan(tester.getTopLeft(find.text(available.name)).dy),
      );
      expect(find.text('Downloaded'), findsOneWidget);
    });

    testWidgets('platform and capability search narrow the model library', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        SharedPreferences.setMockInitialValues({});
        final general = _remoteModel();
        final vision = _remoteVisionModel();
        const native = DownloadableModel(
          name: 'Native Specialist',
          description: 'Native-only model.',
          url: 'https://example.com/native.gguf',
          filename: 'native.gguf',
          sizeBytes: 20,
          availability: ModelAvailability.native,
        );
        const desktop = DownloadableModel(
          name: 'Desktop Specialist',
          description: 'Large desktop-only model.',
          url: 'https://example.com/desktop.gguf',
          filename: 'desktop.gguf',
          sizeBytes: 20,
          availability: ModelAvailability.nativeDesktop,
        );

        await _pumpScreen(
          tester,
          modelService: _HoldingModelService(),
          models: [general, vision, native, desktop],
        );

        expect(find.widgetWithText(ChoiceChip, 'All'), findsOneWidget);
        expect(find.widgetWithText(ChoiceChip, 'Mobile'), findsOneWidget);
        expect(find.widgetWithText(ChoiceChip, 'Web'), findsOneWidget);
        expect(find.widgetWithText(ChoiceChip, 'Desktop'), findsOneWidget);
        expect(find.text(native.name), findsOneWidget);
        expect(find.text(desktop.name), findsOneWidget);

        await tester.tap(find.widgetWithText(ChoiceChip, 'Web'));
        await tester.pumpAndSettle();
        expect(find.text(general.name), findsOneWidget);
        expect(find.text(native.name), findsNothing);
        expect(find.text(desktop.name), findsNothing);

        await tester.tap(find.widgetWithText(ChoiceChip, 'Mobile'));
        await tester.pumpAndSettle();
        expect(find.text(native.name), findsOneWidget);
        expect(find.text(desktop.name), findsNothing);

        await tester.tap(find.widgetWithText(ChoiceChip, 'Desktop'));
        await tester.pumpAndSettle();
        expect(find.text(native.name), findsOneWidget);
        expect(find.text(desktop.name), findsOneWidget);

        await tester.tap(find.widgetWithText(ChoiceChip, 'Mobile'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).first, 'vision');
        await tester.pump();
        expect(find.text(vision.name), findsOneWidget);
        expect(find.text(general.name), findsNothing);

        await tester.tap(find.byTooltip('Clear model search'));
        await tester.pump();
        expect(find.text(general.name), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('desktop search uses native capability profile', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      const desktopAudio = DownloadableModel(
        name: 'Desktop Audio Model',
        description: 'Desktop model with native-only audio.',
        url: 'https://example.com/desktop-audio.gguf',
        filename: 'desktop-audio.gguf',
        sizeBytes: 20,
        availability: ModelAvailability.nativeDesktop,
        supportsAudio: true,
        webSupportsAudio: false,
      );
      const desktopAsr = DownloadableModel(
        name: 'Desktop ASR Model',
        description: 'Desktop model with speech recognition.',
        url: 'https://example.com/desktop-asr.gguf',
        filename: 'desktop-asr.gguf',
        sizeBytes: 20,
        availability: ModelAvailability.nativeDesktop,
        supportsAudio: true,
        supportsSpeechToText: true,
      );
      const desktopTts = DownloadableModel(
        name: 'Desktop TTS Model',
        description: 'Desktop model with speech synthesis.',
        url: 'https://example.com/desktop-tts.gguf',
        filename: 'desktop-tts.gguf',
        sizeBytes: 20,
        availability: ModelAvailability.nativeDesktop,
        supportsTextToSpeech: true,
      );

      await _pumpScreen(
        tester,
        modelService: _HoldingModelService(),
        models: const [desktopAudio, desktopAsr, desktopTts],
      );

      await tester.tap(find.widgetWithText(ChoiceChip, 'Desktop'));
      await tester.enterText(find.byType(TextField).first, 'audio');
      await tester.pump();

      expect(find.text(desktopAudio.name), findsOneWidget);

      await tester.enterText(find.byType(TextField).first, 'stt');
      await tester.pump();

      expect(find.text(desktopAsr.name), findsOneWidget);
      expect(find.text(desktopAudio.name), findsNothing);

      await tester.enterText(find.byType(TextField).first, 'speech-to-text');
      await tester.pump();
      expect(find.text(desktopAsr.name), findsOneWidget);

      await tester.enterText(find.byType(TextField).first, 'speech to text');
      await tester.pump();
      expect(find.text(desktopAsr.name), findsOneWidget);

      await tester.enterText(find.byType(TextField).first, 'text-to-speech');
      await tester.pump();
      expect(find.text(desktopTts.name), findsOneWidget);
      expect(find.text(desktopAsr.name), findsNothing);

      await tester.enterText(find.byType(TextField).first, 'tts');
      await tester.pump();
      expect(find.text(desktopTts.name), findsOneWidget);
    });

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

        await _tapVisible(tester, find.text('Download'));
        await modelService.downloadStarted.future.timeout(_testTimeout);
        await tester.pump();

        expect(modelService.downloadCalls, 1);
        expect(find.text('Downloading model'), findsOneWidget);
        expect(find.text('25%'), findsOneWidget);
        expect(find.textContaining('Keep the app open'), findsOneWidget);

        await _tapVisible(tester, find.byTooltip('Pause Download'));
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

        await _tapVisible(tester, find.text('Download'));
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

        await _tapVisible(tester, find.text('Download'));
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

      await _tapVisible(tester, find.text('Download'));
      await modelService.downloadStarted.future.timeout(_testTimeout);
      await tester.pump();

      await _tapVisible(tester, find.byTooltip('Cancel & Discard'));
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

      await _tapVisible(tester, find.text('Download'));
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

        await _tapVisible(tester, find.text('Download'));
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
        await _tapVisible(tester, find.byTooltip('Pause Download'));
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

        await _tapVisible(tester, find.text('Download'));
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
      'anchors and highlights completed model card across download reorder',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final firstModel = _remoteModel();
        final secondModel = _secondRemoteModel();
        final modelService = _HoldingModelService();
        final downloadUi = ModelDownloadUiController();
        addTearDown(downloadUi.dispose);

        await _pumpScreen(
          tester,
          modelService: modelService,
          models: [firstModel, secondModel],
          downloadUiController: downloadUi,
        );

        final downloadButtons = find.widgetWithText(OutlinedButton, 'Download');
        expect(downloadButtons, findsNWidgets(2));

        // Start downloading the second model
        await _tapVisible(tester, downloadButtons.last);
        await modelService.downloadStarted.future.timeout(_testTimeout);
        await tester.pump();

        final highlightedCard = find.byKey(
          ValueKey('model-card-highlight-${secondModel.filename}'),
        );
        final scrollable = tester.state<ScrollableState>(
          find
              .ancestor(of: highlightedCard, matching: find.byType(Scrollable))
              .first,
        );
        final scrollController = scrollable.widget.controller!;
        final currentTop = tester.getTopLeft(highlightedCard).dy;
        scrollController.jumpTo(
          (scrollController.position.pixels + currentTop - 140).clamp(
            scrollController.position.minScrollExtent,
            scrollController.position.maxScrollExtent,
          ),
        );
        await tester.pump();
        final beforeTop = tester.getTopLeft(highlightedCard).dy;

        // Complete the download
        modelService.completeDownload();
        await tester.pump(const Duration(milliseconds: 20));
        await modelService.downloadCompleted.future.timeout(_testTimeout);
        await tester.pumpAndSettle();

        // The second model was reordered to downloaded, and should be highlighted & visible
        expect(highlightedCard, findsOneWidget);
        expect(tester.getTopLeft(highlightedCard).dy, closeTo(beforeTop, 6));
        expect(highlightedCard.hitTestable(), findsOneWidget);
        final container = tester.widget<AnimatedContainer>(highlightedCard);
        final decoration = container.decoration! as BoxDecoration;
        expect(decoration.border, isNotNull);
        expect(find.text(secondModel.name), findsOneWidget);

        await tester.pump(const Duration(seconds: 2));
        await tester.pumpAndSettle();
        final clearedContainer = tester.widget<AnimatedContainer>(
          highlightedCard,
        );
        final clearedDecoration = clearedContainer.decoration! as BoxDecoration;
        expect(clearedDecoration.border, isNull);
      },
    );

    testWidgets('second model waits while first download is active', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final firstModel = _remoteModel();
      final secondModel = _secondRemoteModel();
      final modelService = _HoldingModelService();
      final downloadUi = ModelDownloadUiController();
      addTearDown(downloadUi.dispose);

      await _pumpScreen(
        tester,
        modelService: modelService,
        models: [firstModel, secondModel],
        downloadUiController: downloadUi,
      );

      final downloadButtons = find.widgetWithText(OutlinedButton, 'Download');
      expect(downloadButtons, findsNWidgets(2));
      await _tapVisible(tester, downloadButtons.first);
      await modelService.downloadStarted.future.timeout(_testTimeout);
      await tester.pump();

      final secondDownloadButton = find.widgetWithText(
        OutlinedButton,
        'Download',
      );
      expect(secondDownloadButton, findsOneWidget);
      await tester.ensureVisible(secondDownloadButton);
      await tester.pump();
      await tester.tap(secondDownloadButton);
      await tester.pump(const Duration(milliseconds: 50));

      expect(modelService.downloadCalls, 1);
      final queuedLabel = find.text('Queued for download • Position 1');
      await tester.ensureVisible(queuedLabel);
      await tester.pump();
      expect(queuedLabel, findsOneWidget);

      downloadUi.cancel(secondModel.filename);
      downloadUi.cancel(firstModel.filename);
      await tester.pump(const Duration(milliseconds: 150));
      await modelService.downloadCancelled.future.timeout(_testTimeout);
      for (var i = 0; i < 20 && downloadUi.hasPendingDownloads; i += 1) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(modelService.downloadCalls, 1);
      expect(downloadUi.hasPendingDownloads, isFalse);
    });

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

      await tester.tap(find.widgetWithText(OutlinedButton, 'Add model'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'GGUF URL (Hugging Face)'),
        'https://huggingface.co/owner/repo/resolve/main/model.gguf?token=secret',
      );

      await tester.tap(find.widgetWithText(FilledButton, 'Add model'));
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

      await tester.tap(find.widgetWithText(FilledButton, 'Add model'));
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

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
}

Future<void> _pumpScreen(
  WidgetTester tester, {
  required _HoldingModelService modelService,
  required List<DownloadableModel> models,
  ChatProvider? provider,
  ModelDownloadUiController? downloadUiController,
  bool showModelLibraryInitially = true,
  String? focusModelFilename,
  int focusRequestId = 0,
  bool settle = true,
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
            showModelLibraryInitially: showModelLibraryInitially,
            downloadUiController: downloadUiController,
            focusModelFilename: focusModelFilename,
            focusRequestId: focusRequestId,
          ),
        ),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
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

DownloadableModel _secondRemoteModel() {
  return const DownloadableModel(
    name: 'Second Test Model',
    description: 'Another fake model for queue tests.',
    url: 'https://example.com/second.gguf',
    filename: 'second.gguf',
    sizeBytes: 10,
  );
}

class _HoldingModelService implements ModelService {
  _HoldingModelService({
    Set<String>? downloadedFiles,
    Set<String>? cachedAssetKeys,
    this.modelsDirectoryFuture,
  }) : downloadedFiles = downloadedFiles ?? <String>{},
       cachedAssetKeys = cachedAssetKeys?.toSet();

  final Completer<void> downloadStarted = Completer<void>();
  final Completer<void> downloadCancelled = Completer<void>();
  final Completer<void> downloadCompleted = Completer<void>();
  final Completer<void> _finishDownload = Completer<void>();
  final Set<String> downloadedFiles;
  final Set<String>? cachedAssetKeys;
  final Future<String>? modelsDirectoryFuture;

  int downloadCalls = 0;
  int deleteCalls = 0;
  CancelToken? lastCancelToken;

  void completeDownload() {
    if (!_finishDownload.isCompleted) {
      _finishDownload.complete();
    }
  }

  @override
  Future<String> getModelsDirectory() async =>
      await modelsDirectoryFuture ?? '/models';

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
