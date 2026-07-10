import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:llamadart_chat_example/models/chat_settings.dart';
import 'package:llamadart_chat_example/providers/chat_provider.dart';
import 'package:llamadart_chat_example/screens/app_shell_screen.dart';
import 'package:llamadart_chat_example/services/model_download_ui_controller.dart';

import 'mocks.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppShellScreen', () {
    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
    });

    testWidgets('keeps active download progress visible outside settings', (
      tester,
    ) async {
      final oldSize = tester.view.physicalSize;
      final oldRatio = tester.view.devicePixelRatio;
      tester.view
        ..physicalSize = const Size(854, 700)
        ..devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view
          ..physicalSize = oldSize
          ..devicePixelRatio = oldRatio;
      });

      final provider = ChatProvider(
        chatService: MockChatService(),
        settingsService: MockSettingsService(),
      );
      addTearDown(provider.dispose);
      final downloadUi = ModelDownloadUiController();
      addTearDown(downloadUi.dispose);
      await downloadUi.enqueueDownload(
        filename: 'active.gguf',
        displayName: 'Active model',
      );
      downloadUi.updateState('active.gguf', progress: 0.42);

      await tester.pumpWidget(
        ChangeNotifierProvider<ChatProvider>.value(
          value: provider,
          child: MaterialApp(
            home: AppShellScreen(downloadUiController: downloadUi),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Active model'), findsOneWidget);
      expect(find.textContaining('42%'), findsOneWidget);

      final queued = downloadUi.enqueueDownload(
        filename: 'queued.gguf',
        displayName: 'Queued model',
      );
      await tester.pump();
      expect(find.text('1 queued'), findsOneWidget);

      await tester.tap(find.textContaining('42%'));
      await tester.pumpAndSettle();
      expect(find.text('Model parameters'), findsOneWidget);

      downloadUi.cancel('queued.gguf');
      expect(await queued, isFalse);
      downloadUi.completeActiveDownload('active.gguf');
    });

    testWidgets('download activity keeps an open pinned settings panel open', (
      tester,
    ) async {
      final oldSize = tester.view.physicalSize;
      final oldRatio = tester.view.devicePixelRatio;
      tester.view
        ..physicalSize = const Size(1800, 900)
        ..devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view
          ..physicalSize = oldSize
          ..devicePixelRatio = oldRatio;
      });

      final provider = ChatProvider(
        chatService: MockChatService(),
        settingsService: MockSettingsService(),
      );
      addTearDown(provider.dispose);
      final downloadUi = ModelDownloadUiController();
      addTearDown(downloadUi.dispose);
      await downloadUi.enqueueDownload(
        filename: 'active.gguf',
        displayName: 'Active model',
      );
      downloadUi.updateState('active.gguf', progress: 0.1);

      await tester.pumpWidget(
        ChangeNotifierProvider<ChatProvider>.value(
          value: provider,
          child: MaterialApp(
            home: AppShellScreen(downloadUiController: downloadUi),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Open model and inference settings'));
      await tester.pumpAndSettle();
      expect(find.text('Model parameters'), findsOneWidget);

      await tester.tap(find.text('Active model'));
      await tester.pumpAndSettle();
      expect(find.text('Model parameters'), findsOneWidget);

      downloadUi.completeActiveDownload('active.gguf');
    });

    testWidgets('keeps desktop settings opt-in and opens manage models view', (
      tester,
    ) async {
      final oldSize = tester.view.physicalSize;
      final oldRatio = tester.view.devicePixelRatio;

      tester.view
        ..physicalSize = const Size(1440, 920)
        ..devicePixelRatio = 1.0;

      addTearDown(() {
        tester.view
          ..physicalSize = oldSize
          ..devicePixelRatio = oldRatio;
      });

      final provider = ChatProvider(
        chatService: MockChatService(),
        settingsService: MockSettingsService(),
        initialSettings: const ChatSettings(
          modelPath: 'test_model.gguf',
          gpuLayers: 99,
          autoTuneModelParams: true,
        ),
      );

      await tester.pumpWidget(
        ChangeNotifierProvider<ChatProvider>.value(
          value: provider,
          child: const MaterialApp(home: AppShellScreen()),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('llamadart chat'), findsOneWidget);
      expect(find.text('New conversation'), findsWidgets);
      expect(find.text('Inference parameters'), findsNothing);
      expect(find.text('Change model'), findsOneWidget);
      expect(
        find.byTooltip('Open model and inference settings'),
        findsOneWidget,
      );

      await tester.tap(
        find.byTooltip('Open model and inference settings').first,
      );
      await tester.pumpAndSettle();
      expect(find.text('Inference parameters'), findsOneWidget);

      await tester.tap(find.text('Model parameters'));
      await tester.pumpAndSettle();
      expect(find.text('Auto · Max'), findsOneWidget);
      expect(
        find.textContaining(
          'Auto tuning recalculates GPU layers and context headroom',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('Set GPU layers to 99 for Auto'),
        findsNothing,
      );

      provider.updateGpuLayers(0);
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.textContaining('GPU layers is 0, so inference will run on CPU.'),
        findsOneWidget,
      );
    });

    testWidgets('shows change model action when settings panel is hidden', (
      tester,
    ) async {
      final oldSize = tester.view.physicalSize;
      final oldRatio = tester.view.devicePixelRatio;

      tester.view
        ..physicalSize = const Size(1024, 820)
        ..devicePixelRatio = 1.0;

      addTearDown(() {
        tester.view
          ..physicalSize = oldSize
          ..devicePixelRatio = oldRatio;
      });

      final provider = ChatProvider(
        chatService: MockChatService(),
        settingsService: MockSettingsService(),
        initialSettings: const ChatSettings(modelPath: 'test_model.gguf'),
      );

      await tester.pumpWidget(
        ChangeNotifierProvider<ChatProvider>.value(
          value: provider,
          child: const MaterialApp(home: AppShellScreen()),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('Change model'), findsOneWidget);
    });

    testWidgets('uses a full-width settings view on mobile', (tester) async {
      final oldSize = tester.view.physicalSize;
      final oldRatio = tester.view.devicePixelRatio;

      tester.view
        ..physicalSize = const Size(390, 844)
        ..devicePixelRatio = 1.0;

      addTearDown(() {
        tester.view
          ..physicalSize = oldSize
          ..devicePixelRatio = oldRatio;
      });

      final provider = ChatProvider(
        chatService: MockChatService(),
        settingsService: MockSettingsService(),
        initialSettings: const ChatSettings(modelPath: 'test_model.gguf'),
      );

      await tester.pumpWidget(
        ChangeNotifierProvider<ChatProvider>.value(
          value: provider,
          child: const MaterialApp(home: AppShellScreen()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byTooltip('Open model and inference settings').first,
      );
      await tester.pumpAndSettle();

      expect(find.text('Settings'), findsOneWidget);
      expect(find.byTooltip('Close settings'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('icon-only shell actions expose accessible names', (
      tester,
    ) async {
      final oldSize = tester.view.physicalSize;
      final oldRatio = tester.view.devicePixelRatio;
      tester.view
        ..physicalSize = const Size(390, 844)
        ..devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view
          ..physicalSize = oldSize
          ..devicePixelRatio = oldRatio;
      });
      final semantics = tester.ensureSemantics();

      final provider = ChatProvider(
        chatService: MockChatService(),
        settingsService: MockSettingsService(),
        initialSettings: const ChatSettings(modelPath: 'test_model.gguf'),
      );
      addTearDown(provider.dispose);

      await tester.pumpWidget(
        ChangeNotifierProvider<ChatProvider>.value(
          value: provider,
          child: const MaterialApp(home: AppShellScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.bySemanticsLabel('Open navigation menu'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Open model and inference settings'),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('Send message'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('settings survives responsive breakpoints at large text', (
      tester,
    ) async {
      final oldSize = tester.view.physicalSize;
      final oldRatio = tester.view.devicePixelRatio;
      addTearDown(() {
        tester.view
          ..physicalSize = oldSize
          ..devicePixelRatio = oldRatio;
      });

      final provider = ChatProvider(
        chatService: MockChatService(),
        settingsService: MockSettingsService(),
        initialSettings: const ChatSettings(modelPath: 'test_model.gguf'),
      );
      addTearDown(provider.dispose);

      const sizes = <Size>[
        Size(320, 640),
        Size(719, 780),
        Size(720, 780),
        Size(1039, 820),
        Size(1040, 820),
        Size(1599, 900),
        Size(1600, 900),
      ];

      for (final size in sizes) {
        tester.view
          ..physicalSize = size
          ..devicePixelRatio = 1.0;

        await tester.pumpWidget(
          ChangeNotifierProvider<ChatProvider>.value(
            value: provider,
            child: MaterialApp(
              key: ValueKey<double>(size.width),
              home: MediaQuery(
                data: MediaQueryData(
                  size: size,
                  textScaler: const TextScaler.linear(2.0),
                ),
                child: AppShellScreen(key: ValueKey<double>(size.width)),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(
          find.byTooltip('Open model and inference settings').first,
        );
        await tester.pumpAndSettle();

        expect(
          tester.takeException(),
          isNull,
          reason: 'Unexpected layout exception at ${size.width}px',
        );
        expect(find.text('Model parameters'), findsOneWidget);

        await tester.tap(find.text('Manage models'));
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          tester.takeException(),
          isNull,
          reason: 'Model library overflowed at ${size.width}px',
        );
        expect(find.text('Add model'), findsOneWidget);
      }
    });

    testWidgets('confirms before deleting a conversation', (tester) async {
      final oldSize = tester.view.physicalSize;
      final oldRatio = tester.view.devicePixelRatio;
      tester.view
        ..physicalSize = const Size(1440, 920)
        ..devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view
          ..physicalSize = oldSize
          ..devicePixelRatio = oldRatio;
      });

      final provider = ChatProvider(
        chatService: MockChatService(),
        settingsService: MockSettingsService(),
        initialSettings: const ChatSettings(modelPath: 'test_model.gguf'),
      )..createConversation();
      addTearDown(provider.dispose);

      await tester.pumpWidget(
        ChangeNotifierProvider<ChatProvider>.value(
          value: provider,
          child: const MaterialApp(home: AppShellScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(provider.conversations, hasLength(2));
      void pressDelete() {
        final deleteButton = tester.widget<IconButton>(
          find
              .ancestor(
                of: find.byTooltip('Delete conversation').first,
                matching: find.byType(IconButton),
              )
              .first,
        );
        deleteButton.onPressed!();
      }

      pressDelete();
      await tester.pumpAndSettle();

      expect(find.text('Delete conversation?'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(provider.conversations, hasLength(2));

      pressDelete();
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(provider.conversations, hasLength(1));
    });
  });
}
