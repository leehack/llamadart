// Keep Material types compatible with flutter_markdown (see README).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart_studio/llamadart_studio.dart';
import 'package:llamadart_studio/src/widgets/tool_availability_notice_card.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';

import 'studio_widget_test_helpers.dart';

const _unavailable = StudioToolAvailabilityNotice(
  toolName: 'rip_grep_packages',
  reason:
      'This model cannot safely use this tool. Choose another model to use it.',
);
const _restricted = StudioToolAvailabilityNotice(
  toolName: 'analyze_files',
  reason: 'This model can use a limited set of inputs. Other inputs remain unavailable.',
  isUnavailable: false,
);

void main() {
  for (final workspace in [StudioWorkspace.chat, StudioWorkspace.coding]) {
    for (final width in [420.0, 1440.0]) {
      testWidgets('${workspace.name} shows per-tool limits at width $width', (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(Size(width, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final inference = _AvailabilityInference();
        final deps = await buildTestDeps(inferencePort: inference);
        addTearDown(deps.dispose);
        await deps.shellController.selectWorkspace(workspace);
        await tester.pumpWidget(_app(deps, workspace));
        await tester.pumpAndSettle();
        expect(find.byType(ToolAvailabilityNoticeCard), findsNothing);

        if (workspace == StudioWorkspace.chat) {
          await deps.chatController.sendMessage('Find the relevant code');
        } else {
          await deps.codingController.sendCodingPrompt(
            'Find the relevant code',
          );
        }
        await tester.pumpAndSettle();
        final card = find.byKey(const Key('tool_availability_notice_card'));
        await tester.ensureVisible(card);
        await tester.pumpAndSettle();
        expect(card, findsOneWidget);
        expect(
          find.text('1 unavailable · 1 with limited inputs'),
          findsOneWidget,
        );
        expect(find.text('rip_grep_packages · Unavailable'), findsOneWidget);
        expect(find.text('analyze_files · Limited inputs'), findsOneWidget);
        expect(find.text(_unavailable.reason), findsOneWidget);
        expect(find.text(_restricted.reason), findsOneWidget);
        final messages = workspace == StudioWorkspace.chat
            ? deps.chatController.state.activeConversation!.activeBranch
            : deps.codingController.state.messages;
        expect(
          messages
              .where((message) => message.role == StudioRole.assistant)
              .map((message) => message.text),
          ['I can continue using the compatible tools.'],
        );
        expect(
          messages.any((message) => message.text.contains(_unavailable.reason)),
          isFalse,
        );

        final chooseModel = find.byKey(
          const Key('tool_availability_choose_model'),
        );
        await tester.ensureVisible(chooseModel);
        await tester.pumpAndSettle();
        await tester.tap(chooseModel);
        await tester.pumpAndSettle();
        expect(
          deps.shellController.state.activeWorkspace,
          StudioWorkspace.models,
        );

        inference.emitNotices = false;
        if (workspace == StudioWorkspace.chat) {
          await deps.chatController.sendMessage('Continue');
        } else {
          await deps.codingController.sendCodingPrompt('Continue');
        }
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('tool_availability_notice_card')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('long tool names and reasons remain usable with large text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 460));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var selectedModel = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: StudioTheme.dark(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(1.8)),
          child: child!,
        ),
        home: Scaffold(
          body: ListView(
            children: [
              ToolAvailabilityNoticeCard(
                notices: [
                  StudioToolAvailabilityNotice(
                    toolName: 'dart_flutter_workspace_rip_grep_packages_with_a_long_exposed_name',
                    reason: List.filled(12, _unavailable.reason).join(' '),
                  ),
                ],
                onChooseModel: () => selectedModel = true,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final chooseModel = find.byKey(const Key('tool_availability_choose_model'));
    await tester.ensureVisible(chooseModel);
    await tester.pumpAndSettle();
    await tester.tap(chooseModel);
    expect(selectedModel, isTrue);
    expect(tester.takeException(), isNull);
  });
}

Widget _app(StudioDependencies deps, StudioWorkspace workspace) => StudioScope(
  deps: deps,
  child: MaterialApp(
    theme: StudioTheme.dark(),
    home: Scaffold(
      body: workspace == StudioWorkspace.chat
          ? const ChatWorkspaceView()
          : const CodingWorkspaceView(),
    ),
  ),
);

class _AvailabilityInference extends FakeInferencePort {
  bool emitNotices = true;

  @override
  Stream<StudioTurnEvent> streamTurn(StudioTurnRequest request) =>
      Stream.fromIterable([
        if (emitNotices)
          const StudioToolAvailabilityEvent([_unavailable, _restricted]),
        const StudioTextDeltaEvent(
          'I can continue using the compatible tools.',
        ),
        const StudioTurnCompletedEvent(
          StudioTurnResult(
            text: 'I can continue using the compatible tools.',
            metrics: StudioTurnMetrics(
              generatedTokens: 8,
              elapsedMs: 1,
              decodeElapsedMs: 1,
            ),
          ),
        ),
      ]);
}
