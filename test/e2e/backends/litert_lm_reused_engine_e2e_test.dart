@TestOn('vm')
@Tags(['local-only', 'e2e'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:llamadart/llamadart.dart';
import 'package:test/test.dart';

import '../../../tool/litert_lm_tokenizer_fixture.dart';
import '../../support/suite_system_temp.dart';

const _qwen35Sha256 =
    '684d4d34adf7176eb47f6026ff65c33d42584737254e5524a8d1ad62edc21b98';
const _countingPrompt = 'List the numbers from one to twenty in English.';
const _arithmeticPrompt = 'What is 3 + 4? Reply with the equation only.';

void main() {
  final temp = useSuiteSystemTemp();
  final modelPath = Platform.environment['LITERT_LM_MODEL'];

  test(
    'independent LiteRT-LM requests on a reused engine match fresh engines',
    () async {
      final backend = LiteRtLmBackendPreference.values.byName(
        Platform.environment['LITERT_LM_BACKEND'] ?? 'cpu',
      );
      expect(
        backend,
        anyOf(LiteRtLmBackendPreference.cpu, LiteRtLmBackendPreference.gpu),
      );
      final modelHash = (await sha256.bind(File(modelPath!).openRead()).first)
          .toString();
      expect(modelHash, anyOf(_qwen35Sha256, qwen3UpdatedModelSha256));
      final prompt = modelHash == _qwen35Sha256
          ? _countingPrompt
          : _arithmeticPrompt;
      final isCpu = backend == LiteRtLmBackendPreference.cpu;
      final params = LiteRtLmModelParams(
        contextSize: 1024,
        numberOfThreads: isCpu ? 2 : 0,
        device: isCpu ? ComputeDevice.cpu : ComputeDevice.gpu,
        cacheDir: temp().createTempSync('cache_').path,
      );
      await LlamaLogging.configure(nativeLevel: LlamaLogLevel.info);
      addTearDown(LlamaLogging.configure);

      Future<void> load(LlamaEngine engine) async {
        await engine.loadModel(modelPath, modelParams: params);
        expect(await engine.getBackendName(), 'LiteRT-LM ${backend.name}');
      }

      Future<String> ask(LlamaEngine engine, String text) async {
        final content = StringBuffer();
        await for (final chunk in engine.create(
          [LlamaChatMessage.fromText(role: LlamaChatRole.user, text: text)],
          params: const GenerationParams(
            maxTokens: 32,
            temp: 0,
            topK: 1,
            seed: 1,
          ),
          enableThinking: false,
        )) {
          content.write(chunk.choices.first.delta.content ?? '');
        }
        return content.toString();
      }

      final fresh = <String>[];
      for (var i = 0; i < 2; i++) {
        final engine = LlamaEngine(LlamaBackend());
        try {
          await load(engine);
          fresh.add(await ask(engine, prompt));
        } finally {
          await engine.dispose();
        }
      }

      final engine = LlamaEngine(LlamaBackend());
      addTearDown(engine.dispose);
      await load(engine);
      final repeated = [for (var i = 0; i < 5; i++) await ask(engine, prompt)];
      final unrelated = await ask(engine, 'Say hello in one short sentence.');
      final afterUnrelated = await ask(engine, prompt);
      await engine.unloadModel();
      await load(engine);
      final afterReload = await ask(engine, prompt);
      stdout.writeln(
        jsonEncode({
          'backend': backend.name,
          'model_sha256': modelHash,
          'fresh': fresh,
          'repeated': repeated,
          'unrelated': unrelated,
          'after_unrelated': afterUnrelated,
          'after_reload': afterReload,
        }),
      );

      expect(fresh.first.trim(), isNotEmpty);
      expect(fresh.first, isNot(contains(prompt)));
      expect(fresh.last, fresh.first);
      expect(repeated, everyElement(fresh.first));
      expect(unrelated.trim(), isNotEmpty);
      expect(afterUnrelated, fresh.first);
      expect(afterReload, fresh.first);
    },
    skip: modelPath == null
        ? 'Set LITERT_LM_MODEL to a locked Qwen bundle.'
        : false,
  );
}
