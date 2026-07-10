import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart_chat_example/models/chat_message.dart';
import 'package:llamadart_chat_example/widgets/message_bubble.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('assistant actions copy and regenerate', (tester) async {
    MethodCall? clipboardCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboardCall = call;
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    var regenerateCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: ChatMessage(text: 'A concise answer', isUser: false),
            isNextSame: false,
            onRegenerate: () => regenerateCalls += 1,
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Copy response'));
    await tester.pump();
    expect(clipboardCall?.arguments, <String, dynamic>{
      'text': 'A concise answer',
    });
    expect(find.text('Response copied'), findsOneWidget);

    await tester.tap(find.byTooltip('Regenerate response'));
    expect(regenerateCalls, 1);
  });
}
