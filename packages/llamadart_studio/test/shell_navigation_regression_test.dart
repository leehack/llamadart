// Keep Material types compatible with flutter_markdown (see README).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart_studio/llamadart_studio.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';

import 'studio_widget_test_helpers.dart';

void main() {
  testWidgets('Image draft survives visiting another workspace', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1440, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final deps = await buildTestDeps();
    addTearDown(deps.dispose);
    await tester.pumpWidget(LlamadartStudioApp(dependencies: deps));
    await tester.pumpAndSettle();
    deps.shellController.selectWorkspace(StudioWorkspace.image);
    await tester.pumpAndSettle();
    final prompt = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.decoration?.labelText == 'Positive Prompt',
    );
    await tester.enterText(prompt, 'A handwritten draft to keep');
    deps.shellController.selectWorkspace(StudioWorkspace.chat);
    await tester.pumpAndSettle();
    deps.shellController.selectWorkspace(StudioWorkspace.image);
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(prompt).controller!.text,
      'A handwritten draft to keep',
    );
  });

  testWidgets('Image draft survives rapid return during workspace transition', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1440, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final deps = await buildTestDeps();
    addTearDown(deps.dispose);
    await tester.pumpWidget(LlamadartStudioApp(dependencies: deps));
    await tester.pumpAndSettle();
    deps.shellController.selectWorkspace(StudioWorkspace.image);
    await tester.pumpAndSettle();
    final prompt = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.decoration?.labelText == 'Positive Prompt',
    );
    await tester.enterText(prompt, 'Rapid navigation draft');
    deps.shellController.selectWorkspace(StudioWorkspace.chat);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    deps.shellController.selectWorkspace(StudioWorkspace.image);
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(prompt).controller!.text,
      'Rapid navigation draft',
    );
  });

  for (final workspace in <StudioWorkspace>[
    StudioWorkspace.speech,
    StudioWorkspace.playground,
  ]) {
    testWidgets('${workspace.name} draft survives navigation', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final deps = await buildTestDeps();
      addTearDown(deps.dispose);
      await tester.pumpWidget(LlamadartStudioApp(dependencies: deps));
      await tester.pumpAndSettle();
      deps.shellController.selectWorkspace(workspace);
      await tester.pumpAndSettle();
      final label = workspace == StudioWorkspace.speech
          ? 'Text to Synthesize'
          : 'Passages to Embed (one per line)';
      final field = find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == label,
      );
      await tester.enterText(field, 'Keep this unfinished draft');
      deps.shellController.selectWorkspace(StudioWorkspace.chat);
      await tester.pumpAndSettle();
      deps.shellController.selectWorkspace(workspace);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(field).controller!.text,
        'Keep this unfinished draft',
      );
    });
  }

  for (final width in <double>[800, 1440]) {
    testWidgets('Inspector shortcut toggles at width $width', (tester) async {
      await tester.binding.setSurfaceSize(Size(width, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final deps = await buildTestDeps();
      addTearDown(deps.dispose);
      await tester.pumpWidget(LlamadartStudioApp(dependencies: deps));
      await tester.pumpAndSettle();
      final initial = deps.shellController.state.settings.inspectorOpen;
      Future<void> shortcut() async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
      }

      await shortcut();
      final scaffold = tester.state<ScaffoldState>(find.byType(Scaffold).first);
      if (width < 1120) {
        expect(scaffold.isEndDrawerOpen, isTrue);
      } else {
        expect(deps.shellController.state.settings.inspectorOpen, !initial);
      }
      await shortcut();
      if (width < 1120) {
        expect(scaffold.isEndDrawerOpen, isFalse);
      } else {
        expect(deps.shellController.state.settings.inspectorOpen, initial);
      }
    });
  }
}
