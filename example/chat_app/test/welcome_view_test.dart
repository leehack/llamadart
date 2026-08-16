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

  testWidgets('does not expose remote URL credentials in the model label', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildSubject(
        modelPath:
            'https://example.com/models/tiny.gguf?token=secret#signed-fragment',
        onSelectModel: () {},
        onRetry: () {},
      ),
    );

    expect(find.text('tiny.gguf'), findsOneWidget);
    expect(find.textContaining('token=secret'), findsNothing);
    expect(find.textContaining('signed-fragment'), findsNothing);
  });

  testWidgets(
    'shows quick-start recommendation and triggers callback when no model is loaded',
    (tester) async {
      String? quickStartModel;
      var browsedModels = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WelcomeView(
              isInitializing: false,
              error: null,
              modelPath: null,
              isLoaded: false,
              onRetry: () {},
              onSelectModel: () {
                browsedModels = true;
              },
              onQuickStartModel: (model) {
                quickStartModel = model;
              },
            ),
          ),
        ),
      );

      expect(find.text('Start with a model'), findsOneWidget);
      expect(find.text('Qwen3.5 0.8B Instruct'), findsOneWidget);
      expect(
        find.widgetWithText(FilledButton, 'Choose Qwen3.5 0.8B'),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(OutlinedButton, 'Browse all models'),
        findsOneWidget,
      );

      await tester.tap(
        find.widgetWithText(FilledButton, 'Choose Qwen3.5 0.8B'),
      );
      expect(quickStartModel, 'Qwen3.5-0.8B-Q4_K_M.gguf');

      await tester.tap(
        find.widgetWithText(OutlinedButton, 'Browse all models'),
      );
      expect(browsedModels, isTrue);
    },
  );
}
