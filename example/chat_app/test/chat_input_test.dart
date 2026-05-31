import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_chat_example/models/chat_settings.dart';
import 'package:llamadart_chat_example/providers/chat_provider.dart';
import 'package:llamadart_chat_example/widgets/chat_input.dart';
import 'package:provider/provider.dart';

import 'mocks.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('composer stays editable while generation is running', (
    tester,
  ) async {
    final provider = _GeneratingReadyProvider();
    addTearDown(provider.dispose);

    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<ChatProvider>.value(
        value: provider,
        child: MaterialApp(
          home: Scaffold(
            body: ChatInput(
              controller: controller,
              focusNode: focusNode,
              onSend: () {},
            ),
          ),
        ),
      ),
    );

    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);

    await tester.enterText(find.byType(TextField), 'draft next prompt');
    expect(controller.text, 'draft next prompt');
  });
}

class _GeneratingReadyProvider extends ChatProvider {
  _GeneratingReadyProvider()
    : super(
        chatService: MockChatService(),
        settingsService: MockSettingsService(),
        initialSettings: const ChatSettings(modelPath: 'test_model.gguf'),
      );

  @override
  bool get isGenerating => true;

  @override
  bool get isReady => true;

  @override
  bool get toolsEnabled => false;

  @override
  bool get canAttachMedia => false;

  @override
  List<LlamaContentPart> get stagedParts => const <LlamaContentPart>[];
}
