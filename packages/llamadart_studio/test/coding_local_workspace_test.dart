@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
// Keep Material types compatible with flutter_markdown (see README).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart_studio/llamadart_studio.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';

import 'studio_widget_test_helpers.dart';

const _createKey = Key('coding_create_local_workspace_button');
const _folderKey = Key('coding_pick_folder_button');

Future<void> _mount(WidgetTester tester, StudioDependencies deps) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
  await tester.pumpWidget(LlamadartStudioApp(dependencies: deps));
  await deps.shellController.selectWorkspace(StudioWorkspace.coding);
  await tester.pumpAndSettle();
}

Future<void> _waitFor(WidgetTester tester, bool Function() ready) async {
  final elapsed = Stopwatch()..start();
  while (!ready()) {
    if (elapsed.elapsed > const Duration(seconds: 5)) {
      throw TestFailure('Coding workspace did not reach the expected state.');
    }
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  }
  await tester.pumpAndSettle();
}

Future<void> _openSetup(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('coding_setup_toggle')));
  await tester.pumpAndSettle();
}

Future<void> _selectLocal(WidgetTester tester, String root) async {
  await _openSetup(tester);
  await tester.tap(
    find.byKey(const Key('coding_open_local_workspaces_button')),
  );
  await _waitFor(
    tester,
    () => find.byKey(Key('coding_open_local_$root')).evaluate().isNotEmpty,
  );
  await tester.tap(find.byKey(Key('coding_open_local_$root')));
  await _waitFor(
    tester,
    () => tester.widget<IconButton>(find.byKey(_folderKey)).onPressed != null,
  );
}

