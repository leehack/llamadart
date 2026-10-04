import 'dart:io';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart_basic_example/services/model_service.dart';
import 'package:llamadart_basic_example/services/sqlite_vector_cli_options.dart';
import 'package:llamadart_basic_example/services/sqlite_vector_search_service.dart';
import 'package:sqlite3/sqlite3.dart';

const String defaultModelUrl =
    'https://huggingface.co/ggml-org/embeddinggemma-300M-GGUF/resolve/main/'
    'embeddinggemma-300M-Q8_0.gguf?download=true';

const List<String> defaultCorpus = <String>[
  'Use maxParallelSequences to increase true embedding batch concurrency.',
  'Keep batchSize and microBatchSize aligned for throughput-first workloads.',
  'Prefer CPU fallback on devices where GPU memory is constrained.',
  'Lower context size when you only run short retrieval prompts.',
  'Measure sequential vs batch embedding throughput with benchmark scripts.',
];

Future<void> main(List<String> arguments) async {
  final parser = createSqliteVectorArgParser(defaultModelUrl: defaultModelUrl);
  final results = parser.parse(arguments);
  if (results['help'] as bool) {
    stdout.write(buildSqliteVectorHelpText(parser));
    return;
  }

  final SqliteVectorCliOptions options = parseSqliteVectorCliOptions(
    results,
    defaultCorpus: defaultCorpus,
  );

  final ModelService modelService = ModelService();
  final SqliteVectorSearchService vectorSearchService =
      SqliteVectorSearchService();
  final LlamaEngine engine = LlamaEngine(LlamaBackend());
  Database? database;

  try {
    print('Checking model...');
    final File modelFile = await modelService.ensureModel(
      options.modelUrlOrPath,
    );

    print('Loading model...');
    await engine.setModel(
      LlamaModel(ModelSource.path(modelFile.path)),
      params: ModelParams(
        contextSize: options.contextSize,
        preferredBackend: options.forceCpu ? GpuBackend.cpu : GpuBackend.auto,
        gpuLayers: options.forceCpu ? 0 : ModelParams.maxGpuLayers,
        numberOfThreads: options.threads,
        numberOfThreadsBatch: options.threadsBatch,
        batchSize: options.batchSize,
        microBatchSize: options.microBatchSize,
        maxParallelSequences: options.maxParallelSequences,
      ),
    );

    final String backendName = await engine.getBackendName();
    print('Runtime backend: $backendName');

    final List<double> queryVector = await engine.embed(
      options.query,
      normalize: options.normalize,
    );
    final List<List<double>> documentVectors = await engine.embedBatch(
      options.documents,
      normalize: options.normalize,
    );

    if (queryVector.isEmpty || documentVectors.isEmpty) {
      throw StateError('Embedding generation returned empty vectors.');
    }

    vectorSearchService.loadExtension();
    database = vectorSearchService.openDatabase(options.databasePath);

    vectorSearchService.seedVectorTable(
      database,
      documents: options.documents,
      embeddings: documentVectors,
      distanceMetric: options.distanceMetric,
    );

    final bool requireQuantizedSearchData =
        options.useQuantizedSearch || options.compareExact;

    int? quantizedRows;
    if (requireQuantizedSearchData) {
      quantizedRows = vectorSearchService.prepareQuantizedSearch(
        database,
        preload: options.preloadQuantized,
        qtype: options.quantizedQtype,
        maxMemory: options.quantizedMaxMemory,
      );
    }

    final int effectiveTopK = options.topK > options.documents.length
        ? options.documents.length
        : options.topK;

    final List<SqliteVectorMatch>? quantizedMatches = requireQuantizedSearchData
        ? vectorSearchService.searchNearestDocuments(
            database,
            queryVector: queryVector,
            topK: effectiveTopK,
            quantized: true,
          )
        : null;

    final List<SqliteVectorMatch>? exactMatches =
        (!options.useQuantizedSearch || options.compareExact)
        ? vectorSearchService.searchNearestDocuments(
            database,
            queryVector: queryVector,
            topK: effectiveTopK,
            quantized: false,
          )
        : null;

    final List<SqliteVectorMatch> activeMatches = options.useQuantizedSearch
        ? quantizedMatches!
        : exactMatches!;

    final List<ScoredSqliteVectorMatch> scoredMatches = vectorSearchService
        .scoreMatches(activeMatches, distanceMetric: options.distanceMetric);

    final FilteredScoredMatches filtered = vectorSearchService
        .filterByMinSimilarity(
          scoredMatches,
          minSimilarity: options.minSimilarity,
        );

    final String vectorVersion =
        database.select('SELECT vector_version() AS version').first['version']
            as String;
    final String vectorBackend =
        database.select('SELECT vector_backend() AS backend').first['backend']
            as String;

    print('\nSQLite Vector version: $vectorVersion');
    print('SQLite Vector backend: $vectorBackend');
    print('Query: ${options.query}');
    print('Distance metric: ${options.distanceMetric}');
    print(
      'Search mode: ${options.useQuantizedSearch ? 'QUANTIZED' : 'FULL_SCAN'}',
    );
    if (options.compareExact) {
      print('Compare exact mode: enabled');
    }
    if (quantizedRows != null) {
      print('Quantized rows: $quantizedRows');
      print(
        'Quantized preload: ${options.preloadQuantized ? 'enabled' : 'disabled'}',
      );
      print('Quantized qtype: ${options.quantizedQtype}');
      if (options.quantizedMaxMemory != null) {
        print('Quantized max memory: ${options.quantizedMaxMemory}');
      }
    }
    if (options.minSimilarity != null) {
      print(
        'Minimum similarity filter: ${options.minSimilarity!.toStringAsFixed(4)}',
      );
    }
    if (options.topK > options.documents.length) {
      print(
        'Requested top-k=${options.topK} but corpus has only '
        '${options.documents.length} documents. Returning $effectiveTopK results.',
      );
    }
    if (filtered.filteredCount > 0) {
      print(
        'Filtered out ${filtered.filteredCount} result(s) below '
        'similarity threshold.',
      );
    }

    print('\nTop ${filtered.matches.length} matches:');
    for (final ScoredSqliteVectorMatch scored in filtered.matches) {
      final SqliteVectorMatch match = scored.match;
      final ScoreInterpretation interpretation = scored.interpretation;
      print(
        '- #${match.id}  distance=${match.distance.toStringAsFixed(6)}  '
        'similarity=${interpretation.similarity.toStringAsFixed(4)}  '
        'relevance=${interpretation.relevance}  '
        '${_truncate(match.content, 120)}',
      );
    }

    if (filtered.matches.isEmpty) {
      print('No matches passed the active similarity threshold.');
    }

    if (options.compareExact &&
        exactMatches != null &&
        quantizedMatches != null) {
      final QuantizedComparisonStats stats = vectorSearchService
          .computeQuantizedRecallAtK(
            exactMatches: exactMatches,
            quantizedMatches: quantizedMatches,
          );

      print('\nQuantized quality check:');
      print(
        '- recall@${stats.k} = ${stats.recall.toStringAsFixed(4)} '
        '(${stats.overlapCount}/${stats.k})',
      );
      if (stats.meanDistanceDelta != null &&
          stats.maxAbsoluteDistanceDelta != null) {
        print(
          '- Mean distance delta (quantized - exact): '
          '${stats.meanDistanceDelta!.toStringAsFixed(6)}',
        );
        print(
          '- Max absolute distance delta (shared IDs): '
          '${stats.maxAbsoluteDistanceDelta!.toStringAsFixed(6)}',
        );
      } else {
        print('- No overlapping IDs; distance deltas unavailable.');
      }
    }

    print('\nHow to read these results:');
    if (options.distanceMetric == cosineMetric) {
      print(
        '- COSINE distance: lower is better (0 means identical direction).',
      );
      print(
        '- Approx similarity is reported as (1 - distance), clamped to [-1, 1].',
      );
    } else {
      print('- L2 distance: lower is better (0 means identical vector).');
      print(
        '- Similarity is reported as 1 / (1 + distance) for quick ranking intuition.',
      );
    }
  } on LlamaUnsupportedException catch (error) {
    print('Embeddings are not available on this backend: $error');
    exitCode = 2;
  } on SqliteException catch (error) {
    print('SQLite vector operation failed: $error');
    exitCode = 3;
  } catch (error) {
    print('Error: $error');
    exitCode = 1;
  } finally {
    database?.close();
    await engine.dispose();
  }
}

String _truncate(String value, int maxLength) {
  if (value.length <= maxLength) {
    return value;
  }
  return '${value.substring(0, maxLength - 3)}...';
}
