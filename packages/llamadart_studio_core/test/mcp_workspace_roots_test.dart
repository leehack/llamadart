@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/loopback_mcp_transport.dart';

const _id = McpManager.builtInDartFlutterServerId;

void main() {
  late Directory temporary;
  late String a;
  late String b;
  late McpManager manager;
  late List<_SdkServer> processes;
  late List<McpServerConfig> launches;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('studio_mcp_roots_');
    a = (await Directory('${temporary.path}/A').create()).path;
    b = (await Directory('${temporary.path}/B').create()).path;
    processes = [];
    launches = [];
    manager = McpManager(
      keyValueStore: InMemoryKeyValueStore(),
      executableResolver: (_) async => 'dart',
      transportBuilder: (config) {
        launches.add(config);
        return processes[launches.length - 1].client;
      },
    );
  });
  tearDown(() async {
    await manager.dispose();
    for (final process in processes) {
      await process.server.close();
    }
    await temporary.delete(recursive: true);
  });

  Future<_SdkServer> process({bool delay = false, bool fail = false}) async {
    final server = await _SdkServer.create(delay: delay, fail: fail);
    processes.add(server);
    return server;
  }

  Future<void> configure({
    bool enabled = true,
    bool autoConnect = true,
    McpServerOrigin origin = McpServerOrigin.builtIn,
    McpTransportType transport = McpTransportType.stdio,
  }) => manager.saveServer(
    McpServerConfig(
      id: _id,
      name: 'Dart',
      transportType: transport,
      command: 'dart',
      workingDirectory: a,
      origin: origin,
      enabled: enabled,
      autoConnect: autoConnect,
      disabledTools: const ['roots'],
      hasCustomToolFilter: true,
    ),
  );

  for (final autoConnect in [true, false]) {
    test(
      'first SDK resolution follows newer root and autoConnect=$autoConnect',
      () async {
        await manager.dispose();
        final resolverEntered = Completer<void>();
        final resolverRelease = Completer<String?>();
        manager = McpManager(
          keyValueStore: InMemoryKeyValueStore(),
          executableResolver: (_) {
            resolverEntered.complete();
            return resolverRelease.future;
          },
          transportBuilder: (config) {
            launches.add(config);
            return processes[launches.length - 1].client;
          },
        );
        final first = await process();
        final pending = manager.ensureBuiltInDartFlutterServer(
          workspaceRoot: a,
        );
        await resolverEntered.future;
        await manager.syncWorkspaceServers(b, autoConnect: autoConnect);
        resolverRelease.complete('dart');
        await pending;
        if (!autoConnect) expect(launches, isEmpty);
        await manager.connectServer(_id);
        expect(launches.single.workingDirectory, b);
        expect(first.roots, [Uri.directory(p.canonicalize(b)).toString()]);
      },
    );
  }

  test(
    'selected A is bootstrapped before readiness; switching clears all roots and preserves filters',
    () async {
      final first = await process();
      await configure();
      await manager.connectServer(_id);
      expect(first.roots, [Uri.directory(p.canonicalize(a)).toString()]);
      await manager.syncWorkspaceServers('$a/../A/');
      expect(manager.state.servers.single.isConnected, isTrue);
      expect(launches, hasLength(1));
      expect(
        (await manager.callTool(
          serverId: _id,
          toolName: 'analyze',
          arguments: {'root': first.roots.single},
        ))['isError'],
        isFalse,
      );
      await manager.callTool(
        serverId: _id,
        toolName: 'roots',
        arguments: {
          'command': 'add',
          'uris': ['file:///extra/'],
        },
      );
      final second = await process();
      final rootsAtReady = <List<String>>[];
      final subscription = manager.store.stream.listen((state) {
        final entry = state.servers.single;
        if (entry.config.workingDirectory == b && entry.isConnected) {
          rootsAtReady.add(List.of(second.roots));
        }
      });
      addTearDown(subscription.cancel);
      final switching = manager.syncWorkspaceServers(b);
      expect(manager.state.activeTools, isEmpty);
      await expectLater(
        manager.callTool(serverId: _id, toolName: 'analyze'),
        throwsStateError,
      );
      await switching;
      await manager.connectServer(_id);
      expect(first.client.closed, isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(rootsAtReady, isNotEmpty);
      expect(
        rootsAtReady,
        everyElement([Uri.directory(p.canonicalize(b)).toString()]),
      );
      expect(launches.map((c) => c.workingDirectory), [a, b]);
      expect(second.roots, [Uri.directory(p.canonicalize(b)).toString()]);
      expect(
        (await manager.callTool(
          serverId: _id,
          toolName: 'analyze',
          arguments: {'root': first.roots.first},
        ))['isError'],
        isTrue,
      );
      expect(
        (await manager.callTool(
          serverId: _id,
          toolName: 'analyze',
          arguments: {'root': second.roots.single},
        ))['isError'],
        isFalse,
      );
      expect(manager.state.servers.single.config.disabledTools, ['roots']);
      expect(manager.state.servers.single.config.hasCustomToolFilter, isTrue);
      expect(manager.state.activeTools.map((t) => t.name), ['analyze']);
      expect(manager.state.trustedWorkspaceRoots, isEmpty);
    },
  );

  test('delayed A registration cannot publish over B', () async {
    final first = await process(delay: true);
    await configure();
    final pending = manager.connectServer(_id);
    final rejected = expectLater(pending, throwsA(anything));
    await first.entered.future;
    expect(manager.state.activeTools, isEmpty);
    await expectLater(
      manager.callTool(serverId: _id, toolName: 'analyze'),
      throwsStateError,
    );
    final second = await process();
    await manager.syncWorkspaceServers(b);
    await manager.connectServer(_id);
    first.release.complete();
    await rejected;
    expect(first.client.closed, isTrue);
    expect(manager.state.servers.single.isConnected, isTrue);
    expect(manager.state.servers.single.config.workingDirectory, b);
    expect(second.roots, [Uri.directory(p.canonicalize(b)).toString()]);
    expect(manager.state.activeTools.map((t) => t.name), ['analyze']);
  });

  test(
    'registration error closes owned client and preserves actual server message',
    () async {
      final first = await process(fail: true);
      await configure();
      await expectLater(
        manager.connectServer(_id),
        throwsA(isA<LlamaException>()),
      );
      expect(first.client.closed, isTrue);
      expect(manager.state.servers.single.status, McpConnectionStatus.error);
      expect(
        manager.state.servers.single.errorMessage,
        contains('root admission denied by SDK'),
      );
      expect(manager.state.activeTools, isEmpty);
      await expectLater(
        manager.callTool(serverId: _id, toolName: 'analyze'),
        throwsStateError,
      );
    },
  );

  for (final mode in [
    'disabled',
    'autoConnect false',
    'call autoConnect false',
  ]) {
    test('$mode does not start a disconnected server', () async {
      await configure(
        enabled: mode != 'disabled',
        autoConnect: mode != 'autoConnect false',
      );
      await manager.syncWorkspaceServers(
        b,
        autoConnect: mode != 'call autoConnect false',
      );
      expect(launches, isEmpty);
      expect(manager.state.servers.single.config.enabled, mode != 'disabled');
      expect(
        manager.state.servers.single.config.autoConnect,
        mode != 'autoConnect false',
      );
      await manager.ensureBuiltInDartFlutterServer(
        workspaceRoot: b,
        autoConnect: false,
      );
      expect(launches, isEmpty);
      expect(manager.state.servers.single.config.disabledTools, ['roots']);
      expect(manager.state.servers.single.config.enabled, mode != 'disabled');
      expect(
        manager.state.servers.single.config.autoConnect,
        mode != 'autoConnect false',
      );
    });
  }

  for (final origin in [McpServerOrigin.user, McpServerOrigin.project]) {
    test('$origin receives no SDK root bootstrap', () async {
      final first = await process();
      await configure(origin: origin);
      await manager.connectServer(_id);
      expect(first.roots, isEmpty);
    });
  }
  test('network built-in config receives no SDK root bootstrap', () async {
    final first = await process();
    await configure(transport: McpTransportType.streamableHttp);
    await manager.connectServer(_id);
    expect(first.roots, isEmpty);
  });
}

