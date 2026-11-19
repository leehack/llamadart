import 'dart:async';
import 'dart:io';

import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:test/test.dart';

import 'studio_test_fakes.dart';

const List<WorkspaceFileEntry> _rootEntries = <WorkspaceFileEntry>[
  WorkspaceFileEntry(relativePath: 'nested', name: 'nested', isDirectory: true),
  WorkspaceFileEntry(
    relativePath: 'top.txt',
    name: 'top.txt',
    isDirectory: false,
    sizeBytes: 5,
  ),
];

const List<WorkspaceFileEntry> _nestedEntries = <WorkspaceFileEntry>[
  WorkspaceFileEntry(
    relativePath: 'nested/inner.txt',
    name: 'inner.txt',
    isDirectory: false,
    sizeBytes: 5,
  ),
];

class _ExplorerRaceHarness {
  _ExplorerRaceHarness({
    List<WorkspaceFileEntry> Function(String subdir)? defaultListing,
  }) {
    final kv = InMemoryKeyValueStore();
    controller = CodingWorkspaceController(
      inferencePort: DirectLlamaInferencePort(
        backend: FakeSpeculativeFallbackBackend(),
      ),
      shellController: StudioShellController(keyValueStore: kv),
      keyValueStore: kv,
      mcpManager: McpManager(keyValueStore: kv),
      skillRegistry: SkillRegistry(keyValueStore: kv),
      autoConnectWorkspaceMcp: false,
      listFiles:
          (
            String rootPath, {
            String subdir = '',
            int maxEntries = 200,
            bool recursive = false,
          }) async {
            listCalls.add(subdir);
            if (listQueue.isNotEmpty) {
              return listQueue.removeAt(0)();
            }
            if (gateSubdirs.remove(subdir)) {
              final completer = Completer<List<WorkspaceFileEntry>>();
              listGates[subdir] = completer;
              return completer.future;
            }
            if (defaultListing != null) {
              return defaultListing(subdir);
            }
            return subdir == 'nested' ? _nestedEntries : _rootEntries;
          },
      readFile:
          (
            String rootPath,
            String relativePath, {
            int startLine = 1,
            int maxLines = 250,
          }) async {
            readCalls.add(relativePath);
            if (gateReads.remove(relativePath)) {
              final completer = Completer<WorkspaceFileSlice>();
              readGates[relativePath] = completer;
              return completer.future;
            }
            return WorkspaceFileSlice(
              relativePath: relativePath,
              content: 'hello $relativePath',
              numberedPreview: '1: hello $relativePath',
              startLine: 1,
              endLine: 1,
              totalLines: 1,
              truncated: false,
            );
          },
    );
  }

  late final CodingWorkspaceController controller;
  final Set<String> gateSubdirs = <String>{};
  final Map<String, Completer<List<WorkspaceFileEntry>>> listGates =
      <String, Completer<List<WorkspaceFileEntry>>>{};
  final List<Future<List<WorkspaceFileEntry>> Function()> listQueue =
      <Future<List<WorkspaceFileEntry>> Function()>[];
  final Set<String> gateReads = <String>{};
  final Map<String, Completer<WorkspaceFileSlice>> readGates =
      <String, Completer<WorkspaceFileSlice>>{};
  final List<String> listCalls = <String>[];
  final List<String> readCalls = <String>[];

  List<String> get filePaths =>
      controller.state.files.map((e) => e.relativePath).toList();
}

