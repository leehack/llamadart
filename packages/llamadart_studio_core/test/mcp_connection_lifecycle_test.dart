import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:test/test.dart';

import 'support/loopback_mcp_transport.dart';

void main() {
  test(
    'discovery cannot restore a server or tool disabled while connecting',
    () async {
      final clientTransport = LoopbackMcpTransport();
      final serverTransport = LoopbackMcpTransport(gateToolDiscovery: true);
      clientTransport.peer = serverTransport;
      serverTransport.peer = clientTransport;
      final server = McpServer(
        const Implementation(name: 'local-test', version: '1'),
      );
      server.registerTool(
        'echo',
        callback: (_, _) async =>
            CallToolResult(content: [TextContent(text: 'ok')]),
      );
      await server.connect(serverTransport);
      final manager = McpManager(
        keyValueStore: InMemoryKeyValueStore(),
        transportBuilder: (_) => clientTransport,
      );
      addTearDown(() async {
        await manager.dispose();
        await server.close();
      });
      await manager.saveServer(
        const McpServerConfig(
          id: 'local',
          name: 'Local',
          transportType: McpTransportType.stdio,
        ),
      );
      final pending = manager.connectServer('local');
      await serverTransport.discoveryEntered.future;
      await manager.setServerEnabled('local', false);
      await manager.setToolEnabled('local', 'echo', false);
      serverTransport.discoveryRelease.complete();
      final connected = await pending;
      expect(connected.config.enabled, isFalse);
      expect(connected.config.disabledTools, ['echo']);
      expect(manager.state.servers.single.config.enabled, isFalse);
      expect(manager.state.activeTools, isEmpty);
    },
  );
}
