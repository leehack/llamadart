@TestOn('vm')
library;

import 'dart:io';

// Keep Material types compatible with flutter_markdown (see README).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart_studio/llamadart_studio.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';

import '../integration_test/support/coding_file_browser.dart';
import 'studio_widget_test_helpers.dart';

const _text = 'Salut Québec — café ☕ 안녕하세요 🌲';

// Mirrors the mobile acceptance harness tap: one frame after the tap.
Future<void> _tap(WidgetTester tester, String key) async {
  final target = find.byKey(Key(key));
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target, warnIfMissed: true);
  await tester.pump();
}

Future<void> _waitFor(
  WidgetTester tester,
  bool Function() done,
  String phase,
) async {
  final elapsed = Stopwatch()..start();
  while (!done()) {
    if (elapsed.elapsed > const Duration(seconds: 5)) {
      throw TestFailure('Timed out waiting for $phase.');
    }
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  }
  await tester.pump();
}

void main() {
  for (final path in ['bonjour.txt', 'nested/bonjour.txt', 'a/b/bonjour.txt']) {
    testWidgets('phone file browser opens $path one listing at a time', (
      tester,
    ) async {
      final priorHitTestPolicy = WidgetController.hitTestWarningShouldBeFatal;
      WidgetController.hitTestWarningShouldBeFatal = true;
      addTearDown(
        () => WidgetController.hitTestWarningShouldBeFatal = priorHitTestPolicy,
      );
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final root = Directory.systemTemp.createTempSync('coding_browser_');
      addTearDown(() => root.deleteSync(recursive: true));
      File('${root.path}/$path')
        ..createSync(recursive: true)
        ..writeAsStringSync(_text);
      final deps = await buildTestDeps(
        isMobile: true,
        appDataDirectory: root.path,
      );
      addTearDown(deps.dispose);
      await tester.runAsync(
        () => deps.codingController.setWorkspaceRoot(root.path),
      );
      await tester.binding.setSurfaceSize(const Size(412, 915));
      await tester.pumpWidget(LlamadartStudioApp(dependencies: deps));
      await deps.shellController.selectWorkspace(StudioWorkspace.coding);
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Files ('));
      await tester.pumpAndSettle();

      await openCodingBrowserFile(
        path,
        tap: (key) => _tap(tester, key),
        waitFor: (done, phase) => _waitFor(tester, done, phase),
      );
      await _waitFor(
        tester,
        () => deps.codingController.state.selectedFileSlice?.content == _text,
        'file browser text',
      );
      await tester.pumpAndSettle();

      expect(deps.codingController.state.selectedFilePath, path);
      final preview = find.byKey(const Key('coding_file_syntax_preview'));
      expect(preview, findsOneWidget);
      final displayed = tester
          .widgetList<RichText>(
            find.descendant(of: preview, matching: find.byType(RichText)),
          )
          .map((w) => w.text.toPlainText())
          .join('\n');
      expect(displayed, contains(_text));
      expect(tester.takeException(), isNull);
    });
  }
}
