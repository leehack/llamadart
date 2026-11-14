import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:test/test.dart';

void main() {
  test(
    'Windows workspace trust matches drive case and path separators',
    () async {
      final manager = McpManager(keyValueStore: InMemoryKeyValueStore());
      addTearDown(manager.dispose);
      await manager.initialize();
      await manager.trustWorkspace(
        r'C:\Users\Alice\Studio\',
        connectServers: false,
      );
      expect(manager.isWorkspaceTrusted('c:/users/alice/studio'), isTrue);
      expect(manager.isWorkspaceTrusted(r'C:\Users\Alice\Other'), isFalse);
      expect(McpManager.normalizeWorkspaceRoot(r'C:\'), r'c:\');
    },
  );

  test(
    'UNC trust matches canonical server/share but preserves distinct roots',
    () async {
      final manager = McpManager(keyValueStore: InMemoryKeyValueStore());
      addTearDown(manager.dispose);
      await manager.initialize();
      await manager.trustWorkspace(
        r'\\Server\Share\Studio',
        connectServers: false,
      );
      expect(manager.isWorkspaceTrusted(r'\\server\share\studio\'), isTrue);
      expect(manager.isWorkspaceTrusted(r'\\server\other\studio'), isFalse);
    },
  );
}
