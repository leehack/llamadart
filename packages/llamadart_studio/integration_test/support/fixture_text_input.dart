import 'package:flutter_test/flutter_test.dart';

/// Enables fixture edits after testWidgets has reset the binding.
void registerFixtureTextInput(WidgetTester tester) {
  final input = tester.testTextInput;
  if (input.isRegistered) return;
  // Integration bindings leave this disabled. Without a captured client ID,
  // Flutter's synthetic edits use -1, which only debug builds accept.
  input.register();
  addTearDown(input.unregister);
}

/// Sends a fixture edit through the focused field's registered input client.
Future<void> enterFixtureText(
  WidgetTester tester,
  Finder field,
  String text,
) async {
  expect(
    tester.testTextInput.isRegistered,
    isTrue,
    reason: 'Register fixture text input inside the test body before focusing.',
  );
  await tester.showKeyboard(field);
  expect(
    tester.testTextInput.hasAnyClients,
    isTrue,
    reason: 'Fixture edits require a captured positive TextInput client ID.',
  );
  await tester.enterText(field, text);
}
