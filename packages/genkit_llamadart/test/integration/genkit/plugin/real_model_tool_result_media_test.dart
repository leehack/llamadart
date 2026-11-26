@Tags(['real-model', 'tool-result-media-model'])
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:genkit/genkit.dart';
import 'package:genkit/plugin.dart' as api;
import 'package:genkit_llamadart/genkit_llamadart.dart';
import 'package:image/image.dart' as image;
import 'package:schemantic/schemantic.dart';
import 'package:test/test.dart';

/// Qualifies image tool results on a real vision model.
///
/// Set LLAMADART_TOOL_MEDIA_MODEL and LLAMADART_TOOL_MEDIA_MMPROJ to a
/// Qwen3-VL GGUF and its projector, the variables of llamadart's
/// `tool-result-image-smoke` scenario. LLAMADART_TOOL_MEDIA_CHAT_TEMPLATE
/// optionally names a template file used for a closest-family model.
void main() {
  final env = Platform.environment;
  final model = env['LLAMADART_TOOL_MEDIA_MODEL'];
  final mmproj = env['LLAMADART_TOOL_MEDIA_MMPROJ'];
  final templatePath = env['LLAMADART_TOOL_MEDIA_CHAT_TEMPLATE'];

  const colors = {'red': (220, 20, 20), 'blue': (20, 40, 220)};
  for (final entry in colors.entries) {
    test(
      'the model reads a ${entry.key} photo returned by a Genkit tool',
      () async {
        if (model == null || mmproj == null) {
          markTestSkipped(
            'Set LLAMADART_TOOL_MEDIA_MODEL and LLAMADART_TOOL_MEDIA_MMPROJ.',
          );
          return;
        }
        final plugin = LlamaDartPlugin(
          models: [
            LlamaModelDefinition(
              name: 'vision',
              modelPath: model,
              mmprojPath: mmproj,
              modelParams: ModelParams(
                contextSize: 4096,
                device: ComputeDevice.cpu,
                numberOfThreads: 2,
                numberOfThreadsBatch: 2,
                chatTemplate: templatePath == null
                    ? null
                    : File(templatePath).readAsStringSync(),
              ),
              supportsEmbeddings: false,
            ),
          ],
        );
        final ai = Genkit(plugins: [plugin], isDevEnv: false);
        addTearDown(() async {
          await plugin.dispose();
          await ai.shutdown();
        });
        final (r, g, b) = entry.value;
        final photo = base64Encode(image.encodePng(_solid(r, g, b)));
        var calls = 0;
        final camera = ai.defineTool<Map<String, dynamic>, String>(
          name: 'take_photo',
          description: 'Take a photo with the camera.',
          inputSchema: SchemanticType.from(
            jsonSchema: {'type': 'object'},
            parse: (v) => (v as Map).cast<String, dynamic>(),
          ),
          outputSchema: SchemanticType.string(),
          fn: (_, _) async {
            calls++;
            return ToolResult.response(
              'ok',
              parts: [
                MediaPart(
                  media: Media(
                    url: 'data:image/png;base64,$photo',
                    contentType: 'image/png',
                  ),
                ),
              ],
            );
          },
        );
        final finish = ai.defineGenerateMiddleware<void>(
          name: 'answerFromPhoto',
          create: (_, _) => _AnswerFromToolResult(),
        );
        final result = await ai.generate(
          model: llamaDart.model('vision'),
          system:
              'Call take_photo once. When the photo comes back, answer with its '
              'main color in one word and do not call a tool again.',
          prompt: 'Take a photo and tell me its main color.',
          tools: [camera],
          toolChoice: ToolChoice.required,
          maxTurns: 3,
          use: [finish()],
          config: const LlamaDartGenerationConfig(
            temperature: 0,
            penalty: 1,
            seed: 1,
            maxTokens: 96,
          ),
        );
        stdout.writeln(
          jsonEncode({
            'case': entry.key,
            'text': result.text,
            'finish': '${result.finishReason}',
            'calls': calls,
          }),
        );
        expect(
          result.finishReason,
          FinishReason.stop,
          reason: '${result.error}',
        );
        expect(calls, 1);
        expect(result.text.toLowerCase(), contains(entry.key));
      },
      timeout: const Timeout(Duration(minutes: 10)),
    );
  }
}

image.Image _solid(int r, int g, int b) {
  final photo = image.Image(width: 64, height: 64);
  for (final pixel in photo) {
    pixel.setRgb(r, g, b);
  }
  return photo;
}

// The model answers from the tool turn instead of calling the tool again.
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
