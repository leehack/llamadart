import 'package:args/args.dart';

import 'sqlite_vector_search_service.dart';

/// COSINE metric used when vectors are normalized.
const String cosineMetric = 'COSINE';

/// L2 metric used when vectors are not normalized.
const String l2Metric = 'L2';

/// Parsed and validated command-line options for the SQLite vector example.
final class SqliteVectorCliOptions {
  /// Path or URL to the GGUF model.
  final String modelUrlOrPath;

  /// Query string used for retrieval.
  final String query;

  /// Input corpus documents.
  final List<String> documents;

  /// Number of nearest neighbors to return.
  final int topK;

  /// Whether quantized ANN search is enabled.
  final bool useQuantizedSearch;

  /// Whether quantized vectors are preloaded.
  final bool preloadQuantized;

  /// Quantization type (UINT8, INT8, 1BIT).
  final String quantizedQtype;

  /// Optional quantization memory budget string.
  final String? quantizedMaxMemory;

  /// Whether exact-vs-quantized comparison is enabled.
  final bool compareExact;

  /// Optional minimum similarity threshold.
  final double? minSimilarity;

  /// Whether embedding vectors are normalized.
  final bool normalize;

  /// Distance metric string consumed by sqlite-vector.
  final String distanceMetric;

  /// SQLite database path.
  final String databasePath;

  /// Whether to force CPU backend.
  final bool forceCpu;

  /// Model context size.
  final int contextSize;

  /// Number of generation threads.
  final int threads;

  /// Number of batch threads.
  final int threadsBatch;

  /// Logical batch size.
  final int batchSize;

  /// Micro batch size.
  final int microBatchSize;

  /// Maximum parallel sequence slots.
  final int maxParallelSequences;

  /// Creates immutable CLI options.
  const SqliteVectorCliOptions({
    required this.modelUrlOrPath,
    required this.query,
    required this.documents,
    required this.topK,
    required this.useQuantizedSearch,
    required this.preloadQuantized,
    required this.quantizedQtype,
    required this.quantizedMaxMemory,
    required this.compareExact,
    required this.minSimilarity,
    required this.normalize,
    required this.distanceMetric,
    required this.databasePath,
    required this.forceCpu,
    required this.contextSize,
    required this.threads,
    required this.threadsBatch,
    required this.batchSize,
    required this.microBatchSize,
    required this.maxParallelSequences,
  });
}

/// Creates the CLI parser for the SQLite vector example.
ArgParser createSqliteVectorArgParser({required String defaultModelUrl}) {
  return ArgParser()
    ..addOption(
      'model',
      abbr: 'm',
      help: 'Path or URL to a GGUF embedding model.',
      defaultsTo: defaultModelUrl,
    )
    ..addOption(
      'query',
      abbr: 'q',
      help: 'Query text to search against embedded documents.',
      defaultsTo: 'How do I improve embedding throughput?',
    )
    ..addMultiOption(
      'doc',
      abbr: 'd',
      help: 'Corpus document text. Repeat to add more documents.',
    )
    ..addOption(
      'top-k',
      abbr: 'k',
      help: 'Number of nearest matches to return.',
      defaultsTo: '3',
    )
    ..addFlag(
      'quantized',
      help: 'Use quantized ANN search with vector_quantize_scan(...).',
      defaultsTo: false,
    )
    ..addFlag(
      'quantized-preload',
      help: 'Preload quantized vectors into memory before searching.',
      defaultsTo: true,
    )
    ..addOption(
      'quantized-qtype',
      help: 'Quantization type: UINT8, INT8, or 1BIT.',
      defaultsTo: 'UINT8',
    )
    ..addOption(
      'quantized-max-memory',
      help: 'Quantization memory budget (for example: 30MB, 64MB).',
    )
    ..addFlag(
      'compare-exact',
      help: 'Run exact full-scan and print recall metrics for quantized mode.',
      defaultsTo: false,
    )
    ..addOption(
      'min-similarity',
      help: 'Minimum similarity threshold to display a result (-1.0..1.0).',
    )
    ..addFlag(
      'normalize',
      help: 'L2 normalize vectors before storing/searching.',
      defaultsTo: true,
    )
    ..addOption(
      'db',
      help: 'SQLite path (use :memory: for in-memory DB).',
      defaultsTo: ':memory:',
    )
    ..addFlag(
      'cpu',
      help: 'Force CPU backend for reproducible parity runs.',
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
      help: 'Max parallel sequence slots (0 uses corpus size).',
      defaultsTo: '0',
    )
    ..addFlag('help', abbr: 'h', help: 'Show help message.', negatable: false);
}

