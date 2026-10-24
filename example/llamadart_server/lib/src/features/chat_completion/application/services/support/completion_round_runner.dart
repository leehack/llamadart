import 'package:llamadart/llamadart.dart';

import '../../../../server_engine/domain/chat_completion_engine_port.dart';
import '../../openai_response_mapper.dart';

/// Executes one completion round and reports its usage.
class CompletionRoundRunner {
  final ChatCompletionEnginePort _engine;

  /// Creates a round runner bound to one engine.
  const CompletionRoundRunner(this._engine);

  /// Runs one completion round.
  Future<CompletionRoundResult> run({
    required List<LlamaChatMessage> messages,
    required GenerationParams params,
    required List<ToolDefinition>? tools,
    required ToolChoice? toolChoice,
    required bool parallelToolCalls,
    required bool enableThinking,
  }) async {
    final accumulator = OpenAiChatCompletionAccumulator();
    var completionId = 'chatcmpl-${DateTime.now().millisecondsSinceEpoch}';
    var created = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    LlamaGenerationUsage? usage;

    await for (final chunk in _engine.create(
      messages,
      params: params,
      tools: tools,
      toolChoice: toolChoice,
      parallelToolCalls: parallelToolCalls,
      enableThinking: enableThinking,
    )) {
      completionId = chunk.id;
      created = chunk.created;
      usage = chunk.usage ?? usage;
      accumulator.addChunk(chunk);
    }

    final promptTokens =
        usage?.promptTokens ??
        await _templatePromptTokens(
          messages,
          tools: tools,
          toolChoice: toolChoice,
          parallelToolCalls: parallelToolCalls,
          enableThinking: enableThinking,
        );
    final completionTokens =
        usage?.completionTokens ??
        await _completionTokens(_buildCompletionTokenText(accumulator));

    return CompletionRoundResult(
      accumulator: accumulator,
      completionId: completionId,
      created: created,
      promptTokens: promptTokens,
      completionTokens: completionTokens,
    );
  }

  // Backends without per-request usage fall back to counting tokens of the
  // rendered prompt and the generated text.
  Future<int> _templatePromptTokens(
    List<LlamaChatMessage> messages, {
    required List<ToolDefinition>? tools,
    required ToolChoice? toolChoice,
    required bool parallelToolCalls,
    required bool enableThinking,
  }) async {
    try {
      final templateResult = await _engine.chatTemplate(
        messages,
        tools: tools,
        toolChoice: toolChoice ?? ToolChoice.auto,
        parallelToolCalls: parallelToolCalls,
        enableThinking: enableThinking,
      );
      return templateResult.tokenCount ?? 0;
    } catch (_) {
      return 0;
    }
  }

  Future<int> _completionTokens(String text) async =>
      text.isEmpty ? 0 : await _engine.getTokenCount(text);

  String _buildCompletionTokenText(
    OpenAiChatCompletionAccumulator accumulator,
  ) {
    final parts = <String>[];

    final reasoning = accumulator.reasoningContent;
    if (reasoning.isNotEmpty) {
      parts.add(reasoning);
    }

    final content = accumulator.content;
    if (content.isNotEmpty) {
      parts.add(content);
    }

    return parts.join('\n');
  }
}

/// Result produced by a single completion round.
class CompletionRoundResult {
  /// Accumulated round output.
  final OpenAiChatCompletionAccumulator accumulator;

  /// Completion id seen in streamed chunks.
  final String completionId;

  /// Unix timestamp for the completion.
  final int created;

  /// Prompt token count for this round.
  final int promptTokens;

  /// Completion token count for this round.
  final int completionTokens;

  /// Creates an immutable round result.
  const CompletionRoundResult({
    required this.accumulator,
    required this.completionId,
    required this.created,
    required this.promptTokens,
    required this.completionTokens,
  });
}
