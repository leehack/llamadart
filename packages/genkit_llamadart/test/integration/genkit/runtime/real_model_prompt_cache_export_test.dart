@TestOn('vm')
@Tags(['real-model', 'prompt-cache-model'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:genkit/genkit.dart';
import 'package:genkit_llamadart/genkit_llamadart.dart';
import 'package:llamadart/llamadart.dart' as llama;
import 'package:test/test.dart';

import '../test_support/prompt_cache_export_child.dart';
import '../test_support/real_model_test_support.dart';

const _prompt = 'Once upon a time, in a quiet village near the mountains';
const _sampling = GenerationParams(maxTokens: 8, temp: 0, seed: 42);

Matcher _refused(LlamaDartPromptCacheImportFailure failure, String secret) =>
    throwsA(
      isA<LlamaDartPromptCacheImportException>()
          .having((e) => e.failure, 'failure', failure)
          .having((e) => '$e', 'message', isNot(contains(secret)))
          .having((e) => '$e', 'message', isNot(contains(_prompt))),
    );

void main() {
  test(
    'an export from another process imports, restores and refuses mismatches',
    () async {
      if (Platform.environment['LLAMADART_RUN_PROMPT_CACHE_PROOF'] != '1') {
        markTestSkipped(
          'Set LLAMADART_RUN_PROMPT_CACHE_PROOF=1 for native prompt-cache qualification.',
        );
        return;
      }
      final path = await resolveIntegrationModelPath();
      if (path == null) return;
      final directory = await Directory.systemTemp.createTemp(
        'genkit-cache-export-proof-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final exportFile = File('${directory.path}/cache.bin');
      final child = await Process.run(Platform.resolvedExecutable, [
        'run',
        'test/integration/genkit/test_support/prompt_cache_export_child.dart',
        path,
        exportFile.path,
        _prompt,
      ]);
      expect(child.exitCode, 0, reason: '${child.stdout}\n${child.stderr}');
      final exported = await exportFile.readAsBytes();

      final observer = _Observer();
      LlamaDartRuntimePool makePool({
        String? modelPath,
        ModelParams params = promptCacheExportParams,
        int maxBytes = 64 * 1024 * 1024,
        bool export = true,
      }) => LlamaDartRuntimePool(
        model: LlamaModelDefinition(
          name: 'import',
          modelPath: modelPath ?? path,
          modelParams: params,
        ),
        enablePromptCache: true,
        enablePromptCacheExport: export,
        maxPromptCaches: 2,
        maxPromptCacheBytes: maxBytes,
        observers: [observer],
      );

      final pool = makePool();
      addTearDown(pool.close);
      final a = await pool.open();
      final b = await pool.open();

      final controller = CancellationController()..cancel();
      await expectLater(
        a.importPromptCache(
          exported,
          prompt: _prompt,
          cancellation: controller.token,
        ),
        throwsA(isA<CancelledException>()),
      );
      expect(a.isClosed, isFalse);

      await expectLater(
        a.importPromptCache(exported, prompt: '$_prompt and'),
        _refused(LlamaDartPromptCacheImportFailure.tokenMismatch, path),
      );
      final altered = Uint8List.fromList(exported)..[exported.length - 1] ^= 1;
      await expectLater(
        a.importPromptCache(altered, prompt: _prompt),
        _refused(LlamaDartPromptCacheImportFailure.corrupt, path),
      );
      expect(a.isClosed, isFalse);

      final imported = await a.importPromptCache(exported, prompt: _prompt);
      expect(imported.tokenCount, greaterThan(2));
      expect(imported.exportBytes(), exported);
      final interleaved = await b.importPromptCache(exported, prompt: _prompt);
      await b.scoreNextToken(
        'The planets of the solar system are',
        topK: 1,
        reusePromptPrefix: false,
      );
      final resumed = await a.generateFromCache(imported, params: _sampling);
      expect(observer.last!.usage!.cachedPromptTokens, imported.tokenCount - 1);
      final baseline = await a.generate(
        _prompt,
        params: _sampling.copyWith(reusePromptPrefix: false),
      );
      expect(resumed, baseline);
      expect(
        await b.generateFromCache(interleaved, params: _sampling),
        baseline,
      );

      await expectLater(
        a.importPromptCache(exported, prompt: _prompt),
        _refused(LlamaDartPromptCacheImportFailure.overBudget, path),
      );
      imported.dispose();
      interleaved.dispose();
      await expectLater(
        () => imported.exportBytes(),
        throwsA(isA<llama.LlamaStateException>()),
      );

      final tinyPool = makePool(maxBytes: 1);
      addTearDown(tinyPool.close);
      await expectLater(
        (await tinyPool.open()).importPromptCache(exported, prompt: _prompt),
        _refused(LlamaDartPromptCacheImportFailure.overBudget, path),
      );

      final otherConfig = makePool(
        params: promptCacheExportParams.copyWith(contextSize: 256),
      );
      addTearDown(otherConfig.close);
      final otherConfigOwner = await otherConfig.open();
      await expectLater(
        otherConfigOwner.importPromptCache(exported, prompt: _prompt),
        _refused(LlamaDartPromptCacheImportFailure.identityMismatch, path),
      );
      expect(otherConfigOwner.isClosed, isFalse);

      final changedModel = await File(
        path,
      ).copy('${directory.path}/changed.gguf');
      await changedModel.writeAsBytes([0], mode: FileMode.append, flush: true);
      final otherModel = makePool(modelPath: changedModel.path);
      addTearDown(otherModel.close);
      await expectLater(
        (await otherModel.open()).importPromptCache(exported, prompt: _prompt),
        _refused(
          LlamaDartPromptCacheImportFailure.modelMismatch,
          changedModel.path,
        ),
      );

      final noExport = makePool(export: false);
      addTearDown(noExport.close);
      final local = await (await noExport.open()).cachePrompt(_prompt);
      expect(
        local.exportBytes,
        throwsA(isA<llama.LlamaUnsupportedException>()),
      );
      print(
        'native prompt-cache export proof: cross-process import, restore parity, '
        'interleaved owners, cancellation and every refusal pass',
      );
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

final class _Observer extends llama.LlamaEngineObserver {
  llama.LlamaOperationResult? last;
  @override
  llama.LlamaOperationObserver onStart(llama.LlamaOperation operation) =>
      _Operation(this);
}

final class _Operation extends llama.LlamaOperationObserver {
  _Operation(this.owner);
  final _Observer owner;
  @override
  void onEnd(llama.LlamaOperationResult result) => owner.last = result;
}
