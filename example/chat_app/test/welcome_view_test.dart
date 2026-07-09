import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart_chat_example/widgets/welcome_view.dart';

void main() {
  Widget buildSubject({
    required String? modelPath,
    required VoidCallback? onSelectModel,
    required VoidCallback onRetry,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: WelcomeView(
          isInitializing: false,
          error: null,
          modelPath: modelPath,
          isLoaded: false,
          onRetry: onRetry,
          onSelectModel: onSelectModel,
        ),
      ),
    );
  }

  testWidgets(
    'shows load action for selected model without selector callback',
    (tester) async {
      var retried = false;

      await tester.pumpWidget(
        buildSubject(
          modelPath: '/models/tiny.gguf',
          onSelectModel: null,
          onRetry: () {
            retried = true;
          },
        ),
      );

      expect(find.widgetWithText(FilledButton, 'Load model'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Change model'), findsNothing);

      await tester.tap(find.widgetWithText(FilledButton, 'Load model'));
      expect(retried, isTrue);
    },
  );

  testWidgets('hides model actions when no model or selector is available', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildSubject(modelPath: null, onSelectModel: null, onRetry: () {}),
    );

    expect(find.widgetWithText(FilledButton, 'Load model'), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Select model'), findsNothing);
    expect(find.widgetWithText(OutlinedButton, 'Change model'), findsNothing);
  });
}
