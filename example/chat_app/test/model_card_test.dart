import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart_chat_example/models/downloadable_model.dart';
import 'package:llamadart_chat_example/widgets/model_card.dart';

void main() {
  testWidgets('web LiteRT-LM presets load directly instead of showing cache', (
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

    expect(find.text('Load Web Model'), findsOneWidget);
    expect(find.text('Cache Model'), findsNothing);

    await tester.tap(find.text('Load Web Model'));
    await tester.pump();

    expect(selectCalls, 1);
    expect(downloadCalls, 0);
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
}

Future<void> _pumpCard(
  WidgetTester tester, {
  required DownloadableModel model,
  required bool isWeb,
  required bool isDownloaded,
  required VoidCallback onSelect,
  required VoidCallback onDownload,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ModelCard(
            model: model,
            isDownloaded: isDownloaded,
            isDownloading: false,
            progress: 0,
            isWeb: isWeb,
            isSelected: false,
            gpuLayers: 0,
            contextSize: 2048,
            onGpuLayersChanged: (_) {},
            onContextSizeChanged: (_) {},
            onSelect: onSelect,
            onDownload: onDownload,
            onDelete: () {},
          ),
        ),
      ),
    ),
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
