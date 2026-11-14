import 'package:mcp_dart/mcp_dart.dart';

import '../../domain/mcp_server_config.dart';
import 'mcp_transport_factory_stub.dart'
    if (dart.library.io) 'mcp_transport_factory_io.dart'
    as impl;

/// Creates a [Transport] for [config] using `mcp_dart` (`stdio` on native
/// IO; `streamableHttp` & `sse` across all platforms).
Transport createMcpTransport(McpServerConfig config) =>
    impl.createMcpTransportImpl(config);
