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

    final provider = _ReadyRuntimeProvider(
      promptTokens: 26,
      cachedPromptTokens: 0,
      completionTokens: 12,
    );
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
    for (final (label, value) in [
      ('Prompt tokens', '26'),
      ('Cached prompt tokens', '0'),
      ('Completion tokens', '12'),
      ('Average speed', '86.2 tok/s'),
      ('Runtime notes', 'mock bridge, echo'),
    ]) {
      final tile = find.widgetWithText(ListTile, label);
      await tester.scrollUntilVisible(tile, 100);
      expect(
        find.descendant(of: tile, matching: find.text(value)),
        findsOneWidget,
      );
    }
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
  _ReadyRuntimeProvider({
    this.runtime,
    this.runtimeGpuLayerCount,
    this.promptTokens,
    this.cachedPromptTokens,
    this.completionTokens,
  }) : super(
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
  int? get lastPromptTokens => promptTokens;

  @override
  int? get lastCachedPromptTokens => cachedPromptTokens;

  @override
  int? get lastCompletionTokens => completionTokens;

  @override
  String? get runtimeNotes => 'mock_bridge;echo';

  final LlamaRuntime? runtime;
  final int? runtimeGpuLayerCount;
  final int? promptTokens;
  final int? cachedPromptTokens;
  final int? completionTokens;

  @override
  LlamaRuntime? get activeRuntime => runtime;

  @override
  int? get runtimeGpuLayers => runtimeGpuLayerCount;
}
