import 'dart:io';

// Keep Material types compatible with flutter_markdown (see README).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart_studio/llamadart_studio.dart';

import 'studio_widget_test_helpers.dart';

void main() {
  testWidgets('Coding reasoning paints on its own Material surface', (
    tester,
  ) async {
    final root = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('coding_reasoning_'),
    ))!;
    final deps = await buildTestDeps();
    addTearDown(() async {
      await deps.dispose();
      await tester.runAsync(() => root.delete(recursive: true));
    });
    await tester.runAsync(
      () => deps.codingController.setWorkspaceRoot(root.path),
    );
    await tester.pumpWidget(
      StudioScope(
        deps: deps,
        child: MaterialApp(
          theme: StudioTheme.dark(),
          home: const Scaffold(body: CodingWorkspaceView()),
        ),
      ),
    );
    await tester.enterText(
      find.byKey(const Key('coding_prompt_input')),
      'Explain this workspace',
    );
    await tester.tap(find.byKey(const Key('coding_send_button')));
    await tester.pumpAndSettle();
    expect(find.text('Reasoning trace'), findsOneWidget);
    await tester.tap(find.text('Reasoning trace'));
    await tester.pumpAndSettle();
    expect(find.text('Checking context and tools...'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
