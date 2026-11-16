import 'dart:async';

import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:test/test.dart';

void main() {
  test(
    'discovery cannot restore a server or tool disabled while connecting',
    () async {
      final clientTransport = _LoopbackTransport();
      final serverTransport = _LoopbackTransport(gateToolDiscovery: true);
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

class _LoopbackTransport implements Transport {
  _LoopbackTransport({this.gateToolDiscovery = false});

  final bool gateToolDiscovery;
  final discoveryEntered = Completer<void>();
  final discoveryRelease = Completer<void>();
  late _LoopbackTransport peer;
  bool closed = false;

  @override
  void Function()? onclose;
  @override
  void Function(Error)? onerror;
  @override
  void Function(JsonRpcMessage)? onmessage;
  @override
  String? get sessionId => null;

  @override
  Future<void> start() async {}

  @override
  Future<void> send(JsonRpcMessage message, {int? relatedRequestId}) async {
    final result = message.toJson()['result'];
    if (gateToolDiscovery && result is Map && result.containsKey('tools')) {
      discoveryEntered.complete();
      await discoveryRelease.future;
    }
    if (!closed && !peer.closed) peer.onmessage?.call(message);
  }

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    onclose?.call();
  }
}
