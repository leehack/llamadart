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

const _arithmeticPrompt = 'What is 3 + 4? Reply with the equation only.';
const _montrealPrompt = 'Reply with exactly: Montréal 👋';

void main() {
  final temp = useSuiteSystemTemp();
  final modelPath = Platform.environment['LITERT_LM_MODEL'];

  test(
    'corrected Qwen3 keeps arithmetic and Unicode exact under host load',
    () async {
      final modelHash = (await sha256.bind(File(modelPath!).openRead()).first)
          .toString();
      expect(modelHash, qwen3UpdatedModelSha256);
      final backend = LiteRtLmBackendPreference.values.byName(
        Platform.environment['LITERT_LM_BACKEND'] ?? 'cpu',
      );
      expect(
        backend,
        anyOf(LiteRtLmBackendPreference.cpu, LiteRtLmBackendPreference.gpu),
      );
      final isCpu = backend == LiteRtLmBackendPreference.cpu;
      await LlamaLogging.configure(nativeLevel: LlamaLogLevel.info);
      addTearDown(LlamaLogging.configure);

      final engine = LlamaEngine(LlamaBackend());
      addTearDown(engine.dispose);
      await engine.loadModel(
        modelPath,
        modelParams: LiteRtLmModelParams(
          contextSize: 1024,
          numberOfThreads: isCpu ? 2 : 0,
          device: isCpu ? ComputeDevice.cpu : ComputeDevice.gpu,
          cacheDir: temp().createTempSync('cache_').path,
        ),
      );
      expect(await engine.getBackendName(), 'LiteRT-LM ${backend.name}');

      // Contention makes the background Metal command-buffer race reproducible.
      const workers = 16;
      final load = <Process>[];
      const trials = 100;
      const fixtures = {
        _arithmeticPrompt: '3 + 4 = 7',
        _montrealPrompt: 'Montréal 👋',
      };
      final mismatches = <String, List<String>>{};
      try {
        for (var worker = 0; worker < workers; worker++) {
          load.add(
            await Process.start('/usr/bin/openssl', [
              'dgst',
              '-sha256',
              '/dev/zero',
            ], mode: ProcessStartMode.inheritStdio),
          );
        }
        for (final fixture in fixtures.entries) {
          final wrong = mismatches[fixture.key] = [];
          for (var trial = 0; trial < trials; trial++) {
            final reply = await _ask(engine, fixture.key);
            if (reply != fixture.value) wrong.add(reply);
          }
        }
      } finally {
        for (final worker in load) {
          worker.kill();
        }
        final exits = await Future.wait(load.map((worker) => worker.exitCode));
        expect(exits, everyElement(-ProcessSignal.sigterm.signalNumber));
      }

      stdout.writeln(
        jsonEncode({
          'backend': backend.name,
          'model_sha256': modelHash,
          'load_workers': workers,
          'trials_per_prompt': trials,
          'mismatches': mismatches,
        }),
      );
      for (final fixture in mismatches.entries) {
        expect(fixture.value, isEmpty, reason: fixture.key);
      }
    },
    skip: !Platform.isMacOS
        ? 'The lookahead race regression requires macOS.'
        : modelPath == null
        ? 'Set LITERT_LM_MODEL to the corrected Qwen3 bundle.'
        : false,
  );
}

Future<String> _ask(LlamaEngine engine, String text) async {
  final content = StringBuffer();
  await for (final chunk in engine.create(
    [LlamaChatMessage.fromText(role: LlamaChatRole.user, text: text)],
    params: const GenerationParams(maxTokens: 32, temp: 0, topK: 1, seed: 1),
    enableThinking: false,
  )) {
    content.write(chunk.choices.first.delta.content ?? '');
  }
  return content.toString();
}
