import 'dart:async';

import 'package:mcp_dart/mcp_dart.dart';

class LoopbackMcpTransport implements Transport {
  LoopbackMcpTransport({this.gateToolDiscovery = false});

  final bool gateToolDiscovery;
  final discoveryEntered = Completer<void>();
  final discoveryRelease = Completer<void>();
  late LoopbackMcpTransport peer;
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