void main() {
  late Directory rootDir;

  setUp(() async {
    rootDir = await Directory.systemTemp.createTemp('studio_explorer_race_');
  });

  tearDown(() async {
    if (rootDir.existsSync()) {
      await rootDir.delete(recursive: true);
    }
  });

  test(
    'refreshExplorer discards stale root listing when openDirectory completes concurrently',
    () async {
      final h = _ExplorerRaceHarness();
      await h.controller.setWorkspaceRoot(rootDir.path);
      await h.controller.openFile('top.txt');
      expect(h.controller.state.currentSubdir, '');
      expect(h.controller.state.selectedFilePath, 'top.txt');

      h.gateSubdirs.add('');
      final refreshFuture = h.controller.refreshExplorer();
      await Future<void>.delayed(Duration.zero);
      expect(h.listGates[''], isNotNull);

      await h.controller.openDirectory('nested');
      expect(h.controller.state.currentSubdir, 'nested');
      expect(h.filePaths, <String>['nested/inner.txt']);

      h.listGates['']!.complete(_rootEntries);
      await refreshFuture;

      expect(h.controller.state.currentSubdir, 'nested');
      expect(h.filePaths, <String>['nested/inner.txt']);
    },
  );

  test(
    'refreshExplorer discards stale error when openDirectory completes concurrently',
    () async {
      final h = _ExplorerRaceHarness();
      await h.controller.setWorkspaceRoot(rootDir.path);

      h.gateSubdirs.add('');
      final refreshFuture = h.controller.refreshExplorer();
      await Future<void>.delayed(Duration.zero);

      await h.controller.openDirectory('nested');
      expect(h.controller.state.lastError, isNull);

      h.listGates['']!.completeError(
        const FileSystemException('stale failure'),
      );
      await refreshFuture;

      expect(h.controller.state.currentSubdir, 'nested');
      expect(h.controller.state.lastError, isNull);
    },
  );

  test(
    'openDirectory is not cancelled when refreshExplorer completes first',
    () async {
      final h = _ExplorerRaceHarness();
      await h.controller.setWorkspaceRoot(rootDir.path);

      h.gateSubdirs.add('nested');
      final openFuture = h.controller.openDirectory('nested');
      await Future<void>.delayed(Duration.zero);

      await h.controller.refreshExplorer();

      h.listGates['nested']!.complete(_nestedEntries);
      await openFuture;

      expect(h.controller.state.currentSubdir, 'nested');
      expect(h.filePaths, <String>['nested/inner.txt']);
    },
  );

  test(
    'same-root setWorkspaceRoot cancels in-flight refreshExplorer',
    () async {
      final h = _ExplorerRaceHarness();
      await h.controller.setWorkspaceRoot(rootDir.path);
      await h.controller.openDirectory('nested');

      h.gateSubdirs.add('nested');
      final refreshFuture = h.controller.refreshExplorer();
      await Future<void>.delayed(Duration.zero);

      await h.controller.setWorkspaceRoot(rootDir.path);
      expect(h.controller.state.currentSubdir, '');

      h.listGates['nested']!.complete(_nestedEntries);
      await refreshFuture;

      expect(h.controller.state.currentSubdir, '');
      expect(h.filePaths, <String>['nested', 'top.txt']);
    },
  );

  test(
    'invalidated refreshExplorer skips redundant selected-file read after listFiles',
    () async {
      final h = _ExplorerRaceHarness();
      await h.controller.setWorkspaceRoot(rootDir.path);
      await h.controller.openFile('top.txt');
      final readsBeforeRefresh = h.readCalls.length;

      h.gateSubdirs.add('');
      final refreshFuture = h.controller.refreshExplorer();
      await Future<void>.delayed(Duration.zero);

      await h.controller.openDirectory('nested');

      h.listGates['']!.complete(_rootEntries);
      await refreshFuture;

      expect(h.readCalls.length, readsBeforeRefresh);
      expect(h.controller.state.currentSubdir, 'nested');
      expect(h.filePaths, <String>['nested/inner.txt']);
    },
  );

  test(
    'refreshExplorer discards stale listing when invalidated during selected-file read',
    () async {
      final h = _ExplorerRaceHarness();
      await h.controller.setWorkspaceRoot(rootDir.path);
      await h.controller.openFile('top.txt');

      h.gateReads.add('top.txt');
      final refreshFuture = h.controller.refreshExplorer();
      await Future<void>.delayed(Duration.zero);
      expect(h.readGates['top.txt'], isNotNull);

      await h.controller.openDirectory('nested');
      expect(h.controller.state.currentSubdir, 'nested');
      expect(h.filePaths, <String>['nested/inner.txt']);

      h.readGates['top.txt']!.complete(
        const WorkspaceFileSlice(
          relativePath: 'top.txt',
          content: 'stale',
          numberedPreview: '1: stale',
          startLine: 1,
          endLine: 1,
          totalLines: 1,
          truncated: false,
        ),
      );
      await refreshFuture;

      expect(h.controller.state.currentSubdir, 'nested');
      expect(h.filePaths, <String>['nested/inner.txt']);
    },
  );

  test(
    'openDirectory discards stale error when a newer openDirectory completes first',
    () async {
      final h = _ExplorerRaceHarness(
        defaultListing: (String subdir) {
          if (subdir == 'nested') return _nestedEntries;
          if (subdir == 'other') {
            return const <WorkspaceFileEntry>[
              WorkspaceFileEntry(
                relativePath: 'other/file.txt',
                name: 'file.txt',
                isDirectory: false,
                sizeBytes: 3,
              ),
            ];
          }
          return _rootEntries;
        },
      );
      await h.controller.setWorkspaceRoot(rootDir.path);

      h.gateSubdirs.add('nested');
      final staleOpen = h.controller.openDirectory('nested');
      await Future<void>.delayed(Duration.zero);

      await h.controller.openDirectory('other');
      expect(h.controller.state.currentSubdir, 'other');
      expect(h.controller.state.lastError, isNull);

      h.listGates['nested']!.completeError(
        const FileSystemException('stale dir failure'),
      );
      await staleOpen;

      expect(h.controller.state.currentSubdir, 'other');
      expect(h.controller.state.lastError, isNull);
    },
  );

  test(
    'refreshExplorer racing refreshExplorer keeps latest refresh result',
    () async {
      final h = _ExplorerRaceHarness();
      await h.controller.setWorkspaceRoot(rootDir.path);

      final firstGate = Completer<List<WorkspaceFileEntry>>();
      final secondGate = Completer<List<WorkspaceFileEntry>>();
      h.listQueue.add(() => firstGate.future);
      h.listQueue.add(() => secondGate.future);

      final firstRefresh = h.controller.refreshExplorer();
      await Future<void>.delayed(Duration.zero);
      final secondRefresh = h.controller.refreshExplorer();
      await Future<void>.delayed(Duration.zero);

      const latestEntries = <WorkspaceFileEntry>[
        WorkspaceFileEntry(
          relativePath: 'latest.txt',
          name: 'latest.txt',
          isDirectory: false,
          sizeBytes: 6,
        ),
      ];
      secondGate.complete(latestEntries);
      await secondRefresh;
      expect(h.filePaths, <String>['latest.txt']);

      firstGate.complete(_rootEntries);
      await firstRefresh;
      expect(h.filePaths, <String>['latest.txt']);
    },
  );

  test(
    'openFile during refreshExplorer read preserves newly opened file slice',
    () async {
      final h = _ExplorerRaceHarness();
      await h.controller.setWorkspaceRoot(rootDir.path);
      await h.controller.openFile('top.txt');

      h.gateReads.add('top.txt');
      final refreshFuture = h.controller.refreshExplorer();
      await Future<void>.delayed(Duration.zero);
      expect(h.readGates['top.txt'], isNotNull);

      await h.controller.openFile('other.txt');
      expect(h.controller.state.selectedFilePath, 'other.txt');
      expect(h.controller.state.selectedFileSlice?.relativePath, 'other.txt');

      h.readGates['top.txt']!.complete(
        const WorkspaceFileSlice(
          relativePath: 'top.txt',
          content: 'refreshed top',
          numberedPreview: '1: refreshed top',
          startLine: 1,
          endLine: 1,
          totalLines: 1,
          truncated: false,
        ),
      );
      await refreshFuture;

      expect(h.controller.state.selectedFilePath, 'other.txt');
      expect(h.controller.state.selectedFileSlice?.relativePath, 'other.txt');
    },
  );

  test(
    'refreshExplorer applies preview of unchanged selected file when openDirectory invalidates only listing',
    () async {
      final h = _ExplorerRaceHarness();
      await h.controller.setWorkspaceRoot(rootDir.path);
      await h.controller.openFile('top.txt');

      h.gateReads.add('top.txt');
      final refreshFuture = h.controller.refreshExplorer();
      await Future<void>.delayed(Duration.zero);
      expect(h.readGates['top.txt'], isNotNull);

      await h.controller.openDirectory('nested');
      expect(h.controller.state.currentSubdir, 'nested');
      expect(h.filePaths, <String>['nested/inner.txt']);
      expect(h.controller.state.selectedFilePath, 'top.txt');

      h.readGates['top.txt']!.complete(
        const WorkspaceFileSlice(
          relativePath: 'top.txt',
          content: 'updated top',
          numberedPreview: '1: updated top',
          startLine: 1,
          endLine: 1,
          totalLines: 1,
          truncated: false,
        ),
      );
      await refreshFuture;

      expect(h.controller.state.currentSubdir, 'nested');
      expect(h.filePaths, <String>['nested/inner.txt']);
      expect(h.controller.state.selectedFilePath, 'top.txt');
      expect(h.controller.state.selectedFileSlice?.content, 'updated top');
    },
  );

  test('same-root setWorkspaceRoot cancels in-flight openDirectory', () async {
    final h = _ExplorerRaceHarness();
    await h.controller.setWorkspaceRoot(rootDir.path);

    h.gateSubdirs.add('nested');
    final openFuture = h.controller.openDirectory('nested');
    await Future<void>.delayed(Duration.zero);
    expect(h.listGates['nested'], isNotNull);

    await h.controller.setWorkspaceRoot(rootDir.path);
    expect(h.controller.state.currentSubdir, '');
    expect(h.filePaths, <String>['nested', 'top.txt']);

    h.listGates['nested']!.complete(_nestedEntries);
    await openFuture;

    expect(h.controller.state.currentSubdir, '');
    expect(h.filePaths, <String>['nested', 'top.txt']);
  });
}
