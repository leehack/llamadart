import 'dart:io';

import 'package:args/args.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_basic_example/services/model_service.dart';

const String defaultModelUrl =
    'https://huggingface.co/ggml-org/embeddinggemma-300M-GGUF/resolve/main/'
    'embeddinggemma-300M-Q8_0.gguf?download=true';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption(
      'model',
      abbr: 'm',
      help: 'Path or URL to a GGUF model file.',
      defaultsTo: defaultModelUrl,
    )
    ..addMultiOption(
      'input',
      abbr: 'i',
      help: 'Input text to embed. Repeat for batch embedding.',
    )
    ..addFlag(
      'normalize',
      help: 'L2 normalize output vectors.',
      defaultsTo: true,
    )
    ..addFlag(
      'cpu',
      help: 'Force CPU backend for reproducible llama.cpp parity checks.',
      defaultsTo: false,
    )
    ..addOption(
      'ctx-size',
      help: 'Context size (0 uses model default).',
      defaultsTo: '0',
    )
    ..addOption(
      'threads',
      help: 'Generation threads (0 auto).',
      defaultsTo: '0',
    )
    ..addOption(
      'threads-batch',
      help: 'Batch threads (defaults to --threads when omitted).',
      defaultsTo: '0',
    )
    ..addOption(
      'batch-size',
      help: 'Logical batch size (0 uses the model-aware default).',
      defaultsTo: '0',
    )
    ..addOption(
      'ubatch-size',
      help: 'Micro-batch size (0 uses the model-aware default).',
      defaultsTo: '0',
    )
    ..addOption(
      'max-seq',
      help: 'Max parallel sequence slots (0 uses input count).',
      defaultsTo: '0',
    )
    ..addFlag('help', abbr: 'h', help: 'Show help message.', negatable: false);

  final results = parser.parse(arguments);
  if (results['help'] as bool) {
    print('🦙 llamadart Embedding Example\n');
    print(parser.usage);
    print('\nExample:');
    print(
      '  dart run bin/llamadart_embedding_example.dart '
      '-i "hello world" -i "semantic search"',
    );
    print(
      '  dart run bin/llamadart_embedding_example.dart '
      '--cpu --ctx-size 2048 --threads 12 --threads-batch 12 '
      '--batch-size 2048 --ubatch-size 2048 --max-seq 2 '
      '-i "hello world" -i "semantic search"',
    );
    return;
  }

  final modelUrlOrPath = results['model'] as String;
  final inputs = results['input'] as List<String>;
  final normalize = results['normalize'] as bool;
  final forceCpu = results['cpu'] as bool;
  final contextSize = _parseIntOption(results, 'ctx-size');
  final threads = _parseIntOption(results, 'threads');
  final threadsBatch = results.wasParsed('threads-batch')
      ? _parseIntOption(results, 'threads-batch')
      : threads;
  final batchSize = _parseIntOption(results, 'batch-size');
  final microBatchSize = _parseIntOption(results, 'ubatch-size');
  final requestedMaxSeq = _parseIntOption(results, 'max-seq');
  final texts = inputs.isEmpty
      ? const <String>['hello world', 'semantic search in dart']
      : List<String>.from(inputs);
  final maxParallelSequences = requestedMaxSeq > 0
      ? requestedMaxSeq
      : texts.length;

  final modelService = ModelService();
  final engine = LlamaEngine(LlamaBackend());

  try {
    print('Checking model...');
    final modelFile = await modelService.ensureModel(modelUrlOrPath);
    print('Loading model...');
    await engine.loadModel(
      modelFile.path,
      modelParams: ModelParams(
        contextSize: contextSize,
        preferredBackend: forceCpu ? GpuBackend.cpu : GpuBackend.auto,
        gpuLayers: forceCpu ? 0 : ModelParams.maxGpuLayers,
        numberOfThreads: threads,
        numberOfThreadsBatch: threadsBatch,
        batchSize: batchSize,
        microBatchSize: microBatchSize,
        maxParallelSequences: maxParallelSequences,
      ),
    );

    final backendName = await engine.getBackendName();
    print('Runtime backend: $backendName');

    final vectors = await engine.embedBatch(texts, normalize: normalize);
    for (int i = 0; i < vectors.length; i++) {
      final vector = vectors[i];
      final previewLength = vector.length < 8 ? vector.length : 8;
      final preview = vector
          .take(previewLength)
          .map((value) => value.toStringAsFixed(6))
          .join(', ');

      print('\nInput ${i + 1}: ${texts[i]}');
      print('Dimensions: ${vector.length}');
      print('First $previewLength values: [$preview]');
    }
  } on LlamaUnsupportedException catch (e) {
    print('Embedding is not available on this backend: $e');
    exitCode = 2;
  } catch (e) {
    print('Error: $e');
    exitCode = 1;
  } finally {
    await engine.dispose();
  }
}

int _parseIntOption(ArgResults results, String name) {
  final value = int.tryParse(results[name] as String);
  if (value == null) {
    throw FormatException('Invalid integer for --$name: ${results[name]}');
  }
  return value;
}
