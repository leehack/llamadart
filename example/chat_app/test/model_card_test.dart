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
}

Future<void> _pumpCard(
  WidgetTester tester, {
  required DownloadableModel model,
  required bool isWeb,
  required bool isDownloaded,
  ModelProfileCacheState? cacheState,
  bool isDownloading = false,
  double progress = 0,
  String? downloadStatusLabel,
  String? downloadTransferLabel,
  required VoidCallback onSelect,
  required VoidCallback onDownload,
  VoidCallback? onDelete,
  bool includeProjector = true,
  ValueChanged<bool>? onIncludeProjectorChanged,
  double textScale = 1.0,
  bool isSelected = false,
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
            progress: progress,
            downloadStatusLabel: downloadStatusLabel,
            downloadTransferLabel: downloadTransferLabel,
            isWeb: isWeb,
            isSelected: isSelected,
            gpuLayers: gpuLayers,
            contextSize: 2048,
            onGpuLayersChanged: (_) {},
            onContextSizeChanged: (_) {},
            onSelect: onSelect,
            onDownload: onDownload,
            onDelete: onDelete ?? () {},
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
