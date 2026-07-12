import '../../server_engine/domain/chat_completion_engine_port.dart';
import '../domain/openai_chat_completion_request.dart';
import 'openai_response_mapper.dart';
import 'services/support/completion_round_runner.dart';

/// Use case service for chat completion generation.
class ChatCompletionService {
  /// Engine used for template + completion generation.
  final ChatCompletionEnginePort engine;

  /// Creates a chat completion use case service.
  ChatCompletionService({required this.engine})
    : _roundRunner = CompletionRoundRunner(engine);

  final CompletionRoundRunner _roundRunner;

  /// Generates a non-streaming OpenAI-compatible response body.
  Future<Map<String, dynamic>> generate(
    OpenAiChatCompletionRequest request, {
    required String modelId,
  }) async {
    final round = await _roundRunner.run(
      messages: request.messages,
      params: request.params,
      tools: request.tools,
      toolChoice: request.toolChoice,
      parallelToolCalls: request.parallelToolCalls,
      enableThinking: request.enableThinking,
    );

    return round.accumulator.toResponseJson(
      id: round.completionId,
      created: round.created,
      model: modelId,
      promptTokens: round.promptTokens,
      completionTokens: round.completionTokens,
    );
  }

  /// Generates streaming OpenAI-compatible chunk payloads.
  Stream<Map<String, dynamic>> stream(
    OpenAiChatCompletionRequest request, {
    required String modelId,
  }) async* {
    var emittedRole = false;

    await for (final chunk in engine.create(
      request.messages,
      params: request.params,
      tools: request.tools,
      toolChoice: request.toolChoice,
      parallelToolCalls: request.parallelToolCalls,
      enableThinking: request.enableThinking,
    )) {
      final payload = toOpenAiChatCompletionChunk(
        chunk,
        model: modelId,
        includeRole: !emittedRole,
      );
      emittedRole = true;
      yield payload;
    }
  }
}
