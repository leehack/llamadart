import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:llamadart_chat_example/models/chat_settings.dart';
import 'package:llamadart_chat_example/providers/chat_provider.dart';
import 'package:llamadart_chat_example/screens/app_shell_screen.dart';

import 'mocks.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppShellScreen', () {
    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
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
        initialSettings: const ChatSettings(modelPath: 'test_model.gguf'),
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
