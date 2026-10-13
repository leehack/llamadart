import 'dart:convert';
import 'dart:io';

import 'package:yaml/yaml.dart';

/// Applies consumer defaults and rejects conflicting LiteRT-LM ownership.
///
/// Walks only the consumer's dependency closure. Other pub workspace members in
/// package_config are not dependencies merely because they resolved together.
List<String> selectConsumerNativeRuntimes({
  required Directory? consumerRoot,
  required List<String> selectedRuntimes,
  required bool explicitLiteRtLm,
  required void Function(Uri) dependency,
}) {
  try {
    return _selectConsumerNativeRuntimes(
      consumerRoot: consumerRoot,
      selectedRuntimes: selectedRuntimes,
      explicitLiteRtLm: explicitLiteRtLm,
      dependency: dependency,
    );
  } on FormatException {
    throw StateError(
      'Cannot read the native runtime dependency graph. Fix package metadata and rerun pub get/build.',
    );
  } on FileSystemException {
    throw StateError(
      'Cannot read the native runtime dependency graph. Check package metadata access and rerun pub get/build.',
    );
  }
}

List<String> _selectConsumerNativeRuntimes({
  required Directory? consumerRoot,
  required List<String> selectedRuntimes,
  required bool explicitLiteRtLm,
  required void Function(Uri) dependency,
}) {
  if (!selectedRuntimes.contains('litert_lm') || consumerRoot == null) {
    return selectedRuntimes;
  }
  final rootSpec = File.fromUri(consumerRoot.uri.resolve('pubspec.yaml'));
  if (!rootSpec.existsSync()) return selectedRuntimes;
  dependency(rootSpec.uri);
  Set<String> names(File file, {bool dev = false}) {
    dependency(file.uri);
    final decoded = loadYaml(file.readAsStringSync());
    if (decoded is! Map) return {};
    return {
      if (dev && decoded['name'] is String) decoded['name'] as String,
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
  if (visited.contains('flutter_edge_ai_litertlm') && explicitLiteRtLm) {
    throw StateError(
      'Conflicting LiteRT-LM runtimes: flutter_edge_ai_litertlm already owns its native libraries. Configure hooks.user_defines.llamadart.llamadart_native_runtimes: [llama_cpp] in the application or pub workspace root, remove llamadart_litert_lm_flutter if present, then rerun pub get/build.',
    );
  }
  if (!explicitLiteRtLm &&
      (visited.contains('flutter_edge_ai_llama') ||
          visited.contains('flutter_edge_ai_litertlm'))) {
    return selectedRuntimes
        .where((runtime) => runtime != 'litert_lm')
        .toList(growable: false);
  }
  return selectedRuntimes;
}
