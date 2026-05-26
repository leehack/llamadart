import 'dart:convert';
import 'dart:io';

import 'package:llamadart/llamadart.dart';

const _defaultPrompt =
    'Write a concise explanation of why on-device language models are useful.';

Future<void> main(List<String> args) async {
  final modelPath = args.isNotEmpty
      ? args.first
      : '/opt/UnitySrc/personal/llama/llamadart/models/gemma-4-E2B-it-Q4_K_S.gguf';
  final prompt = args.length > 1 ? args[1] : _defaultPrompt;
  final outputTokens = args.length > 2 ? int.parse(args[2]) : 256;
  const warmups = 1;
  const runs = 3;

  final engine = LlamaEngine(LlamaBackend());
  try {
    final loadSw = Stopwatch()..start();
    await engine.loadModel(
      modelPath,
      modelParams: ModelParams(
        contextSize: 4096,
        gpuLayers: ModelParams.maxGpuLayers,
        preferredBackend: GpuBackend.metal,
      ),
    );
    loadSw.stop();

    final backendName = await engine.getBackendName();
    final resolvedGpuLayers = await engine.getResolvedGpuLayers();
    final promptTokens = await engine.getTokenCount(prompt);

    for (var i = 0; i < warmups; i++) {
      await engine
          .generate(
            prompt,
            params: GenerationParams(maxTokens: outputTokens, seed: 1),
          )
          .drain<void>();
    }

    BackendPerfContextData? perf;
    var wallMs = 0;
    var lastText = '';
    for (var i = 0; i < runs; i++) {
      final buffer = StringBuffer();
      final sw = Stopwatch()..start();
      await for (final chunk in engine.generate(
        prompt,
        params: GenerationParams(maxTokens: outputTokens, seed: 1),
      )) {
        buffer.write(chunk);
      }
      sw.stop();
      wallMs = sw.elapsedMilliseconds;
      lastText = buffer.toString();
      perf = await engine.getPerformanceContext();
    }

    final metrics = {
      'loadMilliseconds': loadSw.elapsedMilliseconds,
      'wallMilliseconds': wallMs,
      'backendName': backendName,
      'resolvedGpuLayers': resolvedGpuLayers,
      'targetDecodeTokens': outputTokens,
      'actualPromptTokens': promptTokens,
      'promptEvalTokens': perf?.promptEvalTokens,
      'evalTokens': perf?.evalTokens,
      'hitEosBeforeTarget': perf == null
          ? null
          : perf.evalTokens < outputTokens,
      'promptEvalMs': perf?.promptEvalMs,
      'evalMs': perf?.evalMs,
      'sampleMs': perf?.sampleMs,
      'prefillTokensPerSecond': perf == null || perf.promptEvalMs <= 0
          ? null
          : perf.promptEvalTokens / (perf.promptEvalMs / 1000.0),
      'decodeTokensPerSecond': perf == null || perf.evalMs <= 0
          ? null
          : perf.evalTokens / (perf.evalMs / 1000.0),
      'decodeWithSamplingTokensPerSecond':
          perf == null || perf.evalMs + perf.sampleMs <= 0
          ? null
          : perf.evalTokens / ((perf.evalMs + perf.sampleMs) / 1000.0),
      'wallTokensPerSecond': wallMs <= 0
          ? null
          : perf?.evalTokens != null
          ? perf!.evalTokens / (wallMs / 1000.0)
          : null,
    };

    print('RESULT llamadart ${jsonEncode(metrics)}');
    print('LAST_TEXT ${jsonEncode(lastText)}');
  } finally {
    await engine.dispose();
    exit(0);
  }
}