class _SdkServer {
  final client = LoopbackMcpTransport();
  final transport = LoopbackMcpTransport();
  final server = McpServer(
    const Implementation(name: 'fake-sdk', version: '1'),
  );
  final roots = <String>[];
  final entered = Completer<void>();
  final release = Completer<void>();

  static Future<_SdkServer> create({
    required bool delay,
    required bool fail,
  }) async {
    final instance = _SdkServer();
    instance.client.peer = instance.transport;
    instance.transport.peer = instance.client;
    instance.server.registerTool(
      'roots',
      callback: (args, _) async {
        if (!instance.entered.isCompleted) instance.entered.complete();
        if (delay) await instance.release.future;
        if (fail) {
          return CallToolResult(
            isError: true,
            content: [TextContent(text: 'root admission denied by SDK')],
          );
        }
        instance.roots.addAll((args['uris'] as List).cast<String>());
        return CallToolResult(
          isError: false,
          content: [TextContent(text: 'Success')],
        );
      },
    );
    instance.server.registerTool(
      'analyze',
      callback: (args, _) async => CallToolResult(
        isError: !instance.roots.contains(args['root']),
        content: [TextContent(text: 'diagnostics')],
      ),
    );
    await instance.server.connect(instance.transport);
    return instance;
  }
}
