import 'dart:convert';
import 'dart:io';

import 'package:yaml/yaml.dart';

/// Rejects conflicting LiteRT-LM owners before either assets or downloads begin.
///
/// Walks only the consumer's dependency closure. Other pub workspace members in
/// package_config are not dependencies merely because they resolved together.
void validateRuntimeCoexistence({
  required Directory? consumerRoot,
  required Iterable<String> selectedRuntimes,
  required void Function(Uri) dependency,
}) {
  if (!selectedRuntimes.contains('litert_lm') || consumerRoot == null) return;
  final rootSpec = File.fromUri(consumerRoot.uri.resolve('pubspec.yaml'));
  if (!rootSpec.existsSync()) return;
  dependency(rootSpec.uri);
  Set<String> names(File file, {bool dev = false}) {
    dependency(file.uri);
    final decoded = loadYaml(file.readAsStringSync());
    if (decoded is! Map) return {};
    return {
      if (decoded['dependencies'] case final Map entries)
        ...entries.keys.whereType<String>(),
      if (dev && decoded['dev_dependencies'] is Map)
        ...(decoded['dev_dependencies'] as Map).keys.whereType<String>(),
    };
  }

  final pending = names(rootSpec, dev: true).toList();
  final visited = <String>{};
  Map<String, Uri>? roots;
  while (pending.isNotEmpty) {
    final name = pending.removeLast();
    if (!visited.add(name)) continue;
    if (name == 'flutter_edge_ai_litertlm') {
      throw StateError(
        'Conflicting LiteRT-LM runtimes: flutter_edge_ai_litertlm already owns its native libraries. Configure hooks.user_defines.llamadart.llamadart_native_runtimes: [llama_cpp] in the application or pub workspace root, remove llamadart_litert_lm_flutter if present, then rerun pub get/build. Runtime defaults are unchanged for applications without that engine.',
      );
    }
    if (roots == null) {
      var directory = consumerRoot;
      File? config;
      while (true) {
        final candidate = File.fromUri(
          directory.uri.resolve('.dart_tool/package_config.json'),
        );
        if (candidate.existsSync()) {
          config = candidate;
          break;
        }
        if (directory.parent.path == directory.path) break;
        directory = directory.parent;
      }
      roots = {};
      if (config != null) {
        dependency(config.uri);
        final json =
            jsonDecode(config.readAsStringSync()) as Map<String, dynamic>;
        for (final entry in json['packages'] as List) {
          final root = config.uri.resolve(entry['rootUri'] as String);
          if (root.scheme == 'file') {
            roots[entry['name'] as String] = Directory.fromUri(root).uri;
          }
        }
      }
    }
    final root = roots[name];
    if (root == null) continue;
    final spec = File.fromUri(root.resolve('pubspec.yaml'));
    if (spec.existsSync()) pending.addAll(names(spec));
  }
}
