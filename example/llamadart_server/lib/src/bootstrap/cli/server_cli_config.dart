import 'dart:io';

/// Parsed runtime settings for the CLI server process.
class ServerCliConfig {
  /// Model path or URL.
  final String modelInput;

  /// Public model id exposed in API responses.
  final String modelId;

  /// Bind address.
  final InternetAddress address;

  /// Bind port.
  final int port;

  /// Optional API key.
  final String? apiKey;

  /// Model context size.
  final int contextSize;

  /// Number of GPU layers.
  final int gpuLayers;

  /// Whether verbose Dart/request logs are enabled.
  final bool enableDartLogs;

  /// Creates a parsed runtime config.
  const ServerCliConfig({
    required this.modelInput,
    required this.modelId,
    required this.address,
    required this.port,
    required this.apiKey,
    required this.contextSize,
    required this.gpuLayers,
    required this.enableDartLogs,
  });

  /// Whether auth is enabled.
  bool get authEnabled => apiKey != null && apiKey!.isNotEmpty;
}
