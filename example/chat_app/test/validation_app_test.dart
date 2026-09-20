import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart_chat_example/validation_main.dart';

void main() {
  testWidgets('compiled validation profile is selectable without preparation', (
    tester,
  ) async {
    const profile = String.fromEnvironment(
      'VALIDATION_PROFILE',
      defaultValue: 'tiny-gguf-cpu',
    );
    await tester.pumpWidget(const ValidationApp());
    expect(tester.takeException(), isNull);
    expect(find.text(profile), findsWidgets);
    final field = tester.widget<DropdownButtonFormField<String>>(
      find.byType(DropdownButtonFormField<String>),
    );
    expect(field.initialValue, profile);
    const native =
        String.fromEnvironment('VALIDATION_EXECUTION_PATH') == 'native_c_api';
    expect(
      find.text(
        native
            ? 'Direct native control · does not qualify the public Dart path'
            : 'llamadart public API',
      ),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