/// Parses [results] and returns strongly typed options for the CLI workflow.
SqliteVectorCliOptions parseSqliteVectorCliOptions(
  ArgResults results, {
  required List<String> defaultCorpus,
}) {
  final String modelUrlOrPath = results['model'] as String;
  final String query = results['query'] as String;
  final List<String> docsOption = List<String>.from(
    results['doc'] as List<String>,
  );
  final List<String> documents = docsOption.isEmpty
      ? List<String>.from(defaultCorpus)
      : docsOption;

  final int topK = _parsePositiveIntOption(results, 'top-k');
  final bool useQuantizedSearch = results['quantized'] as bool;
  final bool preloadQuantized = results['quantized-preload'] as bool;
  final String quantizedQtype = _parseQuantizedTypeOption(
    results,
    'quantized-qtype',
  );
  final String? quantizedMaxMemory = _parseOptionalStringOption(
    results,
    'quantized-max-memory',
  );
  final bool compareExact = results['compare-exact'] as bool;
  final double? minSimilarity = results.wasParsed('min-similarity')
      ? _parseDoubleRangeOption(results, 'min-similarity', min: -1.0, max: 1.0)
      : null;
  final bool normalize = results['normalize'] as bool;
  final String distanceMetric = normalize ? cosineMetric : l2Metric;

  final String databasePath = results['db'] as String;
  final bool forceCpu = results['cpu'] as bool;
  final int contextSize = _parseNonNegativeIntOption(results, 'ctx-size');
  final int threads = _parseNonNegativeIntOption(results, 'threads');
  final int threadsBatch = results.wasParsed('threads-batch')
      ? _parseNonNegativeIntOption(results, 'threads-batch')
      : threads;
  final int batchSize = _parseNonNegativeIntOption(results, 'batch-size');
  final int microBatchSize = _parseNonNegativeIntOption(results, 'ubatch-size');
  final int requestedMaxSeq = _parseNonNegativeIntOption(results, 'max-seq');
  final int maxParallelSequences = requestedMaxSeq > 0
      ? requestedMaxSeq
      : documents.length;

  return SqliteVectorCliOptions(
    modelUrlOrPath: modelUrlOrPath,
    query: query,
    documents: documents,
    topK: topK,
    useQuantizedSearch: useQuantizedSearch,
    preloadQuantized: preloadQuantized,
    quantizedQtype: quantizedQtype,
    quantizedMaxMemory: quantizedMaxMemory,
    compareExact: compareExact,
    minSimilarity: minSimilarity,
    normalize: normalize,
    distanceMetric: distanceMetric,
    databasePath: databasePath,
    forceCpu: forceCpu,
    contextSize: contextSize,
    threads: threads,
    threadsBatch: threadsBatch,
    batchSize: batchSize,
    microBatchSize: microBatchSize,
    maxParallelSequences: maxParallelSequences,
  );
}

/// Builds user-facing help text with parser usage and common examples.
String buildSqliteVectorHelpText(ArgParser parser) {
  final StringBuffer buffer = StringBuffer();
  buffer.writeln('llamadart SQLite Vector Example');
  buffer.writeln();
  buffer.writeln(parser.usage);
  buffer.writeln('Example:');
  buffer.writeln(
    '  dart run bin/llamadart_sqlite_vector_example.dart '
    '-q "How do I improve embedding throughput?" '
    '-d "Increase maxParallelSequences for wider embedding batches." '
    '-d "Tune batchSize and ubatchSize together."',
  );
  buffer.writeln(
    '  dart run bin/llamadart_sqlite_vector_example.dart '
    '--quantized --top-k 5 '
    '-q "How do I improve embedding throughput?" '
    '-d "Increase maxParallelSequences for wider embedding batches." '
    '-d "Tune batchSize and ubatchSize together."',
  );
  buffer.writeln(
    '  dart run bin/llamadart_sqlite_vector_example.dart '
    '--quantized --compare-exact --quantized-qtype INT8 --top-k 5 '
    '--min-similarity 0.45 '
    '-q "How do I improve embedding throughput?" '
    '-d "Increase maxParallelSequences for wider embedding batches." '
    '-d "Tune batchSize and ubatchSize together."',
  );
  return buffer.toString();
}

int _parseIntOption(ArgResults results, String name) {
  final int? value = int.tryParse(results[name] as String);
  if (value == null) {
    throw FormatException('Invalid integer for --$name: ${results[name]}');
  }
  return value;
}

int _parsePositiveIntOption(ArgResults results, String name) {
  final int value = _parseIntOption(results, name);
  if (value <= 0) {
    throw FormatException('--$name must be greater than 0.');
  }
  return value;
}

int _parseNonNegativeIntOption(ArgResults results, String name) {
  final int value = _parseIntOption(results, name);
  if (value < 0) {
    throw FormatException('--$name must be 0 or greater.');
  }
  return value;
}

String _parseQuantizedTypeOption(ArgResults results, String name) {
  final String value = (results[name] as String).trim().toUpperCase();
  if (!supportedQuantizeTypes.contains(value)) {
    throw FormatException(
      '--$name must be one of: ${supportedQuantizeTypes.join(', ')}.',
    );
  }
  return value;
}

String? _parseOptionalStringOption(ArgResults results, String name) {
  if (!results.wasParsed(name)) {
    return null;
  }

  final String value = (results[name] as String).trim();
  return value.isEmpty ? null : value;
}

double _parseDoubleRangeOption(
  ArgResults results,
  String name, {
  required double min,
  required double max,
}) {
  final String raw = results[name] as String;
  final double? value = double.tryParse(raw);
  if (value == null) {
    throw FormatException('Invalid number for --$name: $raw');
  }
  if (value < min || value > max) {
    throw FormatException('--$name must be in [$min, $max].');
  }
  return value;
}
