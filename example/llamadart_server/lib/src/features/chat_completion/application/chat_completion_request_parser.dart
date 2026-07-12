import 'package:llamadart/llamadart.dart';

import '../../shared/openai_http_exception.dart';
import '../domain/openai_chat_completion_request.dart';
import 'parser_support/chat_completion_field_readers.dart';
import 'parser_support/chat_completion_message_parser.dart';
import 'parser_support/chat_completion_tool_parser.dart';

const int _maxThinkingBudgetTokens = 0x7fffffff;

const GenerationParams _nonThinkingGenerationParams = GenerationParams(
  temp: 0.7,
  topK: 20,
  topP: 0.8,
  minP: 0.0,
  penalty: 1.0,
);

const GenerationParams _thinkingGenerationParams = GenerationParams(
  temp: 1.0,
  topK: 20,
  topP: 0.95,
  minP: 0.0,
  penalty: 1.0,
);

/// Parses and validates an OpenAI chat completion request body.
OpenAiChatCompletionRequest parseChatCompletionRequest(
  Map<String, dynamic> json, {
  required String configuredModelId,
}) {
  final model = json['model'];
  if (model is! String || model.trim().isEmpty) {
    throw OpenAiHttpException.invalidRequest(
      'Missing required `model` field.',
      param: 'model',
    );
  }

  if (model != configuredModelId) {
    throw OpenAiHttpException.modelNotFound(model);
  }

  final n = readIntField(json['n'], 'n');
  if (n != null && n != 1) {
    throw OpenAiHttpException.invalidRequest(
      'Only `n = 1` is supported in this example server.',
      param: 'n',
    );
  }

  final stream = readBoolField(json['stream'], 'stream') ?? false;
  final enableThinking =
      readBoolField(json['enable_thinking'], 'enable_thinking') ?? false;
  final parallelToolCalls =
      readBoolField(json['parallel_tool_calls'], 'parallel_tool_calls') ??
      false;

  final messagesRaw = json['messages'];
  if (messagesRaw is! List || messagesRaw.isEmpty) {
    throw OpenAiHttpException.invalidRequest(
      '`messages` must be a non-empty array.',
      param: 'messages',
    );
  }

  final messages = parseChatMessages(messagesRaw);

  final parsedTools = parseToolDefinitions(json['tools']);
  final tools = restrictToolsForToolChoice(json['tool_choice'], parsedTools);
  final toolChoice = parseToolChoice(json['tool_choice'], parsedTools);

  if (toolChoice == ToolChoice.required && (tools == null || tools.isEmpty)) {
    throw OpenAiHttpException.invalidRequest(
      '`tool_choice = "required"` requires `tools` to be provided.',
      param: 'tool_choice',
    );
  }

  final maxTokens = readIntField(json['max_tokens'], 'max_tokens');
  final thinkingBudgetTokens = readIntField(
    json['thinking_budget_tokens'],
    'thinking_budget_tokens',
  );
  final temperature = readDoubleField(json['temperature'], 'temperature');
  final topP = readDoubleField(json['top_p'], 'top_p');
  final seed = readIntField(json['seed'], 'seed');
  final stops = parseStopSequences(json['stop']);

  if (thinkingBudgetTokens != null && !enableThinking) {
    throw OpenAiHttpException.invalidRequest(
      '`thinking_budget_tokens` requires `enable_thinking = true`.',
      param: 'thinking_budget_tokens',
    );
  }
  if (thinkingBudgetTokens != null && thinkingBudgetTokens < 0) {
    throw OpenAiHttpException.invalidRequest(
      '`thinking_budget_tokens` must be greater than or equal to zero.',
      param: 'thinking_budget_tokens',
    );
  }
  if (thinkingBudgetTokens != null &&
      thinkingBudgetTokens > _maxThinkingBudgetTokens) {
    throw OpenAiHttpException.invalidRequest(
      '`thinking_budget_tokens` must be less than or equal to '
      '$_maxThinkingBudgetTokens.',
      param: 'thinking_budget_tokens',
    );
  }

  var params = enableThinking
      ? _thinkingGenerationParams
      : _nonThinkingGenerationParams;
  if (maxTokens != null) {
    params = params.copyWith(maxTokens: maxTokens);
  }
  if (thinkingBudgetTokens != null) {
    params = params.copyWith(
      thinkingBudget: ThinkingBudget(maxTokens: thinkingBudgetTokens),
    );
  }
  if (temperature != null) {
    params = params.copyWith(temp: temperature);
  }
  if (topP != null) {
    params = params.copyWith(topP: topP);
  }
  if (seed != null) {
    params = params.copyWith(seed: seed);
  }
  if (stops.isNotEmpty) {
    params = params.copyWith(stopSequences: stops);
  }

  return OpenAiChatCompletionRequest(
    model: model,
    messages: messages,
    params: params,
    stream: stream,
    enableThinking: enableThinking,
    parallelToolCalls: parallelToolCalls,
    tools: tools,
    toolChoice: toolChoice,
  );
}
