import 'dart:async';
import 'dart:io';

import 'package:llamadart/llamadart.dart';

/// Runs a local Laya encoder and head with cooperative Ctrl-C cancellation.
Future<void> main(List<String> arguments) async {
  if (arguments.length != 2) {
    stderr.writeln(
      'Usage: dart run bin/llamadart_decision_task_example.dart <encoder.gguf> <head.safetensors>',
    );
    exitCode = 64;
    return;
  }
  final DecisionEngine decisions = await DecisionEngine.load(
    DecisionModel(
      encoder: ModelSource.path(arguments[0]),
      head: ModelSource.path(arguments[1]),
    ),
    params: const DecisionModelParams(device: ComputeDevice.cpu, threads: 2),
  );
  StreamSubscription<ProcessSignal>? interrupts;
  try {
    final DecisionTask<DecisionResult> task = decisions.systemOneTask(
      state: 'We were billed twice. Please refund the duplicate.',
      questions: {'refund': DecisionQuestion.noul('Is a refund requested?')},
    );
    interrupts = ProcessSignal.sigint.watch().listen((_) => task.cancel());
    final DecisionCompletion<DecisionResult> completion = await task.done;
    switch (completion.state) {
      case DecisionCompletionState.completed:
        print(
          'refund probability: ${completion.result!.nouls['refund']!.noul}',
        );
      case DecisionCompletionState.cancelled:
        print('Cancelled; underlying work has finished.');
      case DecisionCompletionState.failed:
        stderr.writeln(completion.error);
        exitCode = 1;
    }
  } finally {
    await interrupts?.cancel();
    await decisions.dispose();
  }
}
