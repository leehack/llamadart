import 'dart:io';

import 'package:llamadart/llamadart.dart';

import '../../features/server_engine/server_engine.dart';
import '../cli/server_cli_config.dart';

/// Loads one structured model source with server-specific model parameters.
typedef ServerModelSourceLoader =
    Future<void> Function(
      ModelSource source, {
      required ModelParams modelParams,
      ModelDownloadProgressCallback? onProgress,
    });

/// Creates and initializes a server engine for the provided CLI config.
Future<LlamaApiServerEngine> createInitializedServerEngine(
  ServerCliConfig config,
) async {
  final engine = LlamaEngine(LlamaBackend());
  final serverEngine = LlamaApiServerEngine(engine);

  try {
    await _configureEngineLogs(engine, enableDartLogs: config.enableDartLogs);

    await loadServerModelSource(
      config,
      loader:
          (
            ModelSource source, {
            required ModelParams modelParams,
            ModelDownloadProgressCallback? onProgress,
          }) {
            return engine.loadModelSource(
              source,
              modelParams: modelParams,
              onProgress: onProgress,
            );
          },
    );

    return serverEngine;
  } catch (_) {
    await engine.dispose();
    rethrow;
  }
}

/// Loads the configured model through a structured [ModelSource].
///
/// Keeping this operation separate makes the source-loading contract testable
/// without constructing a native engine.
Future<void> loadServerModelSource(
  ServerCliConfig config, {
  required ServerModelSourceLoader loader,
}) async {
  final source = ModelSource.parse(config.modelInput);
  stdout.writeln('Loading model source: ${source.displayName}');
  await loader(
    source,
    modelParams: ModelParams(
      contextSize: config.contextSize,
      gpuLayers: config.gpuLayers,
    ),
    onProgress: _writeModelLoadProgress,
  );
  stdout.writeln('\nModel ready: ${source.displayName}');
}

void _writeModelLoadProgress(ModelDownloadProgress progress) {
  final fraction = progress.fraction;
  if (fraction != null) {
    stdout.write('\rProgress: ${(fraction * 100).toStringAsFixed(1)}%');
    return;
  }

  final megabytes = (progress.receivedBytes / 1024 / 1024).toStringAsFixed(1);
  stdout.write('\rDownloaded: $megabytes MB');
}

Future<void> _configureEngineLogs(
  LlamaEngine engine, {
  required bool enableDartLogs,
}) async {
  await engine.setNativeLogLevel(LlamaLogLevel.error);

  if (enableDartLogs) {
    await engine.setDartLogLevel(LlamaLogLevel.info);
  }
}
