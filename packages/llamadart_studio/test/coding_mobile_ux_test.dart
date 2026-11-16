@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

// Keep Material types compatible with flutter_markdown (see README).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart_studio/llamadart_studio.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';

import 'studio_widget_test_helpers.dart';

class _FileInference extends FakeInferencePort {
  final events = StreamController<StudioTurnEvent>();
  bool hold = false;
  String response = 'Updated the owned example.';
  int cancellations = 0;

  @override
  void cancelGeneration() {
    cancellations++;
    if (hold && !events.isClosed) unawaited(events.close());
  }

  @override
  Stream<StudioTurnEvent> streamTurn(StudioTurnRequest request) {
    if (hold) return events.stream;
    const call = StudioToolInvocation(
      id: 'write-call',
      name: 'write',
      argumentsJson: '{"path":"main.dart"}',
      resultJson: '{"ok":true}',
      durationMs: 1,
    );
    return Stream.fromIterable([
      const StudioToolInvocationEvent(call),
      StudioTextDeltaEvent(response),
      StudioTurnCompletedEvent(
        StudioTurnResult(
          text: response,
          metrics: StudioTurnMetrics(
            generatedTokens: 1,
            elapsedMs: 1,
            decodeElapsedMs: 1,
          ),
          toolInvocations: [call],
        ),
      ),
    ]);
  }
}

class _RuntimeInference extends FakeInferencePort {
  final runtime = StateStore<StudioRuntimeSnapshot>(
    const StudioRuntimeSnapshot(phase: StudioEnginePhase.ready),
  );

  @override
  ReadOnlyStore<StudioRuntimeSnapshot> get runtimeStore => runtime;

  @override
  Future<void> dispose() async {
    await runtime.dispose();
    await super.dispose();
  }
}

final _boundary = GlobalKey();

