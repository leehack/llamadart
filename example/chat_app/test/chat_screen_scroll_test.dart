import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart_chat_example/models/chat_message.dart';
import 'package:llamadart_chat_example/models/chat_settings.dart';
import 'package:llamadart_chat_example/providers/chat_provider.dart';
import 'package:llamadart_chat_example/screens/chat_screen.dart';
import 'package:provider/provider.dart';

import 'mocks.dart';

class _ScrollTestChatProvider extends ChatProvider {
  final List<ChatMessage> _testMessages = [];
  String _testConversationId = 'conversation-1';
  bool _testIsGenerating = false;

  _ScrollTestChatProvider()
    : super(
        chatService: MockChatService(
          engine: MockLlamaEngine()..initialized = true,
        ),
        settingsService: MockSettingsService(),
        initialSettings: const ChatSettings(modelPath: 'test_model.gguf'),
      ) {
    _testMessages.addAll(_longConversation('Initial'));
  }

  static List<ChatMessage> _longConversation(String label) => List.generate(
    30,
    (index) => ChatMessage(
      text:
          '$label message $index. This deliberately long message gives the '
          'conversation enough height to exercise user-controlled scrolling.',
      isUser: index.isEven,
    ),
  );

  @override
  List<ChatMessage> get messages => List.unmodifiable(_testMessages);

  @override
  String get activeConversationId => _testConversationId;

  @override
  bool get isGenerating => _testIsGenerating;

  @override
  bool get isLoaded => true;

  @override
  bool get isReady => true;

  @override
  bool get canRegenerateLastResponse => false;

  void beginStreaming() {
    _testIsGenerating = true;
    _testMessages.add(ChatMessage(text: 'Starting', isUser: false));
    notifyListeners();
  }

  void growStreamingMessage() {
    final current = _testMessages.removeLast();
    _testMessages.add(
      current.copyWith(
        text:
            '${current.text}\nMore streamed content that increases the height '
            'of the response without taking over the reader’s scroll.',
      ),
    );
    notifyListeners();
  }

  void finishStreaming() {
    _testIsGenerating = false;
    notifyListeners();
  }

  void showConversation(String id) {
    _testConversationId = id;
    _testMessages
      ..clear()
      ..addAll(_longConversation('Other'));
    notifyListeners();
  }

  @override
  Future<void> sendMessage(String text) async {
    _testMessages
      ..add(ChatMessage(text: text, isUser: true))
      ..add(
        ChatMessage(
          text: 'A new assistant response after the explicit send action.',
          isUser: false,
        ),
      );
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<_ScrollTestChatProvider> pumpChat(WidgetTester tester) async {
    final provider = _ScrollTestChatProvider();
    addTearDown(provider.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<ChatProvider>.value(
        value: provider,
        child: const MaterialApp(home: Scaffold(body: ChatScreen())),
      ),
    );
    await tester.pumpAndSettle();
    return provider;
  }

  ScrollController chatScrollController(WidgetTester tester) {
    final scrollable = tester.state<ScrollableState>(
      find.byType(Scrollable).first,
    );
    return scrollable.widget.controller!;
  }

  group('ChatScreen scrolling behavior', () {
    testWidgets(
      'an existing conversation initially opens at the latest message',
      (tester) async {
        await pumpChat(tester);
        final controller = chatScrollController(tester);

        expect(controller.position.maxScrollExtent, greaterThan(0));
        expect(
          controller.position.pixels,
          closeTo(controller.position.maxScrollExtent, 1),
        );
      },
    );

    testWidgets(
      'manual scrolling during streaming is preserved through completion',
      (tester) async {
        final provider = await pumpChat(tester);
        final controller = chatScrollController(tester);

        provider.beginStreaming();
        await tester.pumpAndSettle();
        controller.jumpTo(100);
        await tester.pump();

        for (var index = 0; index < 4; index += 1) {
          provider.growStreamingMessage();
          await tester.pump();
        }
        expect(controller.position.pixels, closeTo(100, 1));

        provider.finishStreaming();
        await tester.pumpAndSettle();
        expect(controller.position.pixels, closeTo(100, 1));

        await tester.tap(find.byTooltip('Jump to latest'));
        await tester.pumpAndSettle();
        expect(
          controller.position.pixels,
          closeTo(controller.position.maxScrollExtent, 1),
        );
      },
    );

    testWidgets('switching conversations opens the new thread at the bottom', (
      tester,
    ) async {
      final provider = await pumpChat(tester);
      final controller = chatScrollController(tester);
      controller.jumpTo(50);
      await tester.pump();

      provider.showConversation('conversation-2');
      await tester.pumpAndSettle();

      expect(
        controller.position.pixels,
        closeTo(controller.position.maxScrollExtent, 1),
      );
    });

    testWidgets('sending a message explicitly re-pins the conversation', (
      tester,
    ) async {
      await pumpChat(tester);
      final controller = chatScrollController(tester);
      controller.jumpTo(50);
      await tester.pump();

      await tester.enterText(find.byType(TextField).last, 'New question');
      await tester.pump();
      await tester.tap(find.byTooltip('Send message'));
      await tester.pumpAndSettle();

      expect(
        controller.position.pixels,
        closeTo(controller.position.maxScrollExtent, 1),
      );
    });
  });
}
