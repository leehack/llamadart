import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:llamadart_chat_example/validation/controller.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const profile = String.fromEnvironment(
    'VALIDATION_PROFILE',
    defaultValue: 'tiny-gguf-cpu',
  );
  testWidgets('shared validation: $profile', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Text('Running llamadart validation')),
      ),
    );
    final controller = ValidationController();
    addTearDown(controller.dispose);
    await controller.run(profile);
    binding.reportData =
        controller.report?.toJson() ?? {'error': controller.error};
    expect(controller.error, isNull);
    expect(
      controller.report?.assertionsPassed,
      isTrue,
      reason:
          'Functional obligations failed; accelerator qualification remains separate in the report.',
    );
  }, timeout: const Timeout(Duration(minutes: 18)));
}
