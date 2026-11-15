import 'dart:io';

import 'package:flutter/foundation.dart';
// Keep Material types compatible with flutter_markdown (see README).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart_studio/llamadart_studio.dart';

import 'studio_widget_test_helpers.dart';

void main() {
  for (final scale in <double>[1, 1.8]) {
    // Shell approval requires a native folder and its gated bash tool.
    testWidgets('Long command approval scrolls at 420x600 with scale $scale', (
      WidgetTester tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(420, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final deps = await buildTestDeps();
      addTearDown(deps.dispose);
      final directory = Directory.systemTemp.createTempSync('studio_approval_');
      addTearDown(() => directory.deleteSync(recursive: true));
      await tester.runAsync(
        () => deps.codingController.setWorkspaceRoot(directory.path),
      );
      deps.codingController.setAllowShellCommandTool(true);
      final command = List<String>.generate(
        100,
        (int i) => 'echo command_line_$i',
      ).join('\n');
      final tool = deps.codingController.buildCodingTools().firstWhere(
        (t) => t.name == 'bash',
      );
      final result = tool.invoke(<String, dynamic>{'command': command});
      await tester.pump();
      expect(deps.codingController.state.pendingShellApproval, isNotNull);
      await tester.pumpWidget(
        StudioScope(
          deps: deps,
          child: MaterialApp(
            theme: StudioTheme.dark(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: const Scaffold(body: CodingWorkspaceView()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final preview = find.byKey(const Key('coding_approval_command_scroll'));
      expect(preview, findsOneWidget);
      expect(tester.getSize(preview).height, lessThanOrEqualTo(140));
      final commandScroll = tester.state<ScrollableState>(
        find.descendant(of: preview, matching: find.byType(Scrollable)).first,
      );
      expect(commandScroll.position.maxScrollExtent, greaterThan(0));
      commandScroll.position.jumpTo(commandScroll.position.maxScrollExtent);
      await tester.pump();
      final reject = find.byKey(const Key('coding_reject_bash_button'));
      await tester.ensureVisible(reject);
      await tester.pumpAndSettle();
      expect(tester.getBottomRight(reject).dy, lessThanOrEqualTo(600));
      expect(tester.takeException(), isNull);
      await tester.tap(reject);
      await tester.pumpAndSettle();
      expect((await result as Map)['rejected'], isTrue);
      expect(find.byKey(const Key('coding_prompt_input')), findsOneWidget);
    }, skip: kIsWeb);
  }

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
