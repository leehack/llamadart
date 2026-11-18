@TestOn('vm')
library;

import 'dart:io';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:llamadart_studio_core/src/services/skills/project_context_discovery_io.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  const flutterBin = r'C:\Studio SDK\flutter\bin';
  const cachedDart = '$flutterBin\\cache\\dart-sdk\\bin\\dart.exe';
  const standaloneBin = r'D:\Dart SDK\bin';

  for (final command in [
    'dart',
    '$flutterBin\\dart',
    '$flutterBin\\dart.bat',
    '$flutterBin\\dart.cmd',
    cachedDart,
  ]) {
    test('Windows resolves $command to Flutter cached native Dart', () async {
      final files = {'$flutterBin\\dart', '$flutterBin\\dart.bat', cachedDart};
      expect(
        await resolveHostExecutableImpl(
          command,
          isWindows: true,
          searchDirectories: [flutterBin],
          fileExists: files.contains,
        ),
        cachedDart,
      );
      expect(
        resolveHostExecutableSync(
          command,
          isWindows: true,
          searchDirectories: [flutterBin],
          fileExists: files.contains,
        ),
        cachedDart,
      );
    });
  }

  test(
    'Windows prefers standalone dart.exe over extensionless launcher',
    () async {
      final files = {'$standaloneBin\\dart', '$standaloneBin\\dart.exe'};
      expect(
        await resolveHostExecutableImpl(
          'dart',
          isWindows: true,
          searchDirectories: [standaloneBin],
          fileExists: files.contains,
        ),
        '$standaloneBin\\dart.exe',
      );
    },
  );

  test(
    'Windows never treats only POSIX or batch launchers as usable Dart',
    () async {
      final files = {'$flutterBin\\dart', '$flutterBin\\dart.bat'};
      expect(
        await resolveHostExecutableImpl(
          'dart',
          isWindows: true,
          searchDirectories: [flutterBin],
          fileExists: files.contains,
        ),
        isNull,
      );
      expect(
        () => resolveHostExecutableSync(
          '$flutterBin\\dart',
          isWindows: true,
          searchDirectories: [flutterBin],
          fileExists: files.contains,
        ),
        throwsA(isA<LlamaUnsupportedException>()),
      );
    },
  );

  test(
    'Unix executable resolution retains extensionless SDK launchers',
    () async {
      const dart = '/sdk with spaces/flutter/bin/dart';
      expect(
        await resolveHostExecutableImpl(
          'dart',
          isWindows: false,
          searchDirectories: ['/sdk with spaces/flutter/bin'],
          fileExists: (candidate) => candidate == dart,
        ),
        dart,
      );
    },
  );

  test('Windows skips unusable SDK and accepts a later native SDK', () async {
    expect(
      await resolveHostExecutableImpl(
        'DART.EXE',
        isWindows: true,
        searchDirectories: [flutterBin, '"$standaloneBin"'],
        fileExists: {
          '$flutterBin\\dart.bat',
          '$standaloneBin\\dart.exe',
        }.contains,
      ),
      '$standaloneBin\\dart.exe',
    );
  });

  test(
    'generated command is repaired on reopen while custom configs survive',
    () async {
      final kv = InMemoryKeyValueStore();
      const generated = McpServerConfig(
        id: McpManager.builtInDartFlutterServerId,
        name: 'Dart & Flutter MCP',
        transportType: McpTransportType.stdio,
        command: '$flutterBin\\dart',
        args: ['mcp-server'],
        origin: McpServerOrigin.builtIn,
        enabled: false,
        disabledTools: ['pub'],
        hasCustomToolFilter: true,
      );
      const custom = McpServerConfig(
        id: 'my-custom-dart',
        name: 'Custom Dart',
        transportType: McpTransportType.stdio,
        command: r'E:\Custom tools\dart.bat',
        args: ['run', 'custom.dart'],
        environment: {'MY_CONFIG': 'kept'},
      );
      final first = McpManager(keyValueStore: kv);
      await first.saveServer(generated);
      await first.saveServer(custom);
      await first.dispose();
      final reopened = McpManager(
        keyValueStore: kv,
        executableResolver: (command) => resolveHostExecutableImpl(
          command,
          isWindows: true,
          searchDirectories: [flutterBin],
          fileExists: {
            '$flutterBin\\dart',
            '$flutterBin\\dart.bat',
            cachedDart,
          }.contains,
        ),
      );
      addTearDown(reopened.dispose);
      await reopened.initialize();
      await reopened.ensureBuiltInDartFlutterServer(autoConnect: false);
      final repaired = reopened.state.servers.first.config;
      expect(repaired.command, cachedDart);
      expect(repaired.args, ['mcp-server']);
      expect(repaired.enabled, isFalse);
      expect(repaired.disabledTools, ['pub']);
      expect(repaired.hasCustomToolFilter, isTrue);
      expect(reopened.state.servers.last.config.toJson(), custom.toJson());
      final cold = McpManager(keyValueStore: kv);
      addTearDown(cold.dispose);
      await cold.initialize();
      expect(cold.state.servers.first.config.command, cachedDart);
    },
  );

  test('custom server using reserved ID is not rewritten', () async {
    final manager = McpManager(
      keyValueStore: InMemoryKeyValueStore(),
      executableResolver: (_) async => cachedDart,
    );
    addTearDown(manager.dispose);
    const custom = McpServerConfig(
      id: McpManager.builtInDartFlutterServerId,
      name: 'My custom server',
      transportType: McpTransportType.stdio,
      command: 'custom.exe',
      args: ['keep'],
    );
    await manager.saveServer(custom);
    await manager.ensureBuiltInDartFlutterServer(autoConnect: false);
    expect(manager.state.servers.single.config.toJson(), custom.toJson());
  });

  test(
    'missing native SDK exposes actionable error without spawning',
    () async {
      var spawns = 0;
      final manager = McpManager(
        keyValueStore: InMemoryKeyValueStore(),
        executableResolver: (_) async => null,
        transportBuilder: (_) {
          spawns++;
          throw StateError('Must not spawn without usable Dart');
        },
      );
      addTearDown(manager.dispose);
      await manager.ensureBuiltInDartFlutterServer();
      final state = manager.state.servers.single;
      expect(state.status, McpConnectionStatus.error);
      expect(state.errorMessage, contains('Install the Dart or Flutter SDK'));
      expect(state.errorMessage, contains('dart.exe'));
      expect(spawns, 0);
    },
  );

  test(
    'default server uses real stdio with an executable path containing spaces',
    () async {
      final root = await Directory.systemTemp.createTemp('studio_mcp_launch_');
      final sdkBin = p.join(root.path, 'SDK & tools');
      await Link(sdkBin).create(p.dirname(Platform.resolvedExecutable));
      final command = p.join(sdkBin, p.basename(Platform.resolvedExecutable));
      final manager = McpManager(
        keyValueStore: InMemoryKeyValueStore(),
        executableResolver: (_) async => command,
      );
      addTearDown(() async {
        await manager.dispose();
        await root.delete(recursive: true);
      });
      await manager.ensureBuiltInDartFlutterServer(
        workspaceRoot: root.path,
        autoConnect: false,
      );
      final connected = await manager.connectServer(
        McpManager.builtInDartFlutterServerId,
      );
      expect(connected.config.command, command);
      expect(connected.config.args, ['mcp-server']);
      expect(connected.status, McpConnectionStatus.connected);
      expect(connected.tools.map((t) => t.name), contains('analyze_files'));
    },
    skip: Platform.isWindows
        ? 'Windows real launch is covered by release-app qualification; directory symlinks need elevated permission.'
        : false,
  );
}
