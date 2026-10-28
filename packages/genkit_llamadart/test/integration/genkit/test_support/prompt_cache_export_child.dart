import 'dart:io';

import 'package:genkit_llamadart/genkit_llamadart.dart';

/// The model parameters the export proof uses in both processes.
const ModelParams promptCacheExportParams = ModelParams(
  device: ComputeDevice.cpu,
  contextSize: 512,
  numberOfThreads: 1,
  numberOfThreadsBatch: 1,
  batchSize: 1,
  microBatchSize: 1,
);

/// Caches `<prompt>` for `<model>` and writes its export to `<output>`.
///
/// Usage: `dart prompt_cache_export_child.dart <model> <output> <prompt>`
Future<void> main(List<String> args) async {
  final pool = LlamaDartRuntimePool(
    model: LlamaModelDefinition(
      name: 'export',
      modelPath: args[0],
      modelParams: promptCacheExportParams,
    ),
    enablePromptCache: true,
    enablePromptCacheExport: true,
    maxOwners: 1,
    maxPromptCaches: 1,
  );
  try {
    final owner = await pool.open();
    final cache = await owner.cachePrompt(args[2]);
    await File(args[1]).writeAsBytes(cache.exportBytes(), flush: true);
  } finally {
    await pool.close();
  }
}
