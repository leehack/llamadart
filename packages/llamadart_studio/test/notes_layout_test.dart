// Keep Material types compatible with flutter_markdown (see README).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart_studio/llamadart_studio.dart';

import 'studio_widget_test_helpers.dart';

void main() {
  for (final width in <double>[390, 1440]) {
    testWidgets('Notes prioritizes writing and discloses search at $width', (
      WidgetTester tester,
    ) async {
      await tester.binding.setSurfaceSize(Size(width, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final deps = await buildTestDeps();
      addTearDown(deps.dispose);
      final note = await deps.notebookController.createNote(
        title: 'An idea worth keeping',
        content: 'Draft text',
      );
      await tester.pumpWidget(
        StudioScope(
          deps: deps,
          child: MaterialApp(
            theme: StudioTheme.dark(),
            home: const Scaffold(body: NotebookWorkspaceView()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final body = find.byKey(const Key('vault_note_content_input'));
      expect(body, findsOneWidget);
      expect(tester.getTopLeft(body).dy, lessThan(900));
      expect(find.byKey(const Key('vault_search_input')), findsNothing);
      expect(find.byKey(const Key('vault_index_notes_button')), findsNothing);
      if (width < 800) {
        expect(find.byKey(Key('vault_note_item_${note.id}')), findsNothing);
        await tester.tap(find.byKey(const Key('notebook_sources_section')));
        await tester.pumpAndSettle();
        expect(find.byKey(Key('vault_note_item_${note.id}')), findsOneWidget);
        await tester.tap(find.byKey(const Key('notebook_sources_section')));
        await tester.pumpAndSettle();
      } else {
        expect(find.byKey(Key('vault_note_item_${note.id}')), findsOneWidget);
      }

      await tester.enterText(body, 'A focused editing session');
      await tester.pump(const Duration(milliseconds: 700));
      expect(
        deps.notebookController.state.selectedNote?.content,
        'A focused editing session',
      );
      final scrollable = find
          .descendant(
            of: find.byKey(const Key('notebook_workspace_scroll')),
            matching: find.byType(Scrollable),
          )
          .first;
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      final position = tester.state<ScrollableState>(scrollable).position;
      position.jumpTo(position.maxScrollExtent);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Ask notebook'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ask notebook'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('vault_search_input')), findsOneWidget);
      expect(find.byKey(const Key('vault_index_notes_button')), findsNothing);
      await tester.ensureVisible(find.text('Search settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Search settings'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('vault_index_notes_button')), findsOneWidget);
      expect(find.byKey(const Key('vault_rerank_switch')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