Future<void> _mount(
  WidgetTester tester,
  StudioDependencies deps,
  Size size, {
  double inset = 0,
  double scale = 1,
  bool settle = true,
}) async {
  await tester.binding.setSurfaceSize(size);
  await tester.pumpWidget(
    RepaintBoundary(
      key: _boundary,
      child: StudioScope(
        deps: deps,
        child: MaterialApp(
          theme: StudioTheme.dark(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              size: size,
              textScaler: TextScaler.linear(scale),
              viewInsets: EdgeInsets.only(bottom: inset),
              viewPadding: const EdgeInsets.only(top: 44, bottom: 34),
              padding: EdgeInsets.only(top: 44, bottom: inset > 0 ? 0 : 34),
            ),
            child: child!,
          ),
          home: const StudioShellScreen(),
        ),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

Future<void> _capture(WidgetTester tester, String name) async {
  final output = Platform.environment['STUDIO_CODING_SCREENSHOTS'];
  if (output == null) return;
  final boundary =
      _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final rendered = await boundary.toImage(pixelRatio: 1);
    final data = await rendered.toByteData(format: ui.ImageByteFormat.png);
    await Directory(output).create(recursive: true);
    await File('$output/$name.png').writeAsBytes(data!.buffer.asUint8List());
    rendered.dispose();
  });
}

void _reachable(WidgetTester tester, String key, Size size, double inset) {
  final finder = find.byKey(Key(key));
  expect(finder, findsOneWidget);
  final rect = tester.getRect(finder);
  expect(rect.top, greaterThanOrEqualTo(44), reason: key);
  expect(
    rect.bottom,
    lessThanOrEqualTo(size.height - inset - (inset == 0 ? 34 : 0)),
    reason: key,
  );
  expect(rect.left, greaterThanOrEqualTo(0));
  expect(rect.right, lessThanOrEqualTo(size.width));
  expect(finder.hitTestable(), findsOneWidget, reason: key);
}

void main() {
  testWidgets('Mobile Files refreshes external changes without reopening', (
    tester,
  ) async {
    const size = Size(320, 740);
    const inset = 300.0;
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final root = Directory.systemTemp.createTempSync('coding_refresh_');
    addTearDown(() => root.deleteSync(recursive: true));
    final deps = await buildTestDeps(
      isMobile: true,
      appDataDirectory: root.path,
    );
    addTearDown(deps.dispose);
    await tester.runAsync(
      () => deps.codingController.setWorkspaceRoot(root.path),
    );
    await deps.shellController.selectWorkspace(StudioWorkspace.coding);
    await _mount(tester, deps, size, inset: inset, scale: 1.8);
    await tester.enterText(
      find.byKey(const Key('coding_prompt_input')),
      'Keep this draft',
    );
    await tester.tap(find.text('Files (0)'));
    await tester.pumpAndSettle();
    final refresh = find.byTooltip('Refresh directory').hitTestable();
    expect(refresh, findsOneWidget);
    expect(
      tester.getRect(refresh).bottom,
      lessThanOrEqualTo(size.height - inset),
    );
    final file = File('${root.path}/external.txt');
    for (final added in [true, false]) {
      if (added) {
        file.writeAsStringSync('External UTF-8 change: Montréal');
      } else {
        file.deleteSync();
      }
      await tester.runAsync(() async {
        final changed = deps.codingController.store.stream
            .firstWhere((state) => state.files.length == (added ? 1 : 0))
            .timeout(const Duration(seconds: 5));
        await tester.tap(refresh);
        await changed;
      });
      await tester.pumpAndSettle();
      expect(find.text('Files (${added ? 1 : 0})'), findsOneWidget);
      expect(
        find.byKey(const Key('coding_file_external.txt')),
        added ? findsOneWidget : findsNothing,
      );
      expect(deps.codingController.state.workspaceRoot, root.path);
    }
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('coding_prompt_input')))
          .controller!
          .text,
      'Keep this draft',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  setUpAll(() async {
    // Optional render font; product fonts are unchanged. Code may still use Ahem.
    final iconPath = Platform.environment['STUDIO_CODING_RENDER_ICONS'];
    if (iconPath != null) {
      final loader = FontLoader('MaterialIcons')
        ..addFont(
          Future.value(ByteData.sublistView(File(iconPath).readAsBytesSync())),
        );
      await loader.load();
    }
    final fontPath = Platform.environment['STUDIO_CODING_RENDER_FONT'];
    if (fontPath != null) {
      final loader = FontLoader('Roboto')
        ..addFont(
          Future.value(ByteData.sublistView(File(fontPath).readAsBytesSync())),
        );
      await loader.load();
    }
  });
  testWidgets('Framework Back dismisses file detail before leaving Coding', (
    tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final root = Directory.systemTemp.createTempSync('coding_back_');
    addTearDown(() => root.deleteSync(recursive: true));
    final deps = await buildTestDeps(
      isMobile: true,
      appDataDirectory: root.path,
    );
    addTearDown(deps.dispose);
    File('${root.path}/main.dart').writeAsStringSync('owned file');
    await tester.runAsync(
      () => deps.codingController.setWorkspaceRoot(root.path),
    );
    await tester.binding.setSurfaceSize(const Size(390, 844));
    await tester.pumpWidget(LlamadartStudioApp(dependencies: deps));
    await deps.shellController.selectWorkspace(StudioWorkspace.coding);
    await tester.pumpAndSettle();
    final prompt = find.byKey(const Key('coding_prompt_input'));
    await tester.enterText(prompt, 'Keep this draft');
    await tester.tap(find.text('Files (1)'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'main');
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('coding_file_main.dart')));
      await Future<void>.delayed(const Duration(milliseconds: 60));
    });
    await tester.pumpAndSettle();
    final detail = find.byKey(const Key('coding_back_to_files'));
    expect(detail, findsOneWidget);
    final scaffold = Scaffold.of(tester.element(detail));
    for (final end in [false, true]) {
      await tester.tap(
        find.byKey(
          Key(end ? 'toggle_inspector_button' : 'open_sidebar_drawer_button'),
        ),
      );
      await tester.pumpAndSettle();
      expect(end ? scaffold.isEndDrawerOpen : scaffold.isDrawerOpen, isTrue);
      expect(await tester.binding.handlePopRoute(), isTrue);
      await tester.pumpAndSettle();
      expect(end ? scaffold.isEndDrawerOpen : scaffold.isDrawerOpen, isFalse);
      expect(detail, findsOneWidget);
    }
    for (final section in ['Agent', 'Edits (0)']) {
      await tester.tap(find.text(section));
      await tester.pumpAndSettle();
      expect(await tester.binding.handlePopRoute(), isFalse);
      await tester.tap(find.text('Files (1)'));
      await tester.pumpAndSettle();
      expect(detail, findsOneWidget);
    }
    for (final end in [false, true]) {
      await tester.binding.setSurfaceSize(const Size(1100, 900));
      await tester.pumpAndSettle();
      expect(detail, findsNothing);
      final preview = find.byKey(const Key('coding_file_syntax_preview'));
      final resizedScaffold = Scaffold.of(tester.element(preview));
      if (end) {
        resizedScaffold.openEndDrawer();
      } else {
        resizedScaffold.openDrawer();
      }
      await tester.pumpAndSettle();
      await tester.binding.setSurfaceSize(const Size(390, 844));
      await tester.pumpAndSettle();
      expect(detail, findsOneWidget);
      expect(
        end ? resizedScaffold.isEndDrawerOpen : resizedScaffold.isDrawerOpen,
        isTrue,
      );
      expect(await tester.binding.handlePopRoute(), isTrue);
      await tester.pumpAndSettle();
      expect(
        end ? resizedScaffold.isEndDrawerOpen : resizedScaffold.isDrawerOpen,
        isFalse,
      );
      expect(detail, findsOneWidget);
    }
    expect(
      ModalRoute.of(tester.element(detail))!.popDisposition,
      RoutePopDisposition.pop,
    );
    await tester.tap(find.byKey(const Key('coding_use_context')));
    await tester.pumpAndSettle();
    expect(deps.codingController.state.includeSelectedFileContext, isFalse);
    unawaited(
      showDialog<void>(
        context: tester.element(detail),
        builder: (_) => const AlertDialog(title: Text('Overlay before detail')),
      ),
    );
    await tester.pumpAndSettle();
    expect(await tester.binding.handlePopRoute(), isTrue);
    await tester.pumpAndSettle();
    expect(find.text('Overlay before detail'), findsNothing);
    expect(detail, findsOneWidget);
    expect(await tester.binding.handlePopRoute(), isTrue);
    await tester.pumpAndSettle();
    expect(detail, findsNothing);
    expect(find.byKey(const Key('coding_file_main.dart')), findsOneWidget);
    expect(
      tester.widget<TextFormField>(find.byType(TextFormField)).initialValue,
      'main',
    );
    expect(
      tester.widget<TextField>(prompt).controller!.text,
      'Keep this draft',
    );
    expect(deps.codingController.state.includeSelectedFileContext, isFalse);
    expect(await tester.binding.handlePopRoute(), isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  for (final size in const [Size(360, 740), Size(390, 844)]) {
    for (final scale in [1.0, 1.8]) {
      for (final inset in [0.0, 300.0]) {
        testWidgets('Full shell composer ${size.width}/$scale/$inset', (
          tester,
        ) async {
          addTearDown(() => tester.binding.setSurfaceSize(null));
          final inference = _FileInference()..hold = true;
          final deps = await buildTestDeps(
            isMobile: true,
            inferencePort: inference,
          );
          addTearDown(deps.dispose);
          addTearDown(() {
            unawaited(inference.events.close());
          });
          await deps.shellController.selectWorkspace(StudioWorkspace.coding);
          await _mount(tester, deps, size, inset: inset, scale: scale);
          await tester.enterText(
            find.byKey(const Key('coding_prompt_input')),
            'Keep my draft',
          );
          _reachable(tester, 'coding_prompt_input', size, inset);
          _reachable(tester, 'coding_send_button', size, inset);
          expect(
            tester.getSize(find.byKey(const Key('coding_send_button'))).height,
            greaterThanOrEqualTo(44),
          );
          await _capture(
            tester,
            '${size.width.toInt()}-keyboard${inset.toInt()}-scale$scale',
          );
          await tester.tap(find.text('Files (0)'));
          await tester.pumpAndSettle();
          _reachable(tester, 'coding_send_button', size, inset);
          await tester.tap(find.text('Edits (0)'));
          await tester.pumpAndSettle();
          expect(
            tester
                .widget<TextField>(find.byKey(const Key('coding_prompt_input')))
                .controller!
                .text,
            'Keep my draft',
          );
          await tester.tap(find.byKey(const Key('coding_send_button')));
          await tester.pump(const Duration(milliseconds: 100));
          _reachable(tester, 'coding_stop_button', size, inset);
          for (final section in ['Agent', 'Files (0)', 'Edits (0)']) {
            await tester.tap(find.text(section));
            await tester.pump(const Duration(milliseconds: 100));
            _reachable(tester, 'coding_stop_button', size, inset);
          }
          await _capture(
            tester,
            '${size.width.toInt()}-running-scale$scale-inset$inset',
          );
          await tester.tap(find.byKey(const Key('coding_stop_button')));
          await tester.pumpAndSettle();
          expect(inference.cancellations, greaterThan(0));
          await tester.pumpWidget(const SizedBox.shrink());
        });
      }
    }
  }

  testWidgets(
    'Owned file opens reveal preview, retain drafts/filter/context and protect Revert',
    (tester) async {
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final inference = _FileInference();
      final root = Directory.systemTemp.createTempSync('coding_mobile_');
      addTearDown(() => root.deleteSync(recursive: true));
      final deps = await buildTestDeps(
        isMobile: true,
        appDataDirectory: root.path,
        inferencePort: inference,
      );
      addTearDown(deps.dispose);
      addTearDown(() {
        unawaited(inference.events.close());
      });
      final file = File('${root.path}/main.dart')..writeAsStringSync('before');
      File('${root.path}/README.md').writeAsStringSync('Owned readme');
      await tester.runAsync(
        () => deps.codingController.setWorkspaceRoot(root.path),
      );
      await tester.runAsync(
        () => deps.codingController
            .buildCodingTools()
            .firstWhere((t) => t.name == 'write')
            .invoke({'path': 'main.dart', 'content': 'after owned write'}),
      );
      await deps.shellController.selectWorkspace(StudioWorkspace.coding);
      await _mount(tester, deps, const Size(390, 844));
      final prompt = find.byKey(const Key('coding_prompt_input'));
      await tester.enterText(prompt, 'Retain draft');
      await tester.tap(find.text('Edits (1)'));
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byKey(const Key('coding_revert_change_0'))).height,
        greaterThanOrEqualTo(44),
      );
      await tester.runAsync(() async {
        await tester.tap(find.text('main.dart'));
        await Future<void>.delayed(const Duration(milliseconds: 60));
      });
      await tester.pumpAndSettle();
      final preview = find.byKey(const Key('coding_file_syntax_preview'));
      expect(preview, findsOneWidget);
      expect(
        find.descendant(
          of: preview,
          matching: find.textContaining(
            'after owned write',
            findRichText: true,
          ),
        ),
        findsWidgets,
      );
      expect(find.byKey(const Key('coding_back_to_files')), findsOneWidget);
      await _capture(tester, '390-file-detail');
      for (final size in const [Size(360, 740), Size(390, 844)]) {
        for (final scale in [1.0, 1.8]) {
          await _mount(tester, deps, size, inset: 300, scale: scale);
          _reachable(tester, 'coding_send_button', size, 300);
          expect(preview, findsOneWidget);
          expect(tester.takeException(), isNull);
          await _capture(
            tester,
            '${size.width.toInt()}-file-keyboard-scale$scale',
          );
        }
      }
      await _mount(tester, deps, const Size(390, 844));
      await tester.tap(find.byKey(const Key('coding_use_context')));
      await tester.pumpAndSettle();
      expect(deps.codingController.state.includeSelectedFileContext, isFalse);
      await tester.tap(find.byKey(const Key('coding_back_to_files')));
      await tester.pumpAndSettle();
      final filter = find.byType(TextFormField);
      await tester.enterText(filter, 'main');
      await tester.tap(find.text('Agent'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(prompt).controller!.text, 'Retain draft');
      await tester.tap(find.text('Files (2)'));
      await tester.pumpAndSettle();
      expect(find.text('main'), findsOneWidget);
      expect(find.byKey(const Key('coding_file_README.md')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await _mount(tester, deps, const Size(390, 844));
      await tester.tap(find.text('Files (2)'));
      await tester.pumpAndSettle();
      expect(find.text('main'), findsOneWidget);
      expect(tester.widget<TextField>(prompt).controller!.text, 'Retain draft');
      // Missing file after the list was populated must stay in Files with details.
      file.deleteSync();
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('coding_file_main.dart')));
        await Future<void>.delayed(const Duration(milliseconds: 60));
      });
      await tester.pumpAndSettle();
      expect(preview, findsNothing);
      expect(find.byKey(const Key('coding_error_banner')), findsOneWidget);
      await tester.tap(find.text('Details'));
      await tester.pumpAndSettle();
      expect(find.text('Choose folder'), findsOneWidget);
      expect(find.text('Model Hub'), findsNothing);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      // Restore then use the actual chat tool card's file action.
      file.writeAsStringSync('after owned write');
      await tester.runAsync(deps.codingController.refreshExplorer);
      inference.response = List.filled(
        30,
        'Owned conversation paragraph.',
      ).join('\n\n');
      await tester.tap(find.text('Agent'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('coding_send_button')));
        await Future<void>.delayed(const Duration(milliseconds: 60));
      });
      await tester.pumpAndSettle();
      final conversation = tester.widget<ListView>(
        find.byKey(const Key('coding_conversation')),
      );
      conversation.controller!.jumpTo(20);
      await tester.pump();
      final retainedOffset = conversation.controller!.offset;
      await tester.tap(find.text('Files (2)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Agent'));
      await tester.pumpAndSettle();
      expect(conversation.controller!.offset, retainedOffset);
      await tester.ensureVisible(find.text('write({"path":"main.dart"})'));
      await tester.pumpAndSettle();
      await _capture(tester, '390-task-tool-card');
      await tester.runAsync(() async {
        await tester.tap(find.text('write({"path":"main.dart"})'));
        await Future<void>.delayed(const Duration(milliseconds: 60));
      });
      await tester.pumpAndSettle();
      expect(preview, findsOneWidget);
      expect(deps.codingController.state.includeSelectedFileContext, isFalse);
      // Concurrent edits must not be discarded by the real Revert UI.
      file.writeAsStringSync('concurrent edit');
      await tester.tap(find.text('Edits (1)'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('coding_revert_change_0')));
        await Future<void>.delayed(const Duration(milliseconds: 60));
      });
      await tester.pumpAndSettle();
      expect(file.readAsStringSync(), 'concurrent edit');
      expect(
        deps.codingController.state.recentChanges.single.reverted,
        isFalse,
      );
      file.writeAsStringSync('after owned write');
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('coding_revert_change_0')));
        for (var i = 0; i < 250; i++) {
          if (deps.codingController.state.recentChanges.single.reverted) break;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await tester.pumpAndSettle();
      expect(file.readAsStringSync(), 'before');
      expect(deps.codingController.state.recentChanges.single.reverted, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('Compact setup, loading and errors keep controls usable', (
    tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final inference = _RuntimeInference();
    final deps = await buildTestDeps(isMobile: true, inferencePort: inference);
    addTearDown(deps.dispose);
    await deps.shellController.selectWorkspace(StudioWorkspace.coding);
    deps.codingController.setAllowShellCommandTool(true);
    expect(deps.codingController.state.allowShellCommandTool, isFalse);
    for (final size in const [Size(360, 740), Size(390, 844)]) {
      for (final scale in [1.0, 1.8]) {
        await _mount(tester, deps, size, inset: 300, scale: scale);
        await tester.enterText(
          find.byKey(const Key('coding_prompt_input')),
          'Keep setup draft',
        );
        await tester.tap(find.byKey(const Key('coding_setup_toggle')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('coding_shell_toggle')), findsNothing);
        expect(
          find.byKey(const Key('coding_manual_path_button')),
          findsNothing,
        );
        _reachable(tester, 'coding_setup_done', size, 300);
        expect(tester.takeException(), isNull);
        await _capture(
          tester,
          '${size.width.toInt()}-setup-large$scale-keyboard',
        );
        await tester.tap(find.byKey(const Key('coding_setup_done')));
        await tester.pumpAndSettle();
        _reachable(tester, 'coding_send_button', size, 300);
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('coding_prompt_input')))
              .controller!
              .text,
          'Keep setup draft',
        );
        inference.runtime.set(
          StudioRuntimeSnapshot(
            phase: StudioEnginePhase.loading,
            activeDescriptor:
                CodingWorkspaceController.recommendedCodingModels.last,
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));
        _reachable(tester, 'coding_send_button', size, 300);
        expect(tester.takeException(), isNull);
        await _capture(
          tester,
          '${size.width.toInt()}-loading-large$scale-keyboard',
        );
        inference.runtime.set(
          const StudioRuntimeSnapshot(
            phase: StudioEnginePhase.unloaded,
            errorMessage: 'Model unavailable. Full runtime recovery details.',
          ),
        );
        await tester.pumpAndSettle();
        _reachable(tester, 'coding_send_button', size, 300);
        await tester.tap(find.text('Details'));
        await tester.pumpAndSettle();
        expect(find.text('Model Hub'), findsOneWidget);
        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
        inference.runtime.set(
          const StudioRuntimeSnapshot(phase: StudioEnginePhase.ready),
        );
        await tester.pumpAndSettle();
      }
    }
    // Network setup remains available without offering a local subprocess.
    await _mount(tester, deps, const Size(390, 844));
    expect(find.byKey(const Key('coding_pick_folder_button')), findsOneWidget);
    await tester.tap(find.byKey(const Key('coding_setup_toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('coding_open_mcp_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('mcp_toggle_add_form_button')));
    await tester.pumpAndSettle();
    expect(find.text('Stdio'), findsNothing);
    expect(find.byKey(const Key('mcp_command_input')), findsNothing);
    expect(find.byKey(const Key('mcp_url_input')), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('mcp_name_input')),
      'Mobile network',
    );
    await tester.enterText(
      find.byKey(const Key('mcp_url_input')),
      'https://example.invalid/mcp',
    );
    final save = find.byKey(const Key('mcp_save_only_button'));
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    final server = deps.mcpManager.state.servers.singleWhere(
      (s) => s.config.name == 'Mobile network',
    );
    expect(server.config.transportType, McpTransportType.streamableHttp);
    expect(server.config.command, isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Desktop full shell retains explorer and real file preview', (
    tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final deps = await buildTestDeps();
    addTearDown(deps.dispose);
    final root = Directory.systemTemp.createTempSync('coding_desktop_');
    addTearDown(() => root.deleteSync(recursive: true));
    File('${root.path}/desktop.dart').writeAsStringSync('desktop owned file');
    await tester.runAsync(
      () => deps.codingController.setWorkspaceRoot(root.path),
    );
    await deps.shellController.selectWorkspace(StudioWorkspace.coding);
    await _mount(tester, deps, const Size(1280, 900));
    await tester.tap(find.byKey(const Key('coding_explorer_toggle')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('coding_file_desktop.dart')));
      await Future<void>.delayed(const Duration(milliseconds: 60));
    });
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('coding_file_syntax_preview')), findsOneWidget);
    expect(find.text('Explorer'), findsOneWidget);
    _reachable(tester, 'coding_send_button', const Size(1280, 900), 0);
    expect(tester.takeException(), isNull);
    await _capture(tester, '1280-desktop-file');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Full shell long approval keeps both decisions reachable', (
    tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final deps = await buildTestDeps();
    addTearDown(deps.dispose);
    final root = Directory.systemTemp.createTempSync('coding_approval_');
    addTearDown(() => root.deleteSync(recursive: true));
    final workspace = Directory(
      '${root.path}/${List.filled(10, 'long_workspace_component').join('/')}',
    )..createSync(recursive: true);
    await tester.runAsync(
      () => deps.codingController.setWorkspaceRoot(workspace.path),
    );
    deps.codingController.setAllowShellCommandTool(true);
    final result = deps.codingController
        .buildCodingTools()
        .firstWhere((t) => t.name == 'bash')
        .invoke({
          'command': List.filled(100, 'never execute this command').join('\n'),
        });
    await deps.shellController.selectWorkspace(StudioWorkspace.coding);
    for (final size in const [Size(360, 740), Size(390, 844)]) {
      await _mount(tester, deps, size, inset: 300, scale: 1.8);
      _reachable(tester, 'coding_reject_bash_button', size, 300);
      _reachable(tester, 'coding_approve_bash_button', size, 300);
      _reachable(tester, 'coding_approval_stop_button', size, 300);
      await _capture(tester, '${size.width.toInt()}-approval-large-keyboard');
      expect(tester.takeException(), isNull);
    }
    await tester.tap(find.byKey(const Key('coding_reject_bash_button')));
    await tester.pumpAndSettle();
    expect((await result as Map)['rejected'], isTrue);
    expect(deps.codingController.state.pendingShellApproval, isNull);
    final cancelled = deps.codingController
        .buildCodingTools()
        .firstWhere((t) => t.name == 'bash')
        .invoke({'command': 'never execute this cancelled command'});
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('coding_approval_stop_button')));
    await tester.pumpAndSettle();
    expect((await cancelled as Map)['rejected'], isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
