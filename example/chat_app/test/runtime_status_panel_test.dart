import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_chat_example/models/chat_settings.dart';
import 'package:llamadart_chat_example/providers/chat_provider.dart';
import 'package:llamadart_chat_example/widgets/runtime_status_panel.dart';
import 'package:provider/provider.dart';

import 'mocks.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('stays compact at narrow width and opens runtime details', (
    tester,
  ) async {
    final oldSize = tester.view.physicalSize;
    final oldRatio = tester.view.devicePixelRatio;
    tester.view
      ..physicalSize = const Size(320, 640)
      ..devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view
        ..physicalSize = oldSize
        ..devicePixelRatio = oldRatio;
    });

    final provider = _ReadyRuntimeProvider();
    addTearDown(provider.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<ChatProvider>.value(
        value: provider,
        child: MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 640),
              textScaler: TextScaler.linear(1.5),
            ),
            child: const Scaffold(body: RuntimeStatusPanel()),
          ),
        ),
      ),
    );

    expect(find.bySemanticsLabel('Open runtime details'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.bySemanticsLabel('Open runtime details'));
    await tester.pumpAndSettle();

    expect(find.text('Runtime details'), findsOneWidget);
    expect(find.text('Average speed'), findsOneWidget);
    expect(find.text('mock bridge, echo'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final (runtime, label) in [
    (LlamaRuntime.liteRtLm, 'Maximum'),
    (LlamaRuntime.llamaCpp, '${ModelParams.maxGpuLayers}'),
  ]) {
    testWidgets('labels full GPU offload as $label on ${runtime.name}', (
      tester,
    ) async {
      final provider = _ReadyRuntimeProvider(
        runtime: runtime,
        runtimeGpuLayerCount: ModelParams.maxGpuLayers,
      );
      addTearDown(provider.dispose);

      await tester.pumpWidget(
        ChangeNotifierProvider<ChatProvider>.value(
          value: provider,
          child: const MaterialApp(home: Scaffold(body: RuntimeStatusPanel())),
        ),
      );
      await tester.tap(find.bySemanticsLabel('Open runtime details'));
      await tester.pumpAndSettle();

      expect(find.text('GPU layers'), findsOneWidget);
      expect(find.text(label), findsOneWidget);
    });
  }
}

class _ReadyRuntimeProvider extends ChatProvider {
  _ReadyRuntimeProvider({this.runtime, this.runtimeGpuLayerCount})
    : super(
        chatService: MockChatService(),
        settingsService: MockSettingsService(),
        initialSettings: const ChatSettings(modelPath: 'mock-qwen.gguf'),
      );

  @override
  bool get isReady => true;

  @override
  String get activeBackend => 'WEBGPU';

  @override
  String get activeModelName => 'mock-qwen.gguf';

  @override
  int get currentTokens => 25;

  @override
  int get contextLimit => 4096;

  @override
  double? get lastTokensPerSecond => 86.2;

  @override
  String? get runtimeNotes => 'mock_bridge;echo';

  final LlamaRuntime? runtime;
  final int? runtimeGpuLayerCount;

  @override
  LlamaRuntime? get activeRuntime => runtime;

  @override
  int? get runtimeGpuLayers => runtimeGpuLayerCount;
}
