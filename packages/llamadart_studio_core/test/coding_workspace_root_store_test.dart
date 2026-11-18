import 'dart:io';

import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'studio_test_fakes.dart';

void main() {
  late Directory directory;
  late InMemoryKeyValueStore kv;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('studio_root_store_');
    kv = InMemoryKeyValueStore();
  });
  tearDown(() => directory.delete(recursive: true));

  Future<CodingWorkspaceController> controller({
    CodingWorkspaceRootStore? rootStore,
  }) async {
    final shell = StudioShellController(keyValueStore: kv);
    final mcp = McpManager(keyValueStore: kv);
    final skills = SkillRegistry(keyValueStore: kv);
    await shell.initialize();
    final result = CodingWorkspaceController(
      inferencePort: FakeInferencePort(),
      shellController: shell,
      keyValueStore: kv,
      mcpManager: mcp,
      skillRegistry: skills,
      autoConnectWorkspaceMcp: false,
      workspaceRootStore: rootStore,
    );
    addTearDown(() async {
      await result.dispose();
      await skills.dispose();
      await mcp.dispose();
      await shell.dispose();
    });
    return result;
  }

  test('default store keeps the v1 absolute root key', () async {
    final canonicalRoot = p.canonicalize(directory.path);
    final first = await controller();
    await first.setWorkspaceRoot(directory.path);
    expect(
      await kv.readString(KeyValueCodingWorkspaceRootStore.storageKey),
      canonicalRoot,
    );
    expect(
      KeyValueCodingWorkspaceRootStore.storageKey,
      'studio.coding.workspace_root.v1',
    );
    final restored = await controller();
    await restored.initialize(autoDetectDefaultRoot: false);
    expect(restored.state.workspaceRoot, canonicalRoot);
  });

  test('read failure is reported without selecting a default root', () async {
    final store = _FailingRootStore();
    final restored = await controller(rootStore: store);
    await restored.initialize();
    expect(restored.state.workspaceRoot, isNull);
    expect(restored.state.lastError, 'Saved root unavailable');
    expect(store.writes, isEmpty);
  });

  test('injected store receives the selected canonical root', () async {
    final canonicalRoot = p.canonicalize(directory.path);
    final store = _FailingRootStore(root: '${directory.path}/./');
    final restored = await controller(rootStore: store);
    await restored.initialize();
    expect(restored.state.workspaceRoot, canonicalRoot);
    expect(store.writes, [canonicalRoot]);
    expect(
      await kv.readString(KeyValueCodingWorkspaceRootStore.storageKey),
      isNull,
    );
  });
}

class _FailingRootStore implements CodingWorkspaceRootStore {
  _FailingRootStore({this.root});

  final String? root;
  final List<String> writes = <String>[];

  @override
  Future<String?> readRoot() async =>
      root ?? (throw StateError('Saved root unavailable'));

  @override
  Future<void> writeRoot(String root) async => writes.add(root);
}
