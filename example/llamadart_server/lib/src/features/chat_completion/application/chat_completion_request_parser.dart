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
  final frequencyPenalty = _readPenalty(
    json['frequency_penalty'],
    'frequency_penalty',
    100,
  );
  final presencePenalty = _readPenalty(
    json['presence_penalty'],
    'presence_penalty',
    2,
  );
  final logitBias = _parseLogitBias(json['logit_bias']);
  final seed = readIntField(json['seed'], 'seed');
  final stops = parseStopSequences(json['stop']);
  final topLogprobs = _readTopLogprobs(json['logprobs'], json['top_logprobs']);

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
  params = params.copyWith(
    frequencyPenalty: frequencyPenalty,
    presencePenalty: presencePenalty,
    logitBias: logitBias,
  );
  if (seed != null) {
    params = params.copyWith(seed: seed);
  }
  if (stops.isNotEmpty) {
    params = params.copyWith(stopSequences: stops);
  }
  if (topLogprobs != null) {
    params = params.copyWith(topLogprobs: topLogprobs);
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

int? _readTopLogprobs(Object? logprobsRaw, Object? topLogprobsRaw) {
  final enabled = readBoolField(logprobsRaw, 'logprobs') ?? false;
  final top = readIntField(topLogprobsRaw, 'top_logprobs');
  if (top != null && !enabled) {
    throw OpenAiHttpException.invalidRequest(
      '`top_logprobs` requires `logprobs = true`.',
      param: 'top_logprobs',
    );
  }
  if (!enabled) return null;
  if (top != null && (top < 0 || top > GenerationParams.maxTopLogprobs)) {
    throw OpenAiHttpException.invalidRequest(
      '`top_logprobs` must be between 0 and '
      '${GenerationParams.maxTopLogprobs}.',
      param: 'top_logprobs',
    );
  }
  return top ?? 0;
}

double? _readPenalty(Object? raw, String name, int limit) {
  final value = readDoubleField(raw, name);
  if (value != null && (!value.isFinite || value < -limit || value > limit)) {
    throw OpenAiHttpException.invalidRequest(
      '`$name` must be between -$limit and $limit.',
      param: name,
    );
  }
  return value;
}

Map<int, double>? _parseLogitBias(Object? raw) {
  if (raw == null) return null;
  if (raw is! Map) {
    throw OpenAiHttpException.invalidRequest(
      '`logit_bias` must be an object keyed by token ID.',
      param: 'logit_bias',
    );
  }

  final biases = <int, double>{};
  for (final MapEntry(:key, :value) in raw.entries) {
    final token = key is String ? int.tryParse(key, radix: 10) : null;
    if (token == null || token < 0 || biases.containsKey(token)) {
      throw OpenAiHttpException.invalidRequest(
        '`logit_bias` keys must be distinct non-negative integer token IDs.',
        param: 'logit_bias',
      );
    }
    if (value is! num || !value.isFinite || value < -10000 || value > 10000) {
      throw OpenAiHttpException.invalidRequest(
        '`logit_bias` values must be finite numbers between -10000 and 10000.',
        param: 'logit_bias',
      );
    }
    biases[token] = value.toDouble();
  }
  return biases;
}
