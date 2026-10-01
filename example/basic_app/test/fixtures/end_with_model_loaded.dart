import 'dart:io';

import 'package:llamadart/llamadart.dart';

/// Loads a model and ends without disposing it, as a program that forgets to,
/// or dies of an error, does.
///
/// Usage:
/// `dart run test/fixtures/end_with_model_loaded.dart RUNTIME ENDING MODEL`,
/// where RUNTIME is `llama` or `image` and ENDING is `return` or `throw`.
Future<void> main(List<String> args) async {
  final [runtime, ending, model] = args;
  if (runtime == 'image') {
    await ImageGenerationEngine.load(ImageGenerationModel.sdxs(model));
  } else {
    await LlamaEngine(LlamaBackend()).loadModel(model);
  }
  stdout.writeln('loaded');
  if (ending == 'throw') {
    throw StateError('Ending with the model loaded.');
  }
}
