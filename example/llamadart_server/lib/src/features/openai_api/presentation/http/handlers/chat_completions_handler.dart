import 'package:llamadart/llamadart.dart';
import 'package:relic/relic.dart';

import '../../../../chat_completion/chat_completion.dart';
import '../../../../shared/shared.dart';
import '../support/generation_gate.dart';
import '../support/http_json.dart';
import '../support/openai_error_mapper.dart';
import 'chat_stream_writer.dart';

/// Handles `POST /v1/chat/completions`.
class ChatCompletionsHandler {
  /// Public model ID exposed in API responses.
  final String modelId;

  /// Chat completion use case service.
  final ChatCompletionService chatCompletionService;

  final GenerationGate _generationGate;
  final ChatStreamWriter _streamWriter;

  /// Creates chat-completions endpoint handlers.
  ChatCompletionsHandler({
    required this.modelId,
    required this.chatCompletionService,
    required GenerationGate generationGate,
  }) : _generationGate = generationGate,
       _streamWriter = ChatStreamWriter(
         chatCompletionService: chatCompletionService,
         modelId: modelId,
         generationGate: generationGate,
       );

  /// Handles one chat completion request.
  Future<Response> handle(Request req) async {
    try {
      final request = parseChatCompletionRequest(
        await readJsonObjectBody(req),
        configuredModelId: modelId,
      );

      if (!_generationGate.tryAcquire()) {
        return errorJsonResponse(
          OpenAiHttpException.busy(
            'Another generation is already in progress. Retry shortly.',
          ),
        );
      }

      if (request.stream) {
        return _streamWriter.create(request);
      }

      return _nonStreamingResponse(request);
    } on OpenAiHttpException catch (error) {
      return errorJsonResponse(error);
    } catch (error) {
      return errorJsonResponse(toServerError(error, 'Unexpected server error'));
    }
  }

  Future<Response> _nonStreamingResponse(
    OpenAiChatCompletionRequest request,
  ) async {
    try {
      final responseBody = await chatCompletionService.generate(
        request,
        modelId: modelId,
      );
      return jsonResponse(responseBody);
    } on OpenAiHttpException catch (error) {
      return errorJsonResponse(error);
    } on LlamaException catch (error) {
      return errorJsonResponse(toServerError(error, 'Model generation failed'));
    } catch (error) {
      return errorJsonResponse(toServerError(error, 'Server error'));
    } finally {
      _generationGate.release();
    }
  }
}
