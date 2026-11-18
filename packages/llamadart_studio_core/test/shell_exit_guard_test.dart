import 'dart:async';

import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:test/test.dart';

void main() {
  late StudioShellController shell;
  setUp(() async {
    shell = StudioShellController(keyValueStore: InMemoryKeyValueStore());
    await shell.initialize();
  });
  tearDown(() => shell.dispose());

  test('failed save refuses navigation and permits a later retry', () async {
    var saved = false;
    shell.registerWorkspaceExitGuard(Object(), () async => saved);
    await shell.selectWorkspace(StudioWorkspace.models);
    expect(shell.state.activeWorkspace, StudioWorkspace.chat);
    saved = true;
    await shell.selectWorkspace(StudioWorkspace.models);
    expect(shell.state.activeWorkspace, StudioWorkspace.models);
  });

  test(
    'concurrent navigation awaits one save and uses latest destination',
    () async {
      final saved = Completer<bool>();
      var saves = 0;
      shell.registerWorkspaceExitGuard(Object(), () {
        saves++;
        return saved.future;
      });
      final first = shell.selectWorkspace(StudioWorkspace.models);
      final second = shell.selectWorkspace(StudioWorkspace.notes);
      expect(shell.state.activeWorkspace, StudioWorkspace.chat);
      expect(saves, 1);
      saved.complete(true);
      await Future.wait([first, second]);
      expect(shell.state.activeWorkspace, StudioWorkspace.notes);
    },
  );

  test('outgoing view cannot unregister the incoming view guard', () async {
    final oldOwner = Object();
    final newOwner = Object();
    shell.registerWorkspaceExitGuard(oldOwner, () async => true);
    shell.registerWorkspaceExitGuard(newOwner, () async => false);
    shell.clearWorkspaceExitGuard(oldOwner);
    expect(await shell.prepareWorkspaceExit(), isFalse);
    shell.clearWorkspaceExitGuard(newOwner);
    expect(await shell.prepareWorkspaceExit(), isTrue);
  });

  test('guard exception fails closed and a replacement can recover', () async {
    final owner = Object();
    shell.registerWorkspaceExitGuard(
      owner,
      () async => throw StateError('save failed'),
    );
    expect(await shell.prepareWorkspaceExit(), isFalse);
    shell.registerWorkspaceExitGuard(owner, () async => true);
    expect(await shell.prepareWorkspaceExit(), isTrue);
  });

  test('same workspace selection does not stop an active capture', () async {
    var calls = 0;
    shell.registerWorkspaceExitGuard(Object(), () async {
      calls++;
      return true;
    });
    await shell.selectWorkspace(StudioWorkspace.chat);
    expect(calls, 0);
  });

  test('disposing during save prevents later navigation', () async {
    final saved = Completer<bool>();
    final isolated = StudioShellController(
      keyValueStore: InMemoryKeyValueStore(),
    );
    await isolated.initialize();
    isolated.registerWorkspaceExitGuard(Object(), () => saved.future);
    final navigate = isolated.selectWorkspace(StudioWorkspace.models);
    await isolated.dispose();
    saved.complete(true);
    await navigate;
    expect(isolated.state.activeWorkspace, StudioWorkspace.chat);
  });

  test('inspector choices stay with their workspace', () async {
    expect(shell.state.inspectorVisible, isTrue);
    await shell.selectWorkspace(StudioWorkspace.notes);
    expect(shell.state.inspectorVisible, isFalse);
    await shell.toggleInspector();
    expect(shell.state.inspectorVisible, isTrue);
    await shell.selectWorkspace(StudioWorkspace.models);
    expect(shell.state.inspectorVisible, isFalse);
    await shell.selectWorkspace(StudioWorkspace.notes);
    expect(shell.state.inspectorVisible, isTrue);
    await shell.selectWorkspace(StudioWorkspace.chat);
    expect(shell.state.inspectorVisible, isTrue);
    await shell.toggleInspector();
    expect(shell.state.inspectorVisible, isFalse);
  });
}
