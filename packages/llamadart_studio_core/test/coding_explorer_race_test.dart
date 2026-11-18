import 'dart:async';
import 'dart:io';

import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:test/test.dart';

import 'studio_test_fakes.dart';

void main() {
  test(
    'refreshExplorer discards stale root listing when openDirectory completes concurrently',
    () async {
      final rootDir = await Directory.systemTemp.createTemp(
        'studio_explorer_race_',
      );
      addTearDown(() async {
        if (rootDir.existsSync()) {
          await rootDir.delete(recursive: true);
        }
      });

      final kv = InMemoryKeyValueStore();
      final shell = StudioShellController(keyValueStore: kv);
      final mcp = McpManager(keyValueStore: kv);
      final skills = SkillRegistry(keyValueStore: kv);
      final port = DirectLlamaInferencePort(
        backend: FakeSpeculativeFallbackBackend(),
      );

      final rootEntries = <WorkspaceFileEntry>[
        const WorkspaceFileEntry(
          relativePath: 'nested',
          name: 'nested',
          isDirectory: true,
        ),
        const WorkspaceFileEntry(
          relativePath: 'top.txt',
          name: 'top.txt',
          isDirectory: false,
          sizeBytes: 5,
        ),
      ];
      final nestedEntries = <WorkspaceFileEntry>[
        const WorkspaceFileEntry(
          relativePath: 'nested/inner.txt',
          name: 'inner.txt',
          isDirectory: false,
          sizeBytes: 5,
        ),
      ];

      Completer<List<WorkspaceFileEntry>>? refreshGate;
      var gateRootList = false;

      final controller = CodingWorkspaceController(
        inferencePort: port,
        shellController: shell,
        keyValueStore: kv,
        mcpManager: mcp,
        skillRegistry: skills,
        autoConnectWorkspaceMcp: false,
        listFiles:
            (
              String rootPath, {
              String subdir = '',
              int maxEntries = 200,
              bool recursive = false,
            }) async {
              if (subdir == 'nested') {
                return nestedEntries;
              }
              if (gateRootList) {
                refreshGate = Completer<List<WorkspaceFileEntry>>();
                return refreshGate!.future;
              }
              return rootEntries;
            },
        readFile:
            (
              String rootPath,
              String relativePath, {
              int startLine = 1,
              int maxLines = 250,
            }) async => WorkspaceFileSlice(
              relativePath: relativePath,
              content: 'hello',
              numberedPreview: '1: hello',
              startLine: 1,
              endLine: 1,
              totalLines: 1,
              truncated: false,
            ),
      );

      await controller.setWorkspaceRoot(rootDir.path);
      await controller.openFile('top.txt');
      expect(controller.state.currentSubdir, '');
      expect(controller.state.selectedFilePath, 'top.txt');

      gateRootList = true;
      final refreshFuture = controller.refreshExplorer();
      await Future<void>.delayed(Duration.zero);
      expect(refreshGate, isNotNull);

      await controller.openDirectory('nested');
      expect(controller.state.currentSubdir, 'nested');
      expect(
        controller.state.files.map((e) => e.relativePath).toList(),
        <String>['nested/inner.txt'],
      );

      refreshGate!.complete(rootEntries);
      await refreshFuture;

      expect(controller.state.currentSubdir, 'nested');
      expect(
        controller.state.files.map((e) => e.relativePath).toList(),
        <String>['nested/inner.txt'],
      );
    },
  );

  test(
    'refreshExplorer discards stale error when openDirectory completes concurrently',
    () async {
      final rootDir = await Directory.systemTemp.createTemp(
        'studio_explorer_race_err_',
      );
      addTearDown(() async {
        if (rootDir.existsSync()) {
          await rootDir.delete(recursive: true);
        }
      });

      final kv = InMemoryKeyValueStore();
      final shell = StudioShellController(keyValueStore: kv);
      final mcp = McpManager(keyValueStore: kv);
      final skills = SkillRegistry(keyValueStore: kv);
      final port = DirectLlamaInferencePort(
        backend: FakeSpeculativeFallbackBackend(),
      );

      final rootEntries = <WorkspaceFileEntry>[
        const WorkspaceFileEntry(
          relativePath: 'nested',
          name: 'nested',
          isDirectory: true,
        ),
      ];
      final nestedEntries = <WorkspaceFileEntry>[
        const WorkspaceFileEntry(
          relativePath: 'nested/inner.txt',
          name: 'inner.txt',
          isDirectory: false,
          sizeBytes: 5,
        ),
      ];

      Completer<List<WorkspaceFileEntry>>? refreshGate;
      var gateRootList = false;

      final controller = CodingWorkspaceController(
        inferencePort: port,
        shellController: shell,
        keyValueStore: kv,
        mcpManager: mcp,
        skillRegistry: skills,
        autoConnectWorkspaceMcp: false,
        listFiles:
            (
              String rootPath, {
              String subdir = '',
              int maxEntries = 200,
              bool recursive = false,
            }) async {
              if (subdir == 'nested') {
                return nestedEntries;
              }
              if (gateRootList) {
                refreshGate = Completer<List<WorkspaceFileEntry>>();
                return refreshGate!.future;
              }
              return rootEntries;
            },
        readFile:
            (
              String rootPath,
              String relativePath, {
              int startLine = 1,
              int maxLines = 250,
            }) async => WorkspaceFileSlice(
              relativePath: relativePath,
              content: 'hello',
              numberedPreview: '1: hello',
              startLine: 1,
              endLine: 1,
              totalLines: 1,
              truncated: false,
            ),
      );

      await controller.setWorkspaceRoot(rootDir.path);
      gateRootList = true;
      final refreshFuture = controller.refreshExplorer();
      await Future<void>.delayed(Duration.zero);

      await controller.openDirectory('nested');
      expect(controller.state.lastError, isNull);

      refreshGate!.completeError(const FileSystemException('stale failure'));
      await refreshFuture;

      expect(controller.state.currentSubdir, 'nested');
      expect(controller.state.lastError, isNull);
    },
  );
}
