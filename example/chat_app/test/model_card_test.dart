import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart_chat_example/models/downloadable_model.dart';
import 'package:llamadart_chat_example/services/model_service_base.dart';
import 'package:llamadart_chat_example/widgets/model_card.dart';

void main() {
  testWidgets('web LiteRT-LM presets load and cache on first use', (
    tester,
  ) async {
    var selectCalls = 0;
    var downloadCalls = 0;

    await _pumpCard(
      tester,
      model: _litertLmModel(),
      isWeb: true,
      isDownloaded: false,
      onSelect: () => selectCalls += 1,
      onDownload: () => downloadCalls += 1,
    );

    expect(find.text('Load & Cache Model'), findsOneWidget);
    expect(find.text('Cache Model'), findsNothing);
    expect(find.text('All platforms'), findsOneWidget);

    await tester.tap(find.text('Load & Cache Model'));
    await tester.pump();

    expect(selectCalls, 1);
    expect(downloadCalls, 0);
  });

  testWidgets('web LiteRT-LM cached presets show cached load action', (
    tester,
  ) async {
    var selectCalls = 0;

    await _pumpCard(
      tester,
      model: _litertLmModel(),
      isWeb: true,
      isDownloaded: true,
      onSelect: () => selectCalls += 1,
      onDownload: () {},
    );

    expect(find.text('Use Cached Model'), findsOneWidget);

    await tester.tap(find.text('Use Cached Model'));
    await tester.pump();

    expect(selectCalls, 1);
  });

  testWidgets('LiteRT-LM audio badge is native-only', (tester) async {
    await _pumpCard(
      tester,
      model: _litertLmModel(),
      isWeb: false,
      isDownloaded: true,
      onSelect: () {},
      onDownload: () {},
    );

    expect(find.text('Audio'), findsOneWidget);

    await _pumpCard(
      tester,
      model: _litertLmModel(),
      isWeb: true,
      isDownloaded: true,
      onSelect: () {},
      onDownload: () {},
    );

    expect(find.text('Audio'), findsNothing);
  });

  testWidgets('ASR card distinguishes STT and requires its projector', (
    tester,
  ) async {
    await _pumpCard(
      tester,
      model: _asrModel(),
      isWeb: false,
      isDownloaded: false,
      cacheState: const ModelProfileCacheState(
        model: ModelAssetCacheState(
          role: ModelAssetRole.model,
          label: 'asr.gguf',
          isAvailable: true,
        ),
        multimodalProjector: ModelAssetCacheState(
          role: ModelAssetRole.multimodalProjector,
          label: 'asr-mmproj.gguf',
          isAvailable: false,
        ),
      ),
      onSelect: () {},
      onDownload: () {},
      onIncludeProjectorChanged: (_) {},
    );

    expect(find.text('Audio'), findsOneWidget);
    expect(find.text('Speech-to-text'), findsOneWidget);
    expect(find.text('Native platforms'), findsOneWidget);
    expect(find.text('Use Text Only'), findsNothing);
    expect(find.text('Download Missing Assets'), findsOneWidget);
  });

  testWidgets('shows distribution, desktop scope, and readable large size', (
    tester,
  ) async {
    await _pumpCard(
      tester,
      model: const DownloadableModel(
        name: 'Desktop model',
        description: 'Large desktop model',
        url: 'https://huggingface.co/unsloth/model/resolve/main/model.gguf',
        filename: 'model.gguf',
        sizeBytes: 20 * 1024 * 1024 * 1024,
        minRamGb: 32,
        distribution: 'Unsloth',
        availability: ModelAvailability.nativeDesktop,
      ),
      isWeb: false,
      isDownloaded: false,
      onSelect: () {},
      onDownload: () {},
    );

    expect(find.text('20.0 GB'), findsOneWidget);
    expect(find.text('Unsloth distribution'), findsOneWidget);
    expect(find.text('Desktop'), findsOneWidget);
  });

  testWidgets('uncached custom models expose remove-from-library action', (
    tester,
  ) async {
    var removeCalls = 0;

    await _pumpCard(
      tester,
      model: _ggufModel(),
      isWeb: false,
      isDownloaded: false,
      isCustom: true,
      onSelect: () {},
      onDownload: () {},
      onRemoveFromLibrary: () => removeCalls += 1,
    );

    await tester.tap(find.byTooltip('Model actions'));
    await tester.pumpAndSettle();

    expect(find.text('Remove from library'), findsOneWidget);
    expect(find.text('Delete downloaded files'), findsNothing);

    await tester.tap(find.text('Remove from library'));
    await tester.pumpAndSettle();
    expect(removeCalls, 1);
  });

  testWidgets('cached custom models keep file deletion separate', (
    tester,
  ) async {
    var deleteCalls = 0;

    await _pumpCard(
      tester,
      model: _ggufModel(),
      isWeb: false,
      isDownloaded: true,
      isCustom: true,
      onSelect: () {},
      onDownload: () {},
      onDelete: () => deleteCalls += 1,
      onRemoveFromLibrary: () {},
    );

    await tester.tap(find.byTooltip('Model actions'));
    await tester.pumpAndSettle();

    expect(find.text('Remove from library'), findsOneWidget);
    expect(find.text('Delete downloaded files'), findsOneWidget);
    await tester.tap(find.text('Delete downloaded files'));
    await tester.pumpAndSettle();
    expect(deleteCalls, 1);
  });

  testWidgets('queued model shows its position and can leave the queue', (
    tester,
  ) async {
    var cancelCalls = 0;

    await _pumpCard(
      tester,
      model: _ggufModel(),
      isWeb: false,
      isDownloaded: false,
      isQueued: true,
      queuePosition: 2,
      onSelect: () {},
      onDownload: () {},
      onCancel: () => cancelCalls += 1,
    );

    expect(find.text('Queued for download • Position 2'), findsOneWidget);
    expect(find.text('Download'), findsNothing);
    await tester.tap(find.byTooltip('Remove from download queue'));
    expect(cancelCalls, 1);
  });

  testWidgets('web GGUF presets still show the cache action before download', (
    tester,
  ) async {
    var selectCalls = 0;
    var downloadCalls = 0;

    await _pumpCard(
      tester,
      model: _ggufModel(),
      isWeb: true,
      isDownloaded: false,
      onSelect: () => selectCalls += 1,
      onDownload: () => downloadCalls += 1,
    );

    expect(find.text('Cache Model'), findsOneWidget);
    expect(find.text('Load Web Model'), findsNothing);

    await tester.tap(find.text('Cache Model'));
    await tester.pump();

    expect(selectCalls, 0);
    expect(downloadCalls, 1);
  });

  testWidgets('web large warning uses web model size when available', (
    tester,
  ) async {
    await _pumpCard(
      tester,
      model: _largeNativeSmallWebLiteRtLmModel(),
      isWeb: true,
      isDownloaded: false,
      onSelect: () {},
      onDownload: () {},
    );

    expect(find.textContaining('very large LiteRT-LM'), findsNothing);
  });

  testWidgets('partial multimodal cache allows text-only load', (tester) async {
    var downloadCalls = 0;
    var deleteCalls = 0;
    var includeProjector = true;

    await _pumpCard(
      tester,
      model: _vlmModel(),
      isWeb: false,
      isDownloaded: false,
      cacheState: const ModelProfileCacheState(
        model: ModelAssetCacheState(
          role: ModelAssetRole.model,
          label: 'model.gguf',
          isAvailable: true,
        ),
        multimodalProjector: ModelAssetCacheState(
          role: ModelAssetRole.multimodalProjector,
          label: 'mmproj.gguf',
          isAvailable: false,
        ),
      ),
      onSelect: () {},
      onDownload: () => downloadCalls += 1,
      onDelete: () => deleteCalls += 1,
      includeProjector: includeProjector,
      onIncludeProjectorChanged: (value) => includeProjector = value,
    );

    expect(find.text('Model cached'), findsOneWidget);
    expect(find.text('mmproj missing'), findsOneWidget);
    expect(
      find.text(
        'Model cached; mmproj missing. Download will fetch only missing assets.',
      ),
      findsOneWidget,
    );
    expect(find.text('Download projector'), findsOneWidget);
    expect(find.text('Use Text Only'), findsOneWidget);
    expect(find.text('Download Projector'), findsOneWidget);
    expect(find.byTooltip('Delete cached assets'), findsOneWidget);

    await tester.tap(find.text('Download Projector'));
    await tester.pump();

    expect(downloadCalls, 1);

    await tester.tap(find.byTooltip('Delete cached assets'));
    await tester.pump();

    expect(deleteCalls, 1);
  });

  testWidgets('download progress row does not overflow narrow cards', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _pumpCard(
      tester,
      model: _vlmModel(),
      isWeb: true,
      isDownloaded: false,
      isDownloading: true,
      progress: 0.67,
      downloadStatusLabel:
          'Caching multimodal projector with an unusually long status label (2/2)',
      downloadTransferLabel: '123.45 MB/s | 12m 34s left',
      onSelect: () {},
      onDownload: () {},
    );

    expect(tester.takeException(), isNull);
    expect(find.byTooltip('Pause Download'), findsOneWidget);
  });

  testWidgets('multimodal actions reflow on narrow large-text cards', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _pumpCard(
      tester,
      model: _vlmModel(),
      isWeb: false,
      isDownloaded: false,
      cacheState: const ModelProfileCacheState(
        model: ModelAssetCacheState(
          role: ModelAssetRole.model,
          label: 'model.gguf',
          isAvailable: true,
        ),
        multimodalProjector: ModelAssetCacheState(
          role: ModelAssetRole.multimodalProjector,
          label: 'mmproj.gguf',
          isAvailable: false,
        ),
      ),
      textScale: 2.0,
      onSelect: () {},
      onDownload: () {},
      onIncludeProjectorChanged: (_) {},
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Download Projector'), findsOneWidget);
    expect(find.text('Use Text Only'), findsOneWidget);
  });

  testWidgets('maximum GPU layers is not labeled as backend Auto', (
    tester,
  ) async {
    await _pumpCard(
      tester,
      model: _ggufModel(),
      isWeb: false,
      isDownloaded: true,
      isSelected: true,
      gpuLayers: 99,
      onSelect: () {},
      onDownload: () {},
    );

    await tester.tap(find.text('Advanced Settings (Selected)'));
    await tester.pumpAndSettle();

    expect(find.text('Max'), findsOneWidget);
    expect(find.text('Max requests full GPU offload'), findsOneWidget);
    expect(find.text('Set to 99 for Auto'), findsNothing);
  });

  testWidgets('unavailable platform cards explain why actions are disabled', (
    tester,
  ) async {
    await _pumpCard(
      tester,
      model: const DownloadableModel(
        name: 'Desktop model',
        description: 'Large desktop model',
        url: 'https://example.com/desktop.gguf',
        filename: 'desktop.gguf',
        sizeBytes: 20,
        availability: ModelAvailability.nativeDesktop,
      ),
      isWeb: false,
      isDownloaded: false,
      isAvailableOnCurrentPlatform: false,
      onSelect: () {},
      onDownload: () {},
    );

    expect(find.text('Available on desktop'), findsOneWidget);
    expect(
      find.textContaining('Switch platforms to use this model'),
      findsOneWidget,
    );
    final button = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Available on desktop'),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('native-only cards explain Web unavailability', (tester) async {
    await _pumpCard(
      tester,
      model: _asrModel(),
      isWeb: true,
      isDownloaded: false,
      isAvailableOnCurrentPlatform: false,
      onSelect: () {},
      onDownload: () {},
    );

    expect(find.text('Native platforms'), findsOneWidget);
    expect(find.text('Available on native platforms'), findsOneWidget);
    final button = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Available on native platforms'),
    );
    expect(button.onPressed, isNull);
  });
}

