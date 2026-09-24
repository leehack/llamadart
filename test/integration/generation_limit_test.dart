@TestOn('vm')
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/backends/backend.dart';
import 'package:test/test.dart';

import '../test_helper.dart';

void main() {
  late LlamaBackend backend;
  late BackendGenerationLimitReporting limits;
  late BackendPerformanceDiagnostics performance;
  late int model;
  late int context;
  late int contextSize;

  setUpAll(() async {
    backend = LlamaBackend();
    limits = backend as BackendGenerationLimitReporting;
    performance = backend as BackendPerformanceDiagnostics;
    final file = await TestHelper.getTestModel();
    const params = ModelParams(
      contextSize: 256,
      gpuLayers: 0,
      preferredBackend: GpuBackend.cpu,
      numberOfThreads: 2,
      numberOfThreadsBatch: 2,
    );
    model = await backend.modelLoad(file.path, params);
    context = await backend.contextCreate(model, params);
    contextSize = await backend.getContextSize(context);
  });
  tearDownAll(() async {
    await backend.contextFree(context);
    await backend.modelFree(model);
    await backend.dispose();
  });

  const prompt = 'Once upon a time';
  const endless = GenerationParams(
    maxTokens: 100000,
    temp: 0,
    seed: 1,
    penalty: 1,
    grammar: 'root ::= "a " root',
  );

  Future<(String, BackendGenerationLimit?)> run(GenerationParams params) async {
    final generation = backend.generate(context, prompt, params);
    final chunks = await generation.toList();
    return (
      utf8.decode(chunks.expand((chunk) => chunk).toList()),
      limits.generationLimitOf(generation),
    );
  }

  group('llama.cpp generation limits', () {
    test('a full context reports contextSize', () async {
      final (_, limit) = await run(endless);
      final perf = (await performance.getPerformanceContext(context))!;

      expect(limit, BackendGenerationLimit.contextSize);
      expect(perf.promptEvalTokens + perf.evalTokens, contextSize);
    });

    test('maxTokens reports maxTokens', () async {
      final (_, limit) = await run(endless.copyWith(maxTokens: 5));
      final perf = (await performance.getPerformanceContext(context))!;

      expect(limit, BackendGenerationLimit.maxTokens);
      expect(perf.evalTokens, 5);
    });

    test('maxTokens equal to the natural length reports no limit', () async {
      const natural = GenerationParams(
        maxTokens: 100000,
        temp: 0,
        seed: 1,
        penalty: 1,
        grammar: 'root ::= "a a a"',
      );
      final (text, _) = await run(natural);
      final length = (await performance.getPerformanceContext(
        context,
      ))!.evalTokens;

      expect(await run(natural.copyWith(maxTokens: length)), (text, null));
      expect(
        (await run(natural.copyWith(maxTokens: length - 1))).$2,
        BackendGenerationLimit.maxTokens,
      );
    });

    test('an end-of-generation token reports no limit', () async {
      final (text, limit) = await run(
        endless.copyWith(grammar: 'root ::= "a a"'),
      );

      expect(text, 'a a');
      expect(limit, isNull);
    });

    test('a stop sequence reports no limit', () async {
      final (text, limit) = await run(
        endless.copyWith(stopSequences: <String>['a a a']),
      );

      expect(text, isEmpty);
      expect(limit, isNull);
    });

    test('cancellation reports no limit', () async {
      final generation = backend.generate(
        context,
        prompt,
        endless.copyWith(streamBatchTokenThreshold: 1),
      );
      var chunks = 0;
      await for (final _ in generation) {
        chunks++;
        backend.cancelGeneration();
      }

      expect(chunks, greaterThan(0));
      expect(limits.generationLimitOf(generation), isNull);
    });
  });

  group('speculative llama.cpp generation limits', () {
    const speculative = GenerationParams(
      maxTokens: 100000,
      temp: 0,
      seed: 1,
      penalty: 1,
      speculativeDecodingConfig: SpeculativeDecodingConfig.ngramSimple(
        ngramSizeN: 1,
        ngramSizeM: 4,
        ngramMinHits: 1,
      ),
    );

    test('a full context reports contextSize', () async {
      final (_, limit) = await run(speculative);

      expect(limit, BackendGenerationLimit.contextSize);
    });

    test('maxTokens reports maxTokens', () async {
      final (_, limit) = await run(speculative.copyWith(maxTokens: 12));

      expect(limit, BackendGenerationLimit.maxTokens);
    });

    test('a stop sequence reports no limit', () async {
      final (control, _) = await run(speculative.copyWith(maxTokens: 40));
      final stop = control.substring(20, 25);

      final (text, limit) = await run(
        speculative.copyWith(stopSequences: <String>[stop]),
      );

      expect(text, control.substring(0, control.indexOf(stop)));
      expect(limit, isNull);
    });
  });

  group('LlamaEngine.create finish reason', () {
    late LlamaEngine engine;

    setUpAll(() async {
      engine = LlamaEngine(LlamaBackend());
      await engine.loadModel(
        (await TestHelper.getTestModel()).path,
        modelParams: const ModelParams(
          contextSize: 256,
          gpuLayers: 0,
          preferredBackend: GpuBackend.cpu,
          numberOfThreads: 2,
          numberOfThreadsBatch: 2,
        ),
      );
    });
    tearDownAll(() => engine.dispose());

    Future<String?> finishReason(GenerationParams params) async {
      final chunks = await engine.create(const <LlamaChatMessage>[
        LlamaChatMessage.fromText(role: LlamaChatRole.user, text: prompt),
      ], params: params).toList();
      return chunks.last.choices.single.finishReason;
    }

    test('is length at a full context or maxTokens', () async {
      expect(await finishReason(endless), 'length');
      expect(await finishReason(endless.copyWith(maxTokens: 3)), 'length');
    });

    test('is stop at an end-of-generation token', () async {
      expect(
        await finishReason(endless.copyWith(grammar: 'root ::= "a a"')),
        'stop',
      );
    });
  });
}
