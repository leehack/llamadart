import 'dart:convert';
import 'dart:developer' as developer;

import 'package:path/path.dart' as p;

import '../../domain/mcp_server_config.dart';
import '../../ports/key_value_store.dart';

/// Persists global [McpServerConfig]s and trusted workspace roots in
/// [KeyValueStore] independently of runtime MCP connection management.
class McpConfigStore {
  /// Creates an [McpConfigStore].
  const McpConfigStore(this._kv);

  static const String _storageKey = 'studio.mcp_servers.v1';
  static const String _trustedWorkspacesKey =
      'studio.mcp_trusted_workspaces.v1';

  final KeyValueStore _kv;

  /// Normalizes a workspace path for stable trust-list comparison.
  static String normalizeWorkspaceRoot(String root) {
    var clean = root.trim();
    if (RegExp(r'^[A-Za-z]:[\\/]').hasMatch(clean) || clean.startsWith(r'\\')) {
      return p.windows.normalize(clean).toLowerCase();
    }
    while (clean.length > 1 && (clean.endsWith('/') || clean.endsWith(r'\'))) {
      if (clean.length == 3 && clean[1] == ':') {
        break;
      }
      clean = clean.substring(0, clean.length - 1);
    }
    return clean;
  }

  /// Loads persisted global server configs and trusted workspace roots.
  Future<({List<McpServerConfig> servers, Set<String> trustedRoots})>
  load() async {
    final trusted = <String>{};
    final rawTrusted = await _kv.readString(_trustedWorkspacesKey);
    if (rawTrusted != null && rawTrusted.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawTrusted);
        if (decoded is List) {
          for (final item in decoded.whereType<String>()) {
            final clean = normalizeWorkspaceRoot(item);
            if (clean.isNotEmpty) {
              trusted.add(clean);
            }
          }
        }
      } catch (error, stackTrace) {
        developer.log(
          'Ignoring corrupt trusted workspaces list',
          name: 'llamadart_studio.mcp',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }

    var restoredConfigs = const <McpServerConfig>[];
    final raw = await _kv.readString(_storageKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          restoredConfigs = decoded
              .whereType<Map<String, Object?>>()
              .map(McpServerConfig.fromJson)
              .where((McpServerConfig c) => !c.isProjectScoped)
              .toList(growable: false);
        }
      } catch (error, stackTrace) {
        developer.log(
          'Ignoring corrupt persisted MCP server configuration list',
          name: 'llamadart_studio.mcp',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }

    return (servers: restoredConfigs, trustedRoots: trusted);
  }

  /// Persists non-project-scoped MCP [configs].
  Future<void> saveServers(Iterable<McpServerConfig> configs) async {
    final encoded = configs
        .where((McpServerConfig c) => !c.isProjectScoped)
        .map((McpServerConfig c) => c.toJson())
        .toList(growable: false);
    await _kv.writeString(_storageKey, jsonEncode(encoded));
  }

  /// Persists the explicit [trustedRoots] allowlist.
  Future<void> saveTrustedRoots(Set<String> trustedRoots) async {
    final sorted = trustedRoots.toList()..sort();
    await _kv.writeString(_trustedWorkspacesKey, jsonEncode(sorted));
  }
}