Future<void> _pumpCard(
  WidgetTester tester, {
  required DownloadableModel model,
  required bool isWeb,
  required bool isDownloaded,
  ModelProfileCacheState? cacheState,
  bool isDownloading = false,
  bool isQueued = false,
  int? queuePosition,
  double progress = 0,
  String? downloadStatusLabel,
  String? downloadTransferLabel,
  required VoidCallback onSelect,
  required VoidCallback onDownload,
  VoidCallback? onDelete,
  VoidCallback? onCancel,
  bool isCustom = false,
  VoidCallback? onRemoveFromLibrary,
  bool includeProjector = true,
  ValueChanged<bool>? onIncludeProjectorChanged,
  double textScale = 1.0,
  bool isSelected = false,
  bool isAvailableOnCurrentPlatform = true,
  int gpuLayers = 0,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: SingleChildScrollView(
          child: ModelCard(
            model: model,
            isDownloaded: isDownloaded,
            cacheState: cacheState,
            isDownloading: isDownloading,
            isQueued: isQueued,
            queuePosition: queuePosition,
            progress: progress,
            downloadStatusLabel: downloadStatusLabel,
            downloadTransferLabel: downloadTransferLabel,
            isWeb: isWeb,
            isAvailableOnCurrentPlatform: isAvailableOnCurrentPlatform,
            isSelected: isSelected,
            gpuLayers: gpuLayers,
            contextSize: 2048,
            onGpuLayersChanged: (_) {},
            onContextSizeChanged: (_) {},
            onSelect: onSelect,
            onDownload: onDownload,
            onDelete: onDelete ?? () {},
            onCancel: onCancel,
            isCustom: isCustom,
            onRemoveFromLibrary: onRemoveFromLibrary,
            includeProjector: includeProjector,
            onIncludeProjectorChanged: onIncludeProjectorChanged,
          ),
        ),
      ),
    ),
  );
}