void main() {
  late Directory owned;
  setUp(() {
    owned = Directory.systemTemp.createTempSync('studio_owned_coding_');
  });
  tearDown(() {
    owned.deleteSync(recursive: true);
  });

  test('created roots retain nested tool bytes and restore through fresh dependencies', () async {
    final kv = InMemoryKeyValueStore();
    final deps = await buildTestDeps(
      isMobile: true,
      appDataDirectory: owned.path,
      keyValueStore: kv,
    );
    addTearDown(deps.dispose);
    expect(deps.codingController.state.workspaceRoot, isNull);
    final roots = await Future.wait(
      List.generate(12, (_) => deps.createLocalCodingWorkspace()),
    );
    expect(roots.toSet(), hasLength(12));
    for (final root in roots) {
      expect(Directory(root).parent.path, '${owned.path}/coding_workspaces');
      expect(Directory(root).existsSync(), isTrue);
    }
    await Directory('${owned.path}/coding_workspaces/not_a_workspace').create();
    await File('${owned.path}/coding_workspaces/workspace_not_a_directory')
        .writeAsString('keep');
    if (!Platform.isWindows) {
      await Link('${owned.path}/coding_workspaces/workspace_external_link')
          .create(owned.path);
    }
    expect((await deps.listLocalCodingWorkspaces()).toSet(), roots.toSet());
    final root = roots.first;
    await deps.codingController.setWorkspaceRoot(root);
    final tools = deps.codingController.buildCodingTools();
    expect(tools.map((tool) => tool.name), isNot(contains('bash')));
    final write = tools.firstWhere((tool) => tool.name == 'write');
    await write.invoke({
      'path': 'src/nested/main.dart',
      'content': 'const label = "Montréal";\n',
    });
    await tools.firstWhere((tool) => tool.name == 'edit').invoke({
      'path': 'src/nested/main.dart',
      'findText': 'Montréal',
      'replaceText': 'Québec',
    });
    final read = await tools.firstWhere((tool) => tool.name == 'read').invoke({
      'path': 'src/nested/main.dart',
    });
    expect(read.toString(), contains('Québec'));
    await deps.codingController.openDirectory('src/nested');
    expect(deps.codingController.state.files.single.name, 'main.dart');
    expect(
      await deps.codingController.openFile('src/nested/main.dart'),
      isTrue,
    );
    expect(
      deps.codingController.state.selectedFileSlice!.content,
      'const label = "Québec";\n',
    );
    expect(
      File('$root/src/nested/main.dart').readAsStringSync(),
      'const label = "Québec";\n',
    );
    deps.codingController.setPromptDraftForWorkspace(root, 'Keep this draft');
    await deps.codingController.setWorkspaceRoot(roots.last);
    expect(
      deps.codingController.promptDraftForWorkspace(root),
      'Keep this draft',
    );
    expect(Directory(roots.last).listSync(), isEmpty);
    expect(
      File('$root/src/nested/main.dart').readAsStringSync(),
      contains('Québec'),
    );
    await deps.codingController.setWorkspaceRoot(root);
    final restored = await buildTestDeps(
      isMobile: true,
      appDataDirectory: owned.path,
      keyValueStore: kv,
    );
    addTearDown(restored.dispose);
    expect(restored.codingController.state.workspaceRoot, root);
    await restored.codingController.openDirectory('src/nested');
    expect(restored.codingController.state.files.single.name, 'main.dart');
    await restored.codingController.openFile('src/nested/main.dart');
    expect(
      restored.codingController.state.selectedFileSlice!.content,
      'const label = "Québec";\n',
    );
    expect(owned.listSync().map((entry) => entry.path), [
      '${owned.path}/coding_workspaces',
    ]);
  });

  testWidgets(
    'mobile default action uses application support and opens real file detail Copy',
    (tester) async {
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      final messenger = tester.binding.defaultBinaryMessenger;
      final supportPath = Completer<String>();
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'getApplicationSupportDirectory');
        return supportPath.future;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final deps = await buildTestDeps(isMobile: true);
      addTearDown(deps.dispose);
      await _mount(tester, deps);
      expect(deps.codingController.state.workspaceRoot, isNull);
      expect(find.byKey(_createKey).hitTestable(), findsOneWidget);
      await tester.runAsync(() => tester.tap(find.byKey(_createKey)));
      await tester.pump();
      expect(find.text('Creating workspace…'), findsOneWidget);
      expect(
        tester.widget<TextButton>(find.byKey(_createKey)).onPressed,
        isNull,
      );
      expect(
        tester.widget<IconButton>(find.byKey(_folderKey)).onPressed,
        isNull,
      );
      expect(deps.codingController.state.workspaceRoot, isNull);
      await tester.runAsync(() async {
        supportPath.complete(owned.path);
      });
      await _waitFor(
        tester,
        () =>
            (deps.codingController.state.workspaceRoot != null ||
                deps.codingController.state.lastError != null) &&
            tester.widget<IconButton>(find.byKey(_folderKey)).onPressed != null,
      );
      expect(
        deps.codingController.state.workspaceRoot,
        isNotNull,
        reason:
            'Create local workspace must make an accessible on-disk directory',
      );
      final root = deps.codingController.state.workspaceRoot!;
      expect(
        Directory(root).parent.path,
        '${owned.path}/llamadart_studio/coding_workspaces',
      );
      expect(find.textContaining('Local workspace created.'), findsOneWidget);
      await tester.runAsync(() async {
        final write = deps.codingController.buildCodingTools().firstWhere(
          (tool) => tool.name == 'write',
        );
        await write.invoke({'path': 'src/main.dart', 'content': 'owned text'});
        await deps.codingController.openDirectory('src');
      });
      await tester.pumpAndSettle();
      await tester.tap(find.text('Files (1)'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('coding_file_src/main.dart')));
      });
      await _waitFor(
        tester,
        () =>
            find.byKey(const Key('coding_back_to_files')).evaluate().isNotEmpty,
      );
      expect(find.byKey(const Key('coding_back_to_files')), findsOneWidget);
      expect(find.text('Copy'), findsOneWidget);
      String? copiedText;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copiedText = (call.arguments as Map)['text'] as String;
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await tester.tap(find.text('Copy'));
      await tester.pumpAndSettle();
      expect(copiedText, 'owned text');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('failed local creation preserves the selected root and draft', (
    tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final blocked = File('${owned.path}/not_a_directory')
      ..writeAsStringSync('keep');
    final deps = await buildTestDeps(
      isMobile: true,
      appDataDirectory: blocked.path,
    );
    addTearDown(deps.dispose);
    await tester.runAsync(
      () => deps.codingController.setWorkspaceRoot(owned.path),
    );
    await _mount(tester, deps);
    await tester.enterText(
      find.byKey(const Key('coding_prompt_input')),
      'Keep this prompt',
    );
    await tester.tap(find.byKey(const Key('coding_setup_toggle')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(
        find.byKey(const Key('coding_create_local_workspace_setup_button')),
      );
    });
    await _waitFor(
      tester,
      () => find
          .textContaining('Could not create a local workspace.')
          .evaluate()
          .isNotEmpty,
    );
    expect(deps.codingController.state.workspaceRoot, owned.path);
    expect(find.text('Keep this prompt'), findsOneWidget);
    expect(blocked.readAsStringSync(), 'keep');
    expect(
      find.textContaining('Could not create a local workspace.'),
      findsOneWidget,
    );
    expect(find.textContaining('Local workspace created.'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final result in ['null', 'throw', 'inaccessible']) {
    testWidgets(
      'mobile picker $result keeps root and draft with actionable recovery',
      (tester) async {
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final picker = _DirectoryPicker();
        FilePicker.platform = picker;
        final deps = await buildTestDeps(
          isMobile: true,
          appDataDirectory: owned.path,
        );
        addTearDown(deps.dispose);
        await tester.runAsync(
          () => deps.codingController.setWorkspaceRoot(owned.path),
        );
        await _mount(tester, deps);
        await tester.enterText(
          find.byKey(const Key('coding_prompt_input')),
          'Keep picker draft',
        );
        await tester.tap(find.byKey(_folderKey));
        if (result == 'throw') {
          picker.result.completeError(PlatformException(code: 'unavailable'));
        } else {
          picker.result.complete(
            result == 'inaccessible' ? '${owned.path}/missing' : null,
          );
        }
        await _waitFor(
          tester,
          () => find.text('Create local').evaluate().isNotEmpty,
        );
        expect(deps.codingController.state.workspaceRoot, owned.path);
        expect(find.text('Keep picker draft'), findsOneWidget);
        expect(find.text('Create local'), findsOneWidget);
        if (result == 'null') {
          expect(
            find.text(
              'No folder selected. You can create a local workspace instead.',
            ),
            findsOneWidget,
          );
          expect(deps.codingController.state.lastError, isNull);
        } else {
          if (result == 'inaccessible') {
            expect(deps.codingController.state.lastError, isNotNull);
          }
          expect(
            find.textContaining(
              RegExp('could not', caseSensitive: false),
              findRichText: true,
            ),
            findsWidgets,
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'desktop cancellation stays silent with no local creation action',
    (tester) async {
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final picker = _DirectoryPicker();
      FilePicker.platform = picker;
      final deps = await buildTestDeps(appDataDirectory: owned.path);
      addTearDown(deps.dispose);
      await _mount(tester, deps);
      expect(find.byKey(_createKey), findsNothing);
      await tester.tap(find.byKey(_folderKey));
      picker.result.complete(null);
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
      expect(deps.codingController.state.workspaceRoot, isNull);
      expect(deps.createLocalCodingWorkspace, throwsUnsupportedError);
      expect(deps.listLocalCodingWorkspaces, throwsUnsupportedError);
      expect(owned.listSync(), isEmpty);
    },
  );

  testWidgets('desktop picker still opens an ordinary accessible folder', (
    tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final picker = _DirectoryPicker();
    FilePicker.platform = picker;
    final deps = await buildTestDeps();
    addTearDown(deps.dispose);
    await _mount(tester, deps);
    await tester.runAsync(() async {
      picker.result = Completer<String?>();
      final selected = deps.codingController.store.stream.firstWhere(
        (state) => state.workspaceRoot != null || state.lastError != null,
      );
      await tester.tap(find.byKey(_folderKey));
      picker.result.complete(owned.path);
      await selected.timeout(const Duration(seconds: 3));
    });
    await tester.pumpAndSettle();
    expect(deps.codingController.state.workspaceRoot, owned.path);
    expect(find.byType(SnackBar), findsNothing);
    expect(find.byKey(_createKey), findsNothing);
  });

  testWidgets('local folder activation failure never reports success', (
    tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final deps = await buildTestDeps(
      isMobile: true,
      appDataDirectory: owned.path,
      keyValueStore: _RejectWorkspaceStore(),
    );
    addTearDown(deps.dispose);
    await _mount(tester, deps);
    await tester.runAsync(() async {
      await tester.tap(find.byKey(_createKey));
    });
    await _waitFor(
      tester,
      () => find
          .textContaining('The local folder could not be opened.')
          .evaluate()
          .isNotEmpty,
    );
    expect(
      Directory('${owned.path}/coding_workspaces').listSync(),
      hasLength(1),
    );
    expect(deps.codingController.state.workspaceRoot, isNull);
    expect(deps.codingController.state.activeCoreTools, isEmpty);
    expect(
      find.textContaining('The local folder could not be opened.'),
      findsOneWidget,
    );
    expect(find.textContaining('Local workspace created.'), findsNothing);
    expect(find.byKey(_createKey).hitTestable(), findsOneWidget);
  });

  testWidgets(
    'earlier local work reopens through UI before and after restart',
    (tester) async {
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final kv = InMemoryKeyValueStore();
      final deps = await buildTestDeps(
        isMobile: true,
        appDataDirectory: owned.path,
        keyValueStore: kv,
      );
      addTearDown(deps.dispose);
      await _mount(tester, deps);
      await tester.tap(find.byKey(_createKey));
      await _waitFor(
        tester,
        () =>
            deps.codingController.state.workspaceRoot != null &&
            tester.widget<IconButton>(find.byKey(_folderKey)).onPressed != null,
      );
      final first = deps.codingController.state.workspaceRoot!;
      await tester.runAsync(() async {
        await deps.codingController
            .buildCodingTools()
            .firstWhere((t) => t.name == 'write')
            .invoke({
              'path': 'src/prior_work.txt',
              'content': 'Montréal retained',
            });
      });
      await tester.enterText(
        find.byKey(const Key('coding_prompt_input')),
        'First workspace draft',
      );
      await _openSetup(tester);
      await tester.tap(
        find.byKey(const Key('coding_create_local_workspace_setup_button')),
      );
      await _waitFor(
        tester,
        () =>
            deps.codingController.state.workspaceRoot != first &&
            tester.widget<IconButton>(find.byKey(_folderKey)).onPressed != null,
      );
      final second = deps.codingController.state.workspaceRoot!;
      await _openSetup(tester);
      await tester.tap(
        find.byKey(const Key('coding_open_local_workspaces_button')),
      );
      await _waitFor(
        tester,
        () => find.byKey(Key('coding_open_local_$first')).evaluate().isNotEmpty,
      );
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await _waitFor(
        tester,
        () =>
            tester.widget<IconButton>(find.byKey(_folderKey)).onPressed != null,
      );
      expect(deps.codingController.state.workspaceRoot, second);
      await _selectLocal(tester, first);
      expect(deps.codingController.state.workspaceRoot, first);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('coding_prompt_input')))
            .controller!
            .text,
        'First workspace draft',
      );
      await _selectLocal(tester, second);
      expect(deps.codingController.state.workspaceRoot, second);
      await tester.pumpWidget(const SizedBox.shrink());
      final fresh = (await tester.runAsync(
        () => buildTestDeps(
          isMobile: true,
          appDataDirectory: owned.path,
          keyValueStore: kv,
        ),
      ))!;
      addTearDown(fresh.dispose);
      expect(fresh.codingController.state.workspaceRoot, second);
      await _mount(tester, fresh);
      await _selectLocal(tester, first);
      expect(fresh.codingController.state.workspaceRoot, first);
      await tester.runAsync(() async {
        final result = await fresh.codingController
            .buildCodingTools()
            .firstWhere((t) => t.name == 'read')
            .invoke({'path': 'src/prior_work.txt'});
        expect(result.toString(), contains('Montréal retained'));
      });
      expect(
        File('$first/src/prior_work.txt').readAsStringSync(),
        'Montréal retained',
      );
      expect(Directory(second).existsSync(), isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'local folder picker shows progress and cancels without creating files',
    (tester) async {
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      final messenger = tester.binding.defaultBinaryMessenger;
      final support = Completer<String>();
      messenger.setMockMethodCallHandler(channel, (_) => support.future);
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final deps = await buildTestDeps(isMobile: true);
      addTearDown(deps.dispose);
      await _mount(tester, deps);
      await _openSetup(tester);
      await tester.tap(
        find.byKey(const Key('coding_open_local_workspaces_button')),
      );
      await tester.pump();
      expect(
        find.byKey(const Key('coding_local_workspaces_loading')),
        findsOneWidget,
      );
      support.complete(owned.path);
      await _waitFor(
        tester,
        () => find
            .text('No local workspaces yet. Create one from Coding setup.')
            .evaluate()
            .isNotEmpty,
      );
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(deps.codingController.state.workspaceRoot, isNull);
      expect(owned.listSync(), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

class _DirectoryPicker extends FilePicker {
  var result = Completer<String?>();

  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    bool lockParentWindow = false,
    String? initialDirectory,
  }) => result.future;
}

class _RejectWorkspaceStore extends InMemoryKeyValueStore {
  @override
  Future<void> writeString(String key, String value) async {
    if (value.contains('/coding_workspaces/')) {
      throw StateError('Storage unavailable');
    }
    await super.writeString(key, value);
  }
}
