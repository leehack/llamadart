@Tags(<String>['local-only'])
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:test/test.dart';

// Explicit existing local assets only; no model discovery or downloads.
// STUDIO_PLAYGROUND_CHAT_MODEL, STUDIO_PLAYGROUND_DECISION_MODEL,
// STUDIO_PLAYGROUND_DECISION_HEAD, optional STUDIO_PLAYGROUND_EVIDENCE.
const _referencePath =
    '../llamadart_validation/assets/decision/laya_0_3_5_reference.json';

Future<String> _sha256(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

void _probabilities(Map<String, double> values) {
  expect(values, isNotEmpty);
  for (final value in values.values) {
    expect(value.isFinite, isTrue);
    expect(value, inInclusiveRange(0, 1));
  }
  // Laya's public answers and the reference round probabilities to 4 decimals.
  expect(values.values.reduce((a, b) => a + b), closeTo(1, 0.001));
}

void main() {
  final chatPath = Platform.environment['STUDIO_PLAYGROUND_CHAT_MODEL'];
  final decisionPath = Platform.environment['STUDIO_PLAYGROUND_DECISION_MODEL'];
  final headPath = Platform.environment['STUDIO_PLAYGROUND_DECISION_HEAD'];
  final configured =
      chatPath != null && decisionPath != null && headPath != null;
  late Directory root;
  late DirectLlamaInferencePort inference;
  late DirectLlamaPlaygroundPort port;
  late DefaultStudioModelStorageAdapter storage;
  late PlaygroundWorkspaceController controller;
  late List<Map<String, dynamic>> referenceRows;
  final records = <Map<String, Object?>>[];
  final passedCases = <String>[];

  void record(String phase, Map<String, Object?> fields) {
    final entry = <String, Object?>{'phase': phase, ...fields};
    records.add(entry);
    print('STUDIO_PLAYGROUND_ACCEPTANCE ${jsonEncode(entry)}');
  }

  group(
    'real macOS Playground acceptance',
    () {
      setUpAll(() async {
        expect(Platform.isMacOS, isTrue);
        for (final path in [chatPath!, decisionPath!, headPath!]) {
          expect(await File(path).exists(), isTrue);
        }
        root = await Directory.systemTemp.createTemp('studio_playground_');
        inference = DirectLlamaInferencePort();
        port = DirectLlamaPlaygroundPort(sharedChatPort: inference);
        storage = DefaultStudioModelStorageAdapter(
          downloadManager: DefaultModelDownloadManager.appPrivate(
            cacheDirectory: '${root.path}/unused-model-cache',
          ),
          localScanner: LocalModelScanner(defaultRoots: const []),
        );
        controller = PlaygroundWorkspaceController(
          storagePort: storage,
          playgroundPort: port,
          isWeb: false,
          isMobile: false,
        );
        final fixture =
            jsonDecode(await File(_referencePath).readAsString())
                as Map<String, dynamic>;
        referenceRows = (fixture['rows'] as List).cast<Map<String, dynamic>>();
        record('provenance', {
          'harnessSha256': await _sha256(
            File('test/local_playground_acceptance_test.dart'),
          ),
          'qwenSha256': await _sha256(File(chatPath)),
          'layaSha256': await _sha256(File(decisionPath)),
          'headSha256': await _sha256(File(headPath)),
          'referenceSha256': await _sha256(File(_referencePath)),
          'referenceSource': fixture['source'],
          'chatDecodeThreads': 2,
          'chatBatchThreads': 2,
          'decisionThreads':
              'Production Studio API default: DecisionModelParams.threads=0 (automatic); no override exposed.',
          'decisionDevice':
              'Production Studio API default: ComputeDevice.auto; actual device recorded with results.',
        });
        await inference.loadModel(
          assets: ResolvedModelAssets(
            descriptor: CuratedModelCatalog.byId('qwen3.5-0.8b-q4-k-m')!,
            primarySource: ModelSource.path(chatPath),
          ),
          settings: const StudioSettings(
            preferredBackend: GpuBackend.metal,
            computeDevice: ComputeDevice.gpu,
            gpuLayers: 99,
            autoTuneHardware: false,
            contextSize: 4096,
            requestedContextSize: 4096,
            numberOfThreads: 2,
            numberOfThreadsBatch: 2,
            maxTokens: 32,
            thinkingEnabled: false,
            toolsEnabled: false,
          ),
          isWeb: false,
        );
        final runtime = inference.runtimeStore.state;
        record('runtime', {
          'backend': runtime.backendName,
          'resolvedGpuLayers': runtime.resolvedGpuLayers,
          'resolvedContextSize': runtime.resolvedContextSize,
          'metadata': runtime.metadata,
        });
        expect(runtime.isReady, isTrue);
        expect(runtime.backendName.toLowerCase(), contains('metal'));
        expect(runtime.resolvedGpuLayers, greaterThan(0));
      });

      tearDownAll(() async {
        try {
          await controller.dispose();
          await port.dispose();
          await inference.dispose();
          await storage.dispose();
          expect(inference.engine.isDisposed, isTrue);
          expect(await controller.store.stream.isEmpty, isTrue);
          await root.delete(recursive: true);
        } finally {
          final evidencePath =
              Platform.environment['STUDIO_PLAYGROUND_EVIDENCE'];
          if (evidencePath != null) {
            final file = File(evidencePath);
            await file.parent.create(recursive: true);
            await file.writeAsString(
              const JsonEncoder.withIndent('  ').convert({
                'kind': 'studio-playground-acceptance-v1',
                'records': records,
                'passedCases': passedCases,
                'completed': passedCases.length == 3,
              }),
              flush: true,
            );
          }
        }
      });

      test(
        'Token Inspector preserves native IDs, pieces and aggregate decoding',
        () async {
          final vocabularyPieces = <int, String>{};
          for (final text in [
            'int add(int a, int b) => a + b;\n',
            'Montreal: 123 + 456 = 579.',
            'Montréal 🦙 — local inference',
          ]) {
            await controller.runTokenInspection(text);
            expect(controller.state.errorMessage, isNull);
            expect(controller.state.isEvaluating, isFalse);
            final tokens = controller.state.inspectedTokens;
            expect(tokens, isNotEmpty);
            // The Studio controller is the action under test. The same real
            // engine's tokenizer/detokenizer provides the mapping oracle only.
            await inference.runExclusiveOnEngine(
              'Playground acceptance token oracle',
              (engine) async {
                final ids = await engine.tokenize(text, addSpecial: false);
                expect(tokens.map((token) => token.id), ids);
                expect(await engine.detokenize(ids), text);
                for (final token in tokens) {
                  expect(token.id, greaterThanOrEqualTo(0));
                  expect(token.piece, await engine.detokenize([token.id]));
                  expect(
                    vocabularyPieces.putIfAbsent(token.id, () => token.piece),
                    token.piece,
                  );
                }
              },
            );
            final joined = tokens.map((token) => token.piece).join();
            if (text.codeUnits.every((unit) => unit < 128)) {
              expect(joined, text);
            }
            record('tokens', {
              'input': text,
              'ids': tokens.map((token) => token.id).toList(),
              'pieces': tokens.map((token) => token.piece).toList(),
              'joinedPiecesEqualInput': joined == text,
              'aggregateNativeDecodeEqualInput': true,
            });
          }
          expect(inference.isBusy, isFalse);
          passedCases.add('tokens');
        },
      );

      test(
        'bounded benchmark reports real backend and evaluated token counts',
        () async {
          const target = 16;
          await controller.runBenchmark(targetDecodeTokens: target);
          expect(controller.state.errorMessage, isNull);
          expect(controller.state.isEvaluating, isFalse);
          final summary = controller.state.benchmarkHistory.single;
          final native = await inference.runExclusiveOnEngine(
            'Playground acceptance benchmark diagnostics',
            (engine) => engine.getPerformanceContext(),
          );
          record('benchmark', {
            'backend': summary.backendName,
            'model': summary.modelName,
            'targetDecodeTokens': target,
            'promptTokens': summary.promptTokens,
            'generatedTokens': summary.generatedTokens,
            'prefillLatencyMs': summary.prefillLatencyMs,
            'decodeElapsedMs': summary.decodeElapsedMs,
            'nativePromptEvalTokens': native?.promptEvalTokens,
            'nativeEvalTokens': native?.evalTokens,
            'nativeSampleCount': native?.sampleCount,
          });
          expect(summary.backendName, inference.runtimeStore.state.backendName);
          expect(
            summary.modelName,
            inference.runtimeStore.state.activeModelLabel,
          );
          expect(summary.promptTokens, greaterThan(0));
          expect(summary.generatedTokens, inInclusiveRange(1, target));
          expect(summary.prefillLatencyMs, greaterThanOrEqualTo(0));
          expect(summary.decodeElapsedMs, greaterThan(0));
          expect(summary.prefillTokensPerSecond.isFinite, isTrue);
          expect(summary.decodeTokensPerSecond.isFinite, isTrue);
          expect(
            native,
            isNotNull,
            reason:
                'Native token counters are required for this native acceptance profile.',
          );
          expect(
            summary.promptTokens,
            native!.promptEvalTokens,
            reason:
                'Evaluated prompt count must include the rendered chat template.',
          );
          if (native.sampleCount > 0) {
            expect(summary.generatedTokens, native.sampleCount);
          }
          expect(inference.isBusy, isFalse);
          passedCases.add('benchmark');
        },
      );

      test(
        'Laya decisions preserve reference labels and normalized score distributions',
        () async {
          await controller.loadLabModel(
            StudioModelDescriptor(
              id: 'acceptance-laya-q8',
              name: 'Explicit local Laya Q8',
              description: 'Existing local encoder and decision head.',
              category: StudioModelCategory.playground,
              specialty: StudioModelSpecialty.decision,
              filename: 'laya-Q8_0.gguf',
              sourceUri: decisionPath!,
              companions: [
                StudioModelCompanionAsset(
                  role: 'decisionHead',
                  filename: 'laya-head.safetensors',
                  sourceUri: headPath!,
                ),
              ],
            ),
          );
          expect(controller.state.errorMessage, isNull);
          final category = referenceRows.singleWhere(
            (row) => row['id'] == 'plain_text/category',
          );
          final urgency = referenceRows.singleWhere(
            (row) => row['id'] == 'plain_text/urgency5',
          );
          final categoryQuestion = category['question'] as Map<String, dynamic>;
          final urgencyQuestion = urgency['question'] as Map<String, dynamic>;
          final labels = (categoryQuestion['criteria'] as List).cast<String>();
          final levels = (urgencyQuestion['criteria'] as List).cast<String>();
          final questions = <SystemOneQuestionSpec>[
            SystemOneChoiceQuestionSpec(
              id: 'category',
              prompt: categoryQuestion['instructions'] as String,
              labels: labels,
            ),
            SystemOneScoreQuestionSpec(
              id: 'urgency',
              prompt: urgencyQuestion['instructions'] as String,
              levels: levels,
            ),
          ];
          final result = await controller.runDecisionBatch(
            state: category['state'] as Object,
            questions: questions,
          );
          expect(controller.state.errorMessage, isNull);
          expect(result, isNotNull);
          final choice = result!.byId('category')! as SystemOneChoiceAnswer;
          final score = result.byId('urgency')! as SystemOneScoreAnswer;
          record('decision', {
            'referenceRows': ['plain_text/category', 'plain_text/urgency5'],
            'device': result.deviceName,
            'elapsedMs': result.elapsedMs,
            'choice': choice.choice,
            'choiceProbabilities': choice.probabilities,
            'choiceConfidence': choice.confidence,
            'score': score.score,
            'levels': score.levels,
            'levelProbabilities': score.levelProbabilities,
            'scoreConfidence': score.confidence,
          });
          expect(result.deviceName, isNotEmpty);
          expect(result.answers.map((answer) => answer.id), [
            'category',
            'urgency',
          ]);
          expect(choice.choice, (category['answer'] as Map)['choice']);
          expect(choice.probabilities.keys, labels);
          expect(score.levels, levels);
          expect(score.levelProbabilities.keys, levels);
          _probabilities(choice.probabilities);
          _probabilities(score.levelProbabilities);
          for (final answer in result.answers) {
            expect(answer.confidence.isFinite, isTrue);
            expect(answer.confidence, inInclusiveRange(0, 1));
          }
          var weighted = 0.0;
          for (var index = 0; index < levels.length; index++) {
            weighted += index * score.levelProbabilities[levels[index]]!;
          }
          expect(score.score, closeTo(weighted, 0.001));
          expect(score.score, inInclusiveRange(0, levels.length - 1));
          // Reuse the native Q8 decision E2E's 0.05 probability tolerance against
          // the maintained Laya 0.3.5 FP32 reference, rather than invented values.
          final reference =
              ((urgency['answer'] as Map)['probabilities'] as Map);
          for (var index = 0; index < levels.length; index++) {
            expect(
              score.levelProbabilities[levels[index]],
              closeTo((reference['$index'] as num).toDouble(), 0.05),
            );
          }
          final speed = await controller.runDecisionSpeedBenchmark(
            state: category['state'] as Object,
            questions: questions,
            iterations: 2,
          );
          expect(controller.state.errorMessage, isNull);
          expect(speed, isNotNull);
          expect(speed!.iterations, 2);
          expect(speed.questionsPerPass, questions.length);
          expect(speed.deviceName, result.deviceName);
          expect(speed.totalElapsedMs, greaterThan(0));
          expect(speed.minMs, greaterThan(0));
          expect(speed.medianMs, greaterThanOrEqualTo(speed.minMs));
          expect(speed.p95Ms, greaterThanOrEqualTo(speed.medianMs));
          record('decisionBenchmark', {
            'iterations': speed.iterations,
            'questionsPerPass': speed.questionsPerPass,
            'device': speed.deviceName,
            'totalElapsedMs': speed.totalElapsedMs,
            'minMs': speed.minMs,
            'medianMs': speed.medianMs,
            'p95Ms': speed.p95Ms,
          });
          passedCases.add('decision');
        },
      );
    },
    skip: configured
        ? false
        : 'Set all three STUDIO_PLAYGROUND_* model/head paths to existing local files.',
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
