// Keep Material types compatible with flutter_markdown (see README).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart_studio/llamadart_studio.dart';

import 'studio_widget_test_helpers.dart';

void main() {
  for (final size in const <Size>[Size(360, 740), Size(1280, 900)]) {
    testWidgets('Coding keeps setup optional at ${size.width}px', (
      WidgetTester tester,
    ) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final deps = await buildTestDeps();
      addTearDown(deps.dispose);
      await tester.pumpWidget(
        StudioScope(
          deps: deps,
          child: MaterialApp(
            theme: StudioTheme.dark(),
            home: const Scaffold(body: CodingWorkspaceView()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('coding_prompt_input')), findsOneWidget);
      expect(find.byKey(const Key('coding_setup_panel')), findsNothing);
      expect(find.text('What would you like to build?'), findsOneWidget);
      final promptTop = tester.getTopLeft(
        find.byKey(const Key('coding_prompt_input')),
      );
      expect(promptTop.dy, lessThan(size.height));

      await tester.tap(find.byKey(const Key('coding_setup_toggle')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('coding_setup_panel')), findsOneWidget);
      final mcp = find.byKey(const Key('coding_open_mcp_button'));
      await tester.ensureVisible(mcp);
      await tester.tap(mcp);
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
      Navigator.of(tester.element(find.byType(Dialog))).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('coding_setup_toggle')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('coding_setup_panel')), findsNothing);
      if (size.width >= 900) {
        expect(find.text('Explorer'), findsNothing);
        await tester.tap(find.byKey(const Key('coding_explorer_toggle')));
        await tester.pumpAndSettle();
        expect(find.text('Explorer'), findsOneWidget);
      } else {
        await tester.tap(find.text('Files (0)'));
        await tester.pumpAndSettle();
        expect(find.textContaining('Filter workspace files'), findsOneWidget);
        await tester.tap(find.text('Agent'));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('coding_prompt_input')), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });
  }
}
