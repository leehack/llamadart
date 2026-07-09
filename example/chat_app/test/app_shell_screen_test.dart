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

    testWidgets('shows desktop shell and opens manage models view', (
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

      expect(find.text('Inference parameters'), findsOneWidget);
      expect(find.text('Change model'), findsNothing);
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
  });
}
