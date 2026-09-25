import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart_chat_example/validation/controller.dart';
import 'package:llamadart_chat_example/validation_main.dart';

void main() {
  const profile = String.fromEnvironment(
    'VALIDATION_PROFILE',
    defaultValue: 'tiny-gguf-cpu',
  );

  testWidgets('compiled validation profile is selectable without preparation', (
    tester,
  ) async {
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

  test('bundled profiles are exactly the validation profile assets', () async {
    final files =
        Directory('../../packages/llamadart_validation/assets/profiles')
            .listSync()
            .map((file) => file.uri.pathSegments.last)
            .where((name) => name.endsWith('.json'))
            .map((name) => name.substring(0, name.length - '.json'.length))
            .toList()
          ..sort();
    expect(files, containsAll(['gemma4-gguf-metal', 'chat-gguf-webgpu']));
    TestWidgetsFlutterBinding.ensureInitialized();
    expect(await bundledValidationProfiles(rootBundle), files);
  });

  testWidgets('the profile field lists every bundled non-NPU profile', (
    tester,
  ) async {
    final ids = (await tester.runAsync(bundledValidationProfiles))!;
    await tester.pumpWidget(const ValidationApp());
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    final field = find.byType(DropdownButtonFormField<String>);
    final items = tester
        .widget<DropdownButton<String>>(
          find.descendant(
            of: field,
            matching: find.byType(DropdownButton<String>),
          ),
        )
        .items!
        .map((item) => item.value)
        .toList();
    expect(
      items,
      profile.startsWith('npu-')
          ? [profile]
          : ids.where((id) => !id.startsWith('npu-')).toList(),
    );
    expect(items, contains(profile));
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
