import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:test/test.dart';

import 'studio_test_fakes.dart';

void main() {
  late Directory directory;
  late Directory first;
  late Directory second;
  late CodingWorkspaceController controller;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'studio_workspace_scope_',
    );
    first = await Directory('${directory.path}/a').create();
    second = await Directory('${directory.path}/b').create();
    final kv = InMemoryKeyValueStore();
    final inference = FakeInferencePort();
    final shell = StudioShellController(keyValueStore: kv);
    final mcp = McpManager(keyValueStore: kv);
    final skills = SkillRegistry(keyValueStore: kv);
    await shell.initialize();
    await mcp.initialize();
    await skills.initialize();
    controller = CodingWorkspaceController(
      inferencePort: inference,
      shellController: shell,
      keyValueStore: kv,
      mcpManager: mcp,
      skillRegistry: skills,
      autoConnectWorkspaceMcp: false,
    );
    addTearDown(() async {
      await controller.dispose();
      await skills.dispose();
      await mcp.dispose();
      await shell.dispose();
      await inference.dispose();
      await directory.delete(recursive: true);
    });
    await controller.setWorkspaceRoot(first.path);
  });

  test(
    'switching roots clears changes and rejects old tools and revert IDs',
    () async {
      final write = controller.buildCodingTools().firstWhere(
        (tool) => tool.name == 'write',
      );
      await write.invoke(<String, dynamic>{
        'path': 'shared.txt',
        'content': 'new A',
      });
      final change = controller.state.recentChanges.single;
      await File('${second.path}/shared.txt').writeAsString('original B');
      await controller.setWorkspaceRoot(second.path);
      expect(controller.state.recentChanges, isEmpty);
      expect(await controller.revertChange(change.id), isFalse);
      await expectLater(
        write.invoke(<String, dynamic>{'path': 'late.txt', 'content': 'stale'}),
        throwsA(isA<LlamaStateException>()),
      );
      expect(await File('${first.path}/late.txt').exists(), isFalse);
      expect(
        await File('${second.path}/shared.txt').readAsString(),
        'original B',
      );
      expect(await File('${first.path}/shared.txt').readAsString(), 'new A');
    },
  );

  test(
    'same root selection preserves current tools and revert history',
    () async {
      final write = controller.buildCodingTools().firstWhere(
        (tool) => tool.name == 'write',
      );
      await write.invoke(<String, dynamic>{
        'path': 'one.txt',
        'content': 'one',
      });
      final firstId = controller.state.recentChanges.single.id;
      await controller.setWorkspaceRoot('${first.path}/.');
      expect(controller.state.recentChanges.single.id, firstId);
      await write.invoke(<String, dynamic>{
        'path': 'two.txt',
        'content': 'two',
      });
      expect(controller.state.recentChanges.length, 2);
      expect(await controller.revertChange(firstId), isTrue);
      expect(await File('${first.path}/one.txt').exists(), isFalse);
    },
  );

  test(
    'an old write completion cannot repopulate the new workspace history',
    () async {
      final write = controller.buildCodingTools().firstWhere(
        (tool) => tool.name == 'write',
      );
      final overrides = _GatedWriteOverrides();
      final pending = IOOverrides.runWithIOOverrides(
        () => write.invoke(<String, dynamic>{
          'path': 'slow.txt',
          'content': 'written A',
        }),
        overrides,
      );
      final failure = expectLater(pending, throwsA(isA<LlamaStateException>()));
      await overrides.entered.future;
      await controller.setWorkspaceRoot(second.path);
      overrides.release.complete();
      await failure;
      expect(controller.state.recentChanges, isEmpty);
      expect(await File('${first.path}/slow.txt').readAsString(), 'written A');
      expect(await File('${second.path}/slow.txt').exists(), isFalse);
    },
  );

  test(
    'an in-flight revert stays in its captured root and cannot mark new changes',
    () async {
      final write = controller.buildCodingTools().firstWhere(
        (tool) => tool.name == 'write',
      );
      await File('${first.path}/slow.txt').writeAsString('before A');
      await write.invoke(<String, dynamic>{
        'path': 'slow.txt',
        'content': 'after A',
      });
      final changeId = controller.state.recentChanges.single.id;
      await File('${second.path}/slow.txt').writeAsString('original B');
      final overrides = _GatedWriteOverrides();
      final pending = IOOverrides.runWithIOOverrides(
        () => controller.revertChange(changeId),
        overrides,
      );
      await overrides.entered.future;
      await controller.setWorkspaceRoot(second.path);
      final newWrite = controller.buildCodingTools().firstWhere(
        (tool) => tool.name == 'write',
      );
      await newWrite.invoke(<String, dynamic>{
        'path': 'new.txt',
        'content': 'new B',
      });
      final newId = controller.state.recentChanges.single.id;
      overrides.release.complete();
      expect(await pending, isFalse);
      expect(controller.state.recentChanges.single.id, newId);
      expect(controller.state.recentChanges.single.reverted, isFalse);
      expect(await File('${first.path}/slow.txt').readAsString(), 'before A');
      expect(
        await File('${second.path}/slow.txt').readAsString(),
        'original B',
      );
    },
  );
}

final class _GatedWriteOverrides extends IOOverrides {
  final Completer<void> entered = Completer<void>();
  final Completer<void> release = Completer<void>();

  @override
  File createFile(String path) {
    final file = super.createFile(path);
    return path.endsWith('/slow.txt')
        ? _GatedFile(file, entered, release)
        : file;
  }
}

class _GatedFile implements File {
  _GatedFile(this.delegate, this.entered, this.release);
  final File delegate;
  final Completer<void> entered;
  final Completer<void> release;

  @override
  Future<bool> exists() => delegate.exists();

  @override
  String resolveSymbolicLinksSync() => delegate.resolveSymbolicLinksSync();

  @override
  Directory get parent => delegate.parent;

  @override
  Future<String> readAsString({Encoding encoding = utf8}) =>
      delegate.readAsString(encoding: encoding);

  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) async {
    await delegate.writeAsString(
      contents,
      mode: mode,
      encoding: encoding,
      flush: flush,
    );
    entered.complete();
    await release.future;
    return this;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
