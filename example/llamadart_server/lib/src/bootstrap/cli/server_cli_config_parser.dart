import 'dart:io';

import 'package:args/args.dart';

import 'server_cli_config.dart';

/// Parses validated runtime config from parsed args.
ServerCliConfig parseServerCliConfig(ArgResults results) {
  final host = results['host'] as String;
  final address = InternetAddress.tryParse(host);
  if (address == null) {
    throw ArgumentError('Invalid --host value: $host');
  }

  return ServerCliConfig(
    modelInput: results['model'] as String,
    modelId: results['model-id'] as String,
    address: address,
    port: _parseIntOption(results['port'] as String, 'port'),
    apiKey: results['api-key'] as String?,
    contextSize: _parseIntOption(
      results['context-size'] as String,
      'context-size',
    ),
    gpuLayers: _parseIntOption(results['gpu-layers'] as String, 'gpu-layers'),
    enableDartLogs: results['log'] as bool,
  );
}

int _parseIntOption(String raw, String fieldName) {
  final value = int.tryParse(raw);
  if (value == null || value < 0) {
    throw ArgumentError('`$fieldName` must be a non-negative integer.');
  }
  return value;
}
