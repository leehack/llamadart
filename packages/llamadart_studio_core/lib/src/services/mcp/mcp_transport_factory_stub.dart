import 'package:mcp_dart/mcp_dart.dart';

import '../../domain/mcp_server_config.dart';

/// Web/fallback transport factory supporting Streamable HTTP and Legacy SSE.
Transport createMcpTransportImpl(McpServerConfig config) {
  switch (config.transportType) {
    case McpTransportType.stdio:
      throw UnsupportedError(
        'Stdio MCP servers require a desktop or mobile IO host.',
      );
    case McpTransportType.streamableHttp:
      final rawUrl = config.url?.trim() ?? '';
      if (rawUrl.isEmpty) {
        throw ArgumentError('MCP Streamable HTTP server requires a URL.');
      }
      return StreamableHttpClientTransport(
        Uri.parse(rawUrl),
        opts: StreamableHttpClientTransportOptions(
          requestInit: config.headers.isEmpty
              ? null
              : <String, dynamic>{'headers': config.headers},
        ),
      );
    case McpTransportType.sse:
      final rawUrl = config.url?.trim() ?? '';
      if (rawUrl.isEmpty) {
        throw ArgumentError('MCP SSE server requires a URL.');
      }
      // ignore: deprecated_member_use
      return SseClientTransport(
        Uri.parse(rawUrl),
        // ignore: deprecated_member_use
        opts: SseClientTransportOptions(headers: config.headers),
      );
  }
}
