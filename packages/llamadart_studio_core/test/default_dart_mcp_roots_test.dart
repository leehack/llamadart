@TestOn('vm')
library;

import 'dart:io';

import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:test/test.dart';

// Real SDK subprocesses and analysis only: no model, fixes, pub, or downloads.
void main() {
  test(
    'production SDK automatically admits selected A, then only B in a fresh process',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'studio_sdk_roots_',
      );
      final roots = <Directory>[];
      final files = <File, List<int>>{};
      for (final name in ['A', 'B']) {
        final root = await Directory('${temporary.path}/$name').create();
        roots.add(root);
        await Directory('${root.path}/lib').create();
        final pubspec = await File('${root.path}/pubspec.yaml').writeAsString(
          'name: studio_roots_${name.toLowerCase()}\nenvironment:\n  sdk: ">=3.10.0 <4.0.0"\n',
        );
        final source = await File('${root.path}/lib/main.dart').writeAsString(
          '/// Doubles the input.\nint doubleValue(int value) => value * 2;\n',
        );
        for (final file in [pubspec, source]) {
          files[file] = await file.readAsBytes();
        }
      }
      final manager = McpManager(
        keyValueStore: InMemoryKeyValueStore(),
        executableResolver: (_) async => Platform.resolvedExecutable,
      );
      addTearDown(() async {
        await manager.dispose();
        await temporary.delete(recursive: true);
      });
      await manager.ensureBuiltInDartFlutterServer(
        workspaceRoot: roots.first.path,
      );
      const id = McpManager.builtInDartFlutterServerId;
      await manager.connectServer(id);
      Future<Map<String, Object?>> analyze(Directory root) => manager.callTool(
        serverId: id,
        toolName: 'analyze_files',
        arguments: {
          'applyFixes': false,
          'roots': [
            {
              'root': root.uri.toString(),
              'paths': ['lib/main.dart'],
            },
          ],
        },
      );
      final before = await analyze(roots.first);
      expect(before['isError'], isFalse, reason: '$before');
      // Include a model-added old root: replacing the process must clear it too.
      await manager.callTool(
        serverId: id,
        toolName: 'roots',
        arguments: {
          'command': 'add',
          'uris': [temporary.uri.toString()],
        },
      );
      await manager.syncWorkspaceServers(roots.last.path);
      await manager.connectServer(id);
      final rejected = await analyze(roots.first);
      final selected = await analyze(roots.last);
      expect(rejected['isError'], isTrue, reason: '$rejected');
      expect(selected['isError'], isFalse, reason: '$selected');
      for (final entry in files.entries) {
        expect(await entry.key.readAsBytes(), entry.value);
      }
      print(
        'STUDIO_SDK_ROOTS server=${manager.state.servers.single.serverVersion} selectedA=$before oldAAfterSwitch=$rejected selectedB=$selected fixtureBytesUnchanged=true',
      );
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
