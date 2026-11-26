import 'dart:io';

import 'package:genkit/genkit.dart';
import 'package:genkit/plugin.dart' as api;
import 'package:genkit_llamadart/genkit_llamadart.dart';
import 'package:schemantic/schemantic.dart';

import 'support/model_downloads.dart';

Future<void> main(List<String> args) async {
  if (args.length != 1 && args.length != 3) {
    throw ArgumentError(
      'Supply IMAGE, or MODEL_SOURCE PROJECTOR_SOURCE IMAGE (paths, hf:// or HTTPS).',
    );
  }
  final prepared = await llamaDart.prepareModel(
    name: 'vision-tools',
    source: ModelSource.parse(
      args.length == 3
          ? args[0]
          : 'hf://Qwen/Qwen3-VL-2B-Instruct-GGUF/Qwen3VL-2B-Instruct-Q4_K_M.gguf?revision=52d6c8ffea26cc873ac5ad116f8631268d7eb503',
    ),
    mmprojSource: ModelSource.parse(
      args.length == 3
          ? args[1]
          : 'hf://Qwen/Qwen3-VL-2B-Instruct-GGUF/mmproj-Qwen3VL-2B-Instruct-F16.gguf?revision=52d6c8ffea26cc873ac5ad116f8631268d7eb503',
    ),
    downloadManager: exampleDownloads,
    modelParams: const ModelParams(
      contextSize: 4096,
      device: ComputeDevice.cpu,
    ),
    supportsEmbeddings: false,
  );
  final ai = prepared.createGenkit(isDevEnv: false);
  var photos = 0;
  final takePhoto = ai.defineTool<Map<String, dynamic>, String>(
    name: 'take_photo',
    description: 'Takes a photo with the camera and returns it.',
    inputSchema: SchemanticType.from(
      jsonSchema: {'type': 'object'},
      parse: (value) => (value as Map).cast<String, dynamic>(),
    ),
    outputSchema: SchemanticType.string(),
    fn: (_, _) async {
      photos++;
      return ToolResult.response(
        'Photo taken.',
        parts: [
          MediaPart(media: Media(url: File(args.last).absolute.uri.toString())),
        ],
      );
    },
  );
  final answer = ai.defineGenerateMiddleware<void>(
    name: 'answerFromPhoto',
    create: (_, _) => _AnswerFromToolResult(),
  );
  try {
    final response = await ai.generate(
      system:
          'Call take_photo once. When the photo comes back, describe it in one '
          'sentence and do not call a tool again.',
      prompt: 'Take a photo and describe it.',
      tools: [takePhoto],
      toolChoice: ToolChoice.required,
      maxTurns: 3,
      use: [answer()],
      config: const LlamaDartGenerationConfig(
        temperature: 0,
        penalty: 1,
        maxTokens: 128,
      ),
    );
    if (response.finishReason != FinishReason.stop || photos != 1) {
      throw response.cause ?? StateError('The photo tool loop did not finish.');
    }
    print(response.text);
  } finally {
    try {
      await prepared.dispose();
    } finally {
      await ai.shutdown();
    }
  }
}

// Offers no tool once the photo is back, so the model answers from it.
class _AnswerFromToolResult extends GenerateMiddleware {
  @override
  Future<ModelResponse> model(
    ModelRequest request,
    api.ActionFnArg<ModelResponseChunk, ModelRequest, void> ctx,
    Future<ModelResponse> Function(
      ModelRequest,
      api.ActionFnArg<ModelResponseChunk, ModelRequest, void>,
    )
    next,
  ) {
    if (request.messages.any((m) => m.role == Role.tool)) {
      request = ModelRequest(
        messages: request.messages,
        tools: request.tools,
        toolChoice: ToolChoice.none,
        config: request.config,
        output: request.output,
      );
    }
    return next(request, ctx);
  }
}
