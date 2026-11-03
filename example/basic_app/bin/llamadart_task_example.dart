import 'dart:async';
import 'dart:io';

import 'package:llamadart/llamadart.dart';

/// Streams one chat task; pass a local model path as the first argument.
Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(
      'Usage: dart run bin/llamadart_task_example.dart <model.gguf>',
    );
    exitCode = 64;
    return;
  }
  final engine = await LlamaEngine.load(
    LlamaModel(ModelSource.path(args.first)),
  );
  try {
    final task = engine.createTask([
      const LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'Hello!'),
    ], params: const GenerationParams(maxTokens: 32));
    final events = task.events.listen((chunk) => stdout.write(chunk.text));
    final observed = events.asFuture<void>();
    final interrupt = ProcessSignal.sigint.watch().listen((_) => task.cancel());
    try {
      final completion = await task.done;
      await observed;
      stdout.writeln('\n${completion.state.name}');
      if (completion.error case final error?) {
        stderr.writeln(error);
        exitCode = 1;
      }
    } finally {
      await interrupt.cancel();
      await events.cancel();
    }
  } finally {
    await engine.dispose();
  }
}
