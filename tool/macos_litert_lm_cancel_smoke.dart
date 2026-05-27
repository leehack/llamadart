import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:llamadart/llamadart.dart';

const _defaultPrompt =
    'Write a detailed numbered essay about on-device language models, '
    'including privacy, latency, offline use, hardware acceleration, and '
    'developer ergonomics.';

Future<void> main(List<String> args) async {
  final modelPath = args.isNotEmpty
      ? args.first
      : '.dart_tool/litert_lm_models/gemma-4-E2B-it.litertlm';
  final backendArg = args.length > 1 ? args[1] : 'cpu';
  final cancelAfterMilliseconds = args.length > 2 ? int.parse(args[2]) : 250;
  final outputTokens = args.length > 3 ? int.parse(args[3]) : 512;
  final timeoutMilliseconds = args.length > 4 ? int.parse(args[4]) : 15000;
  final preferredBackend = backendArg == 'cpu'
      ? GpuBackend.cpu
      : GpuBackend.metal;

  final engine = LlamaEngine(LiteRtLmBackend());
  StreamSubscription<String>? subscription;
  Timer? cancelTimer;
  final done = Completer<void>();
  Object? streamError;
  var chunks = 0;
  var characters = 0;
  var timedOut = false;

  try {
    await engine.loadModel(
      modelPath,
      modelParams: ModelParams(
        contextSize: 4096,
        preferredBackend: preferredBackend,
      ),
    );

    final sw = Stopwatch()..start();
    subscription = engine
        .generate(
          _defaultPrompt,
          params: GenerationParams(maxTokens: outputTokens, seed: 1),
        )
        .listen(
          (chunk) {
            chunks += 1;
            characters += chunk.length;
          },
          onError: (Object error, StackTrace stackTrace) {
            streamError = error;
            if (!done.isCompleted) {
              done.complete();
            }
          },
          onDone: () {
            if (!done.isCompleted) {
              done.complete();
            }
          },
        );

    cancelTimer = Timer(Duration(milliseconds: cancelAfterMilliseconds), () {
      engine.cancelGeneration();
    });

    try {
      await done.future.timeout(Duration(milliseconds: timeoutMilliseconds));
    } on TimeoutException {
      timedOut = true;
      engine.cancelGeneration();
      await subscription.cancel();
    }
    sw.stop();

    final metrics = <String, Object?>{
      'backendName': await engine.getBackendName(),
      'cancelAfterMilliseconds': cancelAfterMilliseconds,
      'targetDecodeTokens': outputTokens,
      'timeoutMilliseconds': timeoutMilliseconds,
      'wallMilliseconds': sw.elapsedMilliseconds,
      'completedBeforeTimeout': !timedOut,
      'chunks': chunks,
      'characters': characters,
      'streamError': streamError?.toString(),
    };
    print('RESULT litert_lm_cancel ${jsonEncode(metrics)}');
    if (timedOut) {
      exitCode = 2;
    }
  } finally {
    cancelTimer?.cancel();
    await subscription?.cancel();
    await engine.dispose();
  }
}
