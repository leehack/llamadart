@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart_studio/llamadart_studio.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';

import 'studio_widget_test_helpers.dart';

const _v1 = 'studio.coding.workspace_root.v1';
const _v2 = 'studio.coding.workspace_root.v2';
const _nested = 'src/nested/main.dart';
const _bytes = 'const label = "Québec ✓";\n';
const _recovery = 'Open local workspace';

Map<String, Object?> _owned(String id) => {
  'version': 2,
  'kind': 'appOwned',
  'id': id,
};

Map<String, Object?> _absolute(String path) => {
  'version': 2,
  'kind': 'absolute',
  'path': path,
};

Future<Object?> _readV2(KeyValueStore kv) async {
  final raw = await kv.readString(_v2);
  return raw == null ? null : jsonDecode(raw);
}

List<String> _tree(Directory root) =>
    root
        .listSync(recursive: true, followLinks: false)
        .map((e) => e.path)
        .toList()
      ..sort();

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

void main() {
  late Directory temp;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('studio_relocation_');
  });
  tearDown(() {
    temp.deleteSync(recursive: true);
  });

  Future<StudioDependencies> deps(String appData, KeyValueStore kv) async {
    final result = await buildTestDeps(
      isMobile: true,
      appDataDirectory: appData,
      keyValueStore: kv,
    );
    addTearDown(result.dispose);
    return result;
  }

  test('owned root follows its stable ID across app data moves', () async {
    final kv = InMemoryKeyValueStore();
    final first = '${temp.path}/A';
    final original = await deps(first, kv);
    final root = await original.createLocalCodingWorkspace();
    final id = root.split('/').last;
    await original.codingController.setWorkspaceRoot(root);
    await original.codingController
        .buildCodingTools()
        .firstWhere((tool) => tool.name == 'write')
        .invoke({'path': _nested, 'content': _bytes});
    expect(await _readV2(kv), _owned(id));
    expect(await kv.readString(_v1), isNull);
    await original.dispose();

    var current = first;
    for (final next in ['${temp.path}/B', '${temp.path}/C']) {
      await Directory(current).rename(next);
      expect(Directory(current).existsSync(), isFalse);
      current = next;
      final restored = await deps(current, kv);
      final expected = '$current/coding_workspaces/$id';
      expect(restored.codingController.state.lastError, isNull);
      expect(restored.codingController.state.workspaceRoot, expected);
      expect(await restored.codingController.openFile(_nested), isTrue);
      expect(
        restored.codingController.state.selectedFileSlice!.content,
        _bytes,
      );
      expect(File('$expected/$_nested').readAsBytesSync(), utf8.encode(_bytes));
      expect(await restored.listLocalCodingWorkspaces(), [expected]);
      await restored.dispose();
    }
  });

  test('owned and external selections keep their kind', () async {
    final kv = InMemoryKeyValueStore();
    final appData = '${temp.path}/app';
    final first = await deps(appData, kv);
    final owned = await first.createLocalCodingWorkspace();
    final id = owned.split('/').last;
    // An external folder shaped like an owned one must stay an exact path.
    final external = Directory('${temp.path}/other/coding_workspaces/$id')
      ..createSync(recursive: true);
    for (final (root, record) in [
      (owned, _owned(id)),
      (external.path, _absolute(external.path)),
      (owned, _owned(id)),
      (external.path, _absolute(external.path)),
    ]) {
      await first.codingController.setWorkspaceRoot(root);
      expect(first.codingController.state.workspaceRoot, root);
      expect(await _readV2(kv), record);
      final fresh = await deps(appData, kv);
      expect(fresh.codingController.state.workspaceRoot, root);
      await fresh.dispose();
    }
    expect(await kv.readString(_v1), isNull);
  });

  test('legacy roots upgrade only through successful selection', () async {
    final appData = '${temp.path}/app';
    final setup = await deps(appData, InMemoryKeyValueStore());
    final owned = await setup.createLocalCodingWorkspace();
    final external = Directory('${temp.path}/external')..createSync();
    for (final (root, record) in [
      (owned, _owned(owned.split('/').last)),
      (external.path, _absolute(external.path)),
    ]) {
      final kv = InMemoryKeyValueStore({_v1: root});
      final restored = await deps(appData, kv);
      expect(restored.codingController.state.workspaceRoot, root);
      expect(await _readV2(kv), record);
      expect(await kv.readString(_v1), root);
    }
  });

  test('stale legacy root is never remapped to a same-named folder', () async {
    final setup = await deps('${temp.path}/old', InMemoryKeyValueStore());
    final stale = await setup.createLocalCodingWorkspace();
    await setup.dispose();
    await Directory('${temp.path}/old').rename('${temp.path}/app');
    final kv = InMemoryKeyValueStore({_v1: stale});
    final before = _tree(temp);
    final restored = await deps('${temp.path}/app', kv);
    expect(restored.codingController.state.workspaceRoot, isNull);
    expect(restored.codingController.state.lastError, contains(_recovery));
    expect(await kv.readString(_v1), stale);
    expect(await kv.readString(_v2), isNull);
    expect(_tree(temp), before);
  });

  test('present v2 records never fall back to v1 or another folder', () async {
    final appData = '${temp.path}/app';
    final setup = await deps(appData, InMemoryKeyValueStore());
    final valid = await setup.createLocalCodingWorkspace();
    final namespace = '$appData/coding_workspaces';
    File('$namespace/workspace_file').writeAsStringSync('keep');
    Directory('$namespace/workspace_outer/workspace_inner')
        .createSync(recursive: true);
    final outside = Directory('${temp.path}/outside/workspace_link')
      ..createSync(recursive: true);
    Link('$namespace/workspace_link').createSync(outside.path);
    final before = _tree(temp);
    final unreadable = [
      'not json',
      jsonEncode({..._owned('workspace_x'), 'version': 3}),
      jsonEncode({'version': 2, 'kind': 'other', 'id': 'workspace_x'}),
      jsonEncode({..._owned('workspace_x'), 'extra': true}),
      for (final id in [
        '../workspace_x',
        'workspace_outer/workspace_inner',
        r'workspace_a\b',
        'workspace_',
        'workspace_a%2Fb',
        'workspace_a\u0000',
        valid,
      ])
        jsonEncode(_owned(id)),
      jsonEncode(_absolute('relative/path')),
    ];
    for (final raw in [
      for (final value in unreadable) (value, 'could not be read'),
      for (final id in [
        'workspace_missing',
        'workspace_file',
        'workspace_link',
      ])
        (jsonEncode(_owned(id)), 'is unavailable'),
    ]) {
      final kv = InMemoryKeyValueStore({_v2: raw.$1, _v1: valid});
      final restored = await deps(appData, kv);
      expect(
        restored.codingController.state.workspaceRoot,
        isNull,
        reason: raw.$1,
      );
      expect(restored.codingController.state.lastError, contains(raw.$2));
      expect(restored.codingController.state.lastError, contains(_recovery));
      expect(await kv.readString(_v2), raw.$1);
      expect(await kv.readString(_v1), valid);
      await restored.dispose();
    }
    expect(_tree(temp), before);
  });

  test('symlinked owned namespace is rejected', () async {
    final real = await deps('${temp.path}/real', InMemoryKeyValueStore());
    final root = await real.createLocalCodingWorkspace();
    Directory('${temp.path}/app').createSync();
    Link('${temp.path}/app/coding_workspaces')
        .createSync('${temp.path}/real/coding_workspaces');
    final kv = InMemoryKeyValueStore({
      _v2: jsonEncode(_owned(root.split('/').last)),
    });
    final restored = await deps('${temp.path}/app', kv);
    expect(restored.codingController.state.workspaceRoot, isNull);
    expect(restored.codingController.state.lastError, contains(_recovery));
    await restored.codingController.setWorkspaceRoot(
      '${temp.path}/app/coding_workspaces/${root.split('/').last}',
    );
    expect(
      (await _readV2(kv) as Map)['kind'],
      'absolute',
      reason: 'a linked namespace never proves ownership',
    );
  });

  test('failed root save preserves prior selection, draft and bytes', () async {
    final kv = _RejectRootStore();
    final appData = '${temp.path}/app';
    final current = await deps(appData, kv);
    final a = await current.createLocalCodingWorkspace();
    final b = await current.createLocalCodingWorkspace();
    await current.codingController.setWorkspaceRoot(a);
    await current.codingController
        .buildCodingTools()
        .firstWhere((tool) => tool.name == 'write')
        .invoke({'path': _nested, 'content': _bytes});
    current.codingController.setPromptDraftForWorkspace(a, 'Keep draft');
    final saved = await kv.readString(_v2);
    kv.reject = true;
    await current.codingController.setWorkspaceRoot(b);
    expect(current.codingController.state.workspaceRoot, a);
    expect(current.codingController.state.lastError, contains('unavailable'));
    expect(current.codingController.promptDraftForWorkspace(a), 'Keep draft');
    expect(await kv.readString(_v2), saved);
    expect(File('$a/$_nested').readAsBytesSync(), utf8.encode(_bytes));
    kv.reject = false;
    final fresh = await deps(appData, kv);
    expect(fresh.codingController.state.workspaceRoot, a);
  });

  testWidgets('a storage outage preserves the owned root across a later move', (
    tester,
  ) async {
    var support = '${temp.path}/supportA';
    var unavailable = false;
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) async {
      if (unavailable) throw PlatformException(code: 'unavailable');
      return support;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.runAsync(() async {
      const id = 'workspace_abc';
      final saved = jsonEncode(_owned(id));
      final kv = InMemoryKeyValueStore({_v2: saved});
      final root = '$support/llamadart_studio/coding_workspaces/$id';
      final file = File('$root/$_nested')..createSync(recursive: true);
      file.writeAsStringSync(_bytes);
      final other = Directory(
        '$support/llamadart_studio/coding_workspaces/workspace_def',
      )..createSync();
      final current = await buildTestDeps(isMobile: true, keyValueStore: kv);
      addTearDown(current.dispose);
      expect(current.codingController.state.workspaceRoot, root);
      current.codingController.setPromptDraftForWorkspace(root, 'Keep draft');
      unavailable = true;
      await current.codingController.setWorkspaceRoot(other.path);
      expect(current.codingController.state.workspaceRoot, root);
      expect(current.codingController.state.lastError, contains(_recovery));
      expect(
        current.codingController.promptDraftForWorkspace(root),
        'Keep draft',
      );
      expect(await kv.readString(_v2), saved);
      expect(file.readAsBytesSync(), utf8.encode(_bytes));
      await current.dispose();
      final moved = '${temp.path}/supportB';
      await Directory(support).rename(moved);
      support = moved;
      unavailable = false;
      final restored = await buildTestDeps(isMobile: true, keyValueStore: kv);
      addTearDown(restored.dispose);
      final expected = '$support/llamadart_studio/coding_workspaces/$id';
      expect(restored.codingController.state.workspaceRoot, expected);
      expect(restored.codingController.state.lastError, isNull);
      expect(await kv.readString(_v2), saved);
      expect(File('$expected/$_nested').readAsBytesSync(), utf8.encode(_bytes));
    });
  });

  testWidgets('unavailable app storage preserves the saved owned root', (
    tester,
  ) async {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => throw PlatformException(code: 'unavailable'),
    );
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final external = Directory('${temp.path}/external')..createSync();
    final kv = InMemoryKeyValueStore({
      _v2: jsonEncode(_owned('workspace_abc')),
    });
    await tester.runAsync(() async {
      final restored = await buildTestDeps(
        isMobile: true,
        keyValueStore: kv,
      ).timeout(const Duration(seconds: 5));
      addTearDown(restored.dispose);
      expect(restored.codingController.state.workspaceRoot, isNull);
      expect(restored.codingController.state.lastError, contains(_recovery));
      await restored.codingController
          .setWorkspaceRoot(external.path)
          .timeout(const Duration(seconds: 5));
      expect(restored.codingController.state.workspaceRoot, isNull);
      expect(restored.codingController.state.lastError, contains(_recovery));
      expect(await _readV2(kv), _owned('workspace_abc'));
    });
  });

  testWidgets('stale legacy root recovers through Open local workspace', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final kv = InMemoryKeyValueStore();
    late String root;
    final deps = (await tester.runAsync(() async {
      final setup = await buildTestDeps(
        isMobile: true,
        appDataDirectory: '${temp.path}/old',
      );
      root = await setup.createLocalCodingWorkspace();
      await setup.codingController.setWorkspaceRoot(root);
      await setup.codingController
          .buildCodingTools()
          .firstWhere((tool) => tool.name == 'write')
          .invoke({'path': _nested, 'content': _bytes});
      await setup.dispose();
      await Directory('${temp.path}/old').rename('${temp.path}/app');
      await kv.writeString(_v1, root);
      return buildTestDeps(
        isMobile: true,
        appDataDirectory: '${temp.path}/app',
        keyValueStore: kv,
      );
    }))!;
    addTearDown(deps.dispose);
    await tester.pumpWidget(LlamadartStudioApp(dependencies: deps));
    await deps.shellController.selectWorkspace(StudioWorkspace.coding);
    await tester.pumpAndSettle();
    expect(deps.codingController.state.workspaceRoot, isNull);
    expect(find.textContaining(_recovery, findRichText: true), findsWidgets);
    final current =
        '${temp.path}/app/coding_workspaces/${root.split('/').last}';
    await tester.tap(find.byKey(const Key('coding_setup_toggle')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('coding_open_local_workspaces_button')),
    );
    await _waitFor(
      tester,
      () => find.byKey(Key('coding_open_local_$current')).evaluate().isNotEmpty,
    );
    await tester.tap(find.byKey(Key('coding_open_local_$current')));
    await _waitFor(
      tester,
      () => deps.codingController.state.workspaceRoot == current,
    );
    expect(
      await tester.runAsync(() => _readV2(kv)),
      _owned(root.split('/').last),
    );
    expect(await tester.runAsync(() => kv.readString(_v1)), root);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      await deps.dispose();
      await Directory('${temp.path}/app').rename('${temp.path}/moved');
      final fresh = await buildTestDeps(
        isMobile: true,
        appDataDirectory: '${temp.path}/moved',
        keyValueStore: kv,
      );
      final moved =
          '${temp.path}/moved/coding_workspaces/${root.split('/').last}';
      expect(fresh.codingController.state.workspaceRoot, moved);
      expect(File('$moved/$_nested').readAsBytesSync(), utf8.encode(_bytes));
      await fresh.dispose();
    });
  });
}

class _RejectRootStore extends InMemoryKeyValueStore {
  bool reject = false;

  @override
  Future<void> writeString(String key, String value) async {
    if (reject && key == _v2) throw StateError('Storage unavailable');
    await super.writeString(key, value);
  }
}
