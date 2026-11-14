import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../domain/mcp_server_config.dart';
import 'project_context_discovery.dart';

const int _maxAgentsBytes = 24 * 1024;

/// Discovers `AGENTS.md`, `.agents/AGENTS.md`, and `CLAUDE.md` from
/// [workspaceRoot].
Future<ProjectAgentsContext> discoverProjectAgentsContextImpl(
  String? workspaceRoot,
) async {
  final root = workspaceRoot?.trim();
  if (root == null || root.isEmpty) {
    return ProjectAgentsContext.empty;
  }
  final rootDir = Directory(root);
  if (!await rootDir.exists()) {
    return ProjectAgentsContext.empty;
  }

  final canonicalRoot = p.canonicalize(rootDir.path);
  final candidates = <String>[
    p.join(canonicalRoot, 'AGENTS.md'),
    p.join(canonicalRoot, '.agents', 'AGENTS.md'),
    p.join(canonicalRoot, 'CLAUDE.md'),
  ];

  final seenRealPaths = <String>{};
  final sources = <String>[];
  final sections = <String>[];
  var remaining = _maxAgentsBytes;

  for (final candidate in candidates) {
    final file = File(candidate);
    if (!await file.exists()) {
      continue;
    }
    String realPath;
    try {
      realPath = await file.resolveSymbolicLinks();
    } catch (_) {
      realPath = p.canonicalize(file.path);
    }
    if (!seenRealPaths.add(realPath)) {
      continue;
    }
    try {
      final raw = (await file.readAsString()).trim();
      if (raw.isEmpty) {
        continue;
      }
      final rel = p.relative(candidate, from: canonicalRoot);
      sources.add(rel);
      final snippet = raw.length > remaining
          ? '${raw.substring(0, remaining)}\n...[truncated]'
          : raw;
      remaining -= snippet.length;
      sections.add('### $rel\n$snippet');
      if (remaining <= 256) {
        break;
      }
    } catch (error, stackTrace) {
      developer.log(
        'Skipping unreadable project context file: ${file.path}',
        name: 'llamadart_studio.context',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  if (sources.isEmpty) {
    return ProjectAgentsContext.empty;
  }

  return ProjectAgentsContext(
    primaryPath: sources.first,
    sourceFiles: List<String>.unmodifiable(sources),
    instructions: sections.join('\n\n'),
  );
}

/// Discovers project MCP server configurations from `.agents/mcp.json`,
/// `.mcp.json`, `.vscode/mcp.json`, and `.agents/mcp/*.json`.
Future<List<McpServerConfig>> discoverProjectMcpConfigsImpl(
  String? workspaceRoot,
) async {
  final root = workspaceRoot?.trim();
  if (root == null || root.isEmpty) {
    return const <McpServerConfig>[];
  }
  final rootDir = Directory(root);
  if (!await rootDir.exists()) {
    return const <McpServerConfig>[];
  }

  final canonicalRoot = p.canonicalize(rootDir.path);
  final candidateFiles = <File>[
    File(p.join(canonicalRoot, '.agents', 'mcp.json')),
    File(p.join(canonicalRoot, '.mcp.json')),
    File(p.join(canonicalRoot, '.vscode', 'mcp.json')),
  ];

  final agentsMcpDir = Directory(p.join(canonicalRoot, '.agents', 'mcp'));
  if (await agentsMcpDir.exists()) {
    try {
      await for (final entity in agentsMcpDir.list(followLinks: false)) {
        if (entity is File && entity.path.toLowerCase().endsWith('.json')) {
          candidateFiles.add(entity);
        }
      }
    } catch (_) {}
  }

  final seenIds = <String>{};
  final configs = <McpServerConfig>[];

  for (final file in candidateFiles) {
    if (!await file.exists()) {
      continue;
    }
    try {
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) {
        continue;
      }
      final decoded = jsonDecode(raw);
      final relPath = p.relative(file.path, from: canonicalRoot);
      final parsed = _parseMcpJsonDocument(
        decoded,
        workspaceRoot: canonicalRoot,
        relativeSourcePath: relPath,
        fallbackName: p.basenameWithoutExtension(file.path),
      );
      for (final cfg in parsed) {
        if (seenIds.add(cfg.id)) {
          configs.add(cfg);
        }
      }
    } catch (error, stackTrace) {
      developer.log(
        'Ignoring malformed project MCP configuration: ${file.path}',
        name: 'llamadart_studio.context',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  return List<McpServerConfig>.unmodifiable(configs);
}

List<McpServerConfig> _parseMcpJsonDocument(
  Object? decoded, {
  required String workspaceRoot,
  required String relativeSourcePath,
  required String fallbackName,
}) {
  final out = <McpServerConfig>[];
  if (decoded is List) {
    for (var i = 0; i < decoded.length; i++) {
      final item = decoded[i];
      if (item is Map) {
        final cfg = _mapEntryToConfig(
          name: (item['name'] as String?) ?? '${fallbackName}_$i',
          raw: Map<String, Object?>.from(item),
          workspaceRoot: workspaceRoot,
          relativeSourcePath: relativeSourcePath,
        );
        if (cfg != null) {
          out.add(cfg);
        }
      }
    }
    return out;
  }

  if (decoded is! Map) {
    return out;
  }

  final rootMap = Map<String, Object?>.from(decoded);
  final rawServers = rootMap['mcpServers'] ?? rootMap['servers'];
  if (rawServers is Map) {
    for (final entry in rawServers.entries) {
      if (entry.key is! String || entry.value is! Map) {
        continue;
      }
      final cfg = _mapEntryToConfig(
        name: entry.key as String,
        raw: Map<String, Object?>.from(entry.value as Map),
        workspaceRoot: workspaceRoot,
        relativeSourcePath: relativeSourcePath,
      );
      if (cfg != null) {
        out.add(cfg);
      }
    }
    return out;
  }

  // Support single-server file in `.agents/mcp/<name>.json`.
  final single = _mapEntryToConfig(
    name: (rootMap['name'] as String?) ?? fallbackName,
    raw: rootMap,
    workspaceRoot: workspaceRoot,
    relativeSourcePath: relativeSourcePath,
  );
  if (single != null) {
    out.add(single);
  }
  return out;
}

McpServerConfig? _mapEntryToConfig({
  required String name,
  required Map<String, Object?> raw,
  required String workspaceRoot,
  required String relativeSourcePath,
}) {
  String sub(String value) => value
      .replaceAll(r'${workspaceFolder}', workspaceRoot)
      .replaceAll(r'${workspaceRoot}', workspaceRoot)
      .replaceAll(r'${PWD}', workspaceRoot);

  final disabled = (raw['disabled'] as bool?) ?? false;
  final enabled = (raw['enabled'] as bool?) ?? !disabled;
  final rawType = (raw['type'] as String? ?? raw['transport'] as String? ?? '')
      .trim()
      .toLowerCase();
  final rawUrl = (raw['url'] as String?)?.trim();
  final rawCommand = (raw['command'] as String?)?.trim();

  final McpTransportType transport;
  if (rawType == 'sse') {
    transport = McpTransportType.sse;
  } else if (rawType == 'http' ||
      rawType == 'streamablehttp' ||
      rawType == 'streamable-http' ||
      (rawUrl != null && rawUrl.isNotEmpty && rawCommand == null)) {
    transport = McpTransportType.streamableHttp;
  } else {
    transport = McpTransportType.stdio;
  }

  if (transport == McpTransportType.stdio &&
      (rawCommand == null || rawCommand.isEmpty)) {
    return null;
  }
  if (transport != McpTransportType.stdio &&
      (rawUrl == null || rawUrl.isEmpty)) {
    return null;
  }

  final rawArgs = raw['args'];
  final args = rawArgs is List
      ? rawArgs.whereType<String>().map(sub).toList(growable: false)
      : const <String>[];
  final rawEnv = raw['env'] ?? raw['environment'];
  final env = rawEnv is Map
      ? <String, String>{
          for (final e in rawEnv.entries)
            if (e.key is String && e.value != null)
              e.key as String: sub(e.value.toString()),
        }
      : const <String, String>{};
  final rawHeaders = raw['headers'];
  final headers = rawHeaders is Map
      ? <String, String>{
          for (final e in rawHeaders.entries)
            if (e.key is String && e.value != null)
              e.key as String: sub(e.value.toString()),
        }
      : const <String, String>{};
  final rawCwd =
      (raw['cwd'] as String?) ?? (raw['workingDirectory'] as String?);
  final cwd = (rawCwd == null || rawCwd.trim().isEmpty)
      ? (transport == McpTransportType.stdio ? workspaceRoot : null)
      : sub(rawCwd.trim());

  final slug = name.trim().toLowerCase().replaceAll(
    RegExp(r'[^a-z0-9_-]+'),
    '_',
  );
  final id = (raw['id'] as String?)?.trim().isNotEmpty == true
      ? (raw['id'] as String).trim()
      : 'project:${slug.isEmpty ? 'mcp' : slug}';

  return McpServerConfig(
    id: id,
    name: (raw['displayName'] as String?)?.trim().isNotEmpty == true
        ? (raw['displayName'] as String).trim()
        : name.trim(),
    transportType: transport,
    command: rawCommand == null ? null : sub(rawCommand),
    args: args,
    workingDirectory: cwd,
    environment: env,
    url: rawUrl == null ? null : sub(rawUrl),
    headers: headers,
    enabled: enabled,
    origin: McpServerOrigin.project,
    sourcePath: relativeSourcePath,
    autoConnect: enabled,
  );
}

List<String> _commonBinDirectories() {
  final dirs = <String>[];
  final envPath = Platform.environment['PATH'];
  if (envPath != null && envPath.isNotEmpty) {
    final sep = Platform.isWindows ? ';' : ':';
    dirs.addAll(envPath.split(sep).where((String s) => s.trim().isNotEmpty));
  }

  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null && flutterRoot.trim().isNotEmpty) {
    dirs.add(p.join(flutterRoot.trim(), 'bin'));
    dirs.add(p.join(flutterRoot.trim(), 'bin', 'cache', 'dart-sdk', 'bin'));
  }
  final dartSdk = Platform.environment['DART_SDK'];
  if (dartSdk != null && dartSdk.trim().isNotEmpty) {
    dirs.add(p.join(dartSdk.trim(), 'bin'));
  }

  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  if (home != null && home.trim().isNotEmpty) {
    final h = home.trim();
    dirs.addAll(<String>[
      p.join(h, 'development', 'flutter', 'bin'),
      p.join(h, 'flutter', 'bin'),
      p.join(h, 'fvm', 'default', 'bin'),
      p.join(h, '.fvm', 'default', 'bin'),
      p.join(h, '.pub-cache', 'bin'),
      p.join(h, '.local', 'bin'),
      p.join(h, '.cargo', 'bin'),
      p.join(h, '.nvm', 'current', 'bin'),
    ]);
  }

  if (!Platform.isWindows) {
    dirs.addAll(const <String>[
      '/opt/homebrew/bin',
      '/opt/homebrew/opt/dart/bin',
      '/usr/local/bin',
      '/usr/bin',
      '/bin',
    ]);
  }
  return dirs;
}

/// Resolves [command] across explicit paths, PATH, and standard SDK bins.
Future<String?> resolveHostExecutableImpl(String command) async {
  final trimmed = command.trim();
  if (trimmed.isEmpty) {
    return null;
  }

  if (trimmed.contains('/') || trimmed.contains('\\')) {
    final file = File(trimmed);
    if (await file.exists()) {
      return file.path;
    }
    return null;
  }

  final candidates = Platform.isWindows
      ? <String>[trimmed, '$trimmed.exe', '$trimmed.bat', '$trimmed.cmd']
      : <String>[trimmed];

  final seenDirs = <String>{};
  for (final dir in _commonBinDirectories()) {
    if (!seenDirs.add(dir)) {
      continue;
    }
    for (final name in candidates) {
      final candidate = File(p.join(dir, name));
      if (await candidate.exists()) {
        return candidate.path;
      }
    }
  }

  try {
    final res = await Process.run(
      Platform.isWindows ? 'where' : 'which',
      <String>[trimmed],
    );
    if (res.exitCode == 0) {
      final firstLine = res.stdout
          .toString()
          .split(RegExp(r'\r?\n'))
          .map((String l) => l.trim())
          .firstWhere((String l) => l.isNotEmpty, orElse: () => '');
      if (firstLine.isNotEmpty && await File(firstLine).exists()) {
        return firstLine;
      }
    }
  } catch (_) {}

  return null;
}

/// Synchronous executable lookup for transport initialization.
String resolveHostExecutableSync(String command) {
  final trimmed = command.trim();
  if (trimmed.isEmpty || trimmed.contains('/') || trimmed.contains('\\')) {
    return trimmed;
  }
  final candidates = Platform.isWindows
      ? <String>[trimmed, '$trimmed.exe', '$trimmed.bat', '$trimmed.cmd']
      : <String>[trimmed];
  final seenDirs = <String>{};
  for (final dir in _commonBinDirectories()) {
    if (!seenDirs.add(dir)) {
      continue;
    }
    for (final name in candidates) {
      final file = File(p.join(dir, name));
      if (file.existsSync()) {
        return file.path;
      }
    }
  }
  return trimmed;
}

/// Augments process environment PATH so Finder-launched macOS apps find `dart`,
/// `flutter`, `npx`, `uvx`, etc.
Map<String, String>? buildMcpProcessEnvironmentImpl(
  Map<String, String> overrides,
) {
  final sep = Platform.isWindows ? ';' : ':';
  final mergedDirs = <String>[];
  final seen = <String>{};

  void addDir(String d) {
    final trimmed = d.trim();
    if (trimmed.isNotEmpty && seen.add(trimmed)) {
      mergedDirs.add(trimmed);
    }
  }

  final overridePath = overrides['PATH'];
  if (overridePath != null) {
    overridePath.split(sep).forEach(addDir);
  }
  for (final d in _commonBinDirectories()) {
    addDir(d);
  }

  final env = <String, String>{
    ...Platform.environment,
    ...overrides,
    'PATH': mergedDirs.join(sep),
  };
  return env;
}
