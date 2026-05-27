import 'dart:convert';

import 'package:llamadart/llamadart.dart';

const _defaultPrompt =
    'Write a concise explanation of why on-device language models are useful.';

Future<void> main(List<String> args) async {
  final modelPath = args.isNotEmpty
      ? args.first
      : '.dart_tool/litert_lm_models/gemma-4-E2B-it.litertlm';
  final backendArg = args.length > 1 ? args[1] : 'cpu';
  final prompt = args.length > 2 ? args[2] : _defaultPrompt;
  final outputTokens = args.length > 3 ? int.parse(args[3]) : 64;
  final preferredBackend = backendArg == 'cpu'
      ? GpuBackend.cpu
      : GpuBackend.metal;

  final engine = LlamaEngine(LlamaBackend());
  try {
    final loadSw = Stopwatch()..start();
    await engine.loadModel(
      modelPath,
      modelParams: ModelParams(
        contextSize: 4096,
        preferredBackend: preferredBackend,
      ),
    );
    loadSw.stop();

    final promptTokens = await engine.tokenize(prompt, addSpecial: false);
    final promptTokensWithSpecial = await engine.tokenize(
      prompt,
      addSpecial: true,
    );
    final promptRoundTrip = await engine.detokenize(promptTokens);
    final buffer = StringBuffer();
    final generateSw = Stopwatch()..start();
    await for (final chunk in engine.generate(
      prompt,
      params: GenerationParams(maxTokens: outputTokens, seed: 1),
    )) {
      buffer.write(chunk);
    }
    generateSw.stop();

    final perf = await engine.getPerformanceContext();
    final metrics = {
      'loadMilliseconds': loadSw.elapsedMilliseconds,
      'wallMilliseconds': generateSw.elapsedMilliseconds,
      'backendName': await engine.getBackendName(),
      'targetDecodeTokens': outputTokens,
      'promptTokenCount': promptTokens.length,
      'promptTokenCountWithSpecial': promptTokensWithSpecial.length,
      'promptRoundTripLength': promptRoundTrip.length,
      'backendInitMilliseconds': perf?.loadMs,
      'promptEvalTokens': perf?.promptEvalTokens,
      'evalTokens': perf?.evalTokens,
      'promptEvalMs': perf?.promptEvalMs,
      'evalMs': perf?.evalMs,
      'prefillTokensPerSecond': perf == null || perf.promptEvalMs <= 0
          ? null
          : perf.promptEvalTokens / (perf.promptEvalMs / 1000.0),
      'decodeTokensPerSecond': perf == null || perf.evalMs <= 0
          ? null
          : perf.evalTokens / (perf.evalMs / 1000.0),
    };

    print('RESULT litert_lm_engine ${jsonEncode(metrics)}');
    print('LAST_TEXT ${jsonEncode(buffer.toString())}');
  } finally {
    await engine.dispose();
  }
}