DownloadableModel _vlmModel() {
  return const DownloadableModel(
    name: 'VLM Test Model',
    description: 'Fake multimodal model for widget tests.',
    url: 'https://example.com/model.gguf',
    filename: 'model.gguf',
    mmprojUrl: 'https://example.com/mmproj.gguf',
    mmprojFilename: 'mmproj.gguf',
    sizeBytes: 10,
    supportsVision: true,
  );
}

DownloadableModel _asrModel() {
  return const DownloadableModel(
    name: 'ASR Test Model',
    description: 'Fake ASR model for widget tests.',
    url: 'https://example.com/asr.gguf',
    filename: 'asr.gguf',
    mmprojUrl: 'https://example.com/asr-mmproj.gguf',
    mmprojFilename: 'asr-mmproj.gguf',
    sizeBytes: 20,
    availability: ModelAvailability.native,
    supportsAudio: true,
    supportsSpeechToText: true,
  );
}

DownloadableModel _litertLmModel() {
  return const DownloadableModel(
    name: 'LiteRT-LM Test Model',
    description: 'Fake LiteRT-LM model for widget tests.',
    url: 'https://example.com/model.litertlm',
    filename: 'model.litertlm',
    webModelSource: RemoteModelAssetSource(
      url: 'https://example.com/model-web.litertlm?download=true',
      filename: 'model-web.litertlm',
    ),
    sizeBytes: 10,
    supportsAudio: true,
    webSupportsAudio: false,
    mediaInputMode: ModelMediaInputMode.direct,
    webMediaInputMode: ModelMediaInputMode.none,
  );
}

DownloadableModel _ggufModel() {
  return const DownloadableModel(
    name: 'GGUF Test Model',
    description: 'Fake GGUF model for widget tests.',
    url: 'https://example.com/model.gguf',
    filename: 'model.gguf',
    sizeBytes: 10,
  );
}

DownloadableModel _largeNativeSmallWebLiteRtLmModel() {
  return const DownloadableModel(
    name: 'LiteRT-LM Test Model',
    description: 'Fake LiteRT-LM model for widget tests.',
    url: 'https://example.com/model.litertlm',
    filename: 'model.litertlm',
    webSizeBytes: 1200 * 1024 * 1024,
    webModelSource: RemoteModelAssetSource(
      url: 'https://example.com/model-web.litertlm?download=true',
      filename: 'model-web.litertlm',
      sizeBytes: 1200 * 1024 * 1024,
    ),
    sizeBytes: 2400 * 1024 * 1024,
  );
}
