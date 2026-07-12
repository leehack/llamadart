import 'package:args/args.dart';
import 'package:llamadart/llamadart.dart';

const String _defaultModelUrl =
    'https://huggingface.co/unsloth/Qwen3.6-27B-GGUF/resolve/main/'
    'Qwen3.6-27B-UD-Q4_K_XL.gguf?download=true';

/// Builds the CLI argument parser.
ArgParser buildServerCliArgParser() {
  return ArgParser()
    ..addOption(
      'model',
      abbr: 'm',
      defaultsTo: _defaultModelUrl,
      help: 'Path, URL, or hf:// model source.',
    )
    ..addOption(
      'model-id',
      defaultsTo: 'llamadart-local',
      help: 'Model ID returned from `/v1/models` and completion responses.',
    )
    ..addOption(
      'host',
      defaultsTo: '127.0.0.1',
      help: 'Host/IP to bind the HTTP server to.',
    )
    ..addOption(
      'port',
      defaultsTo: '8080',
      help: 'TCP port for the HTTP server.',
    )
    ..addOption(
      'api-key',
      help: 'Optional API key required as `Authorization: Bearer <key>`.',
    )
    ..addOption(
      'context-size',
      defaultsTo: '16384',
      help: 'Model context size in tokens.',
    )
    ..addOption(
      'gpu-layers',
      defaultsTo: '${ModelParams.maxGpuLayers}',
      help: 'Number of layers to offload to GPU.',
    )
    ..addFlag(
      'log',
      abbr: 'g',
      defaultsTo: false,
      help:
          'Enable verbose Dart + request logging '
          '(native logs stay error-only).',
    )
    ..addFlag(
      'help',
      abbr: 'h',
      negatable: false,
      help: 'Show this help message.',
    );
}
