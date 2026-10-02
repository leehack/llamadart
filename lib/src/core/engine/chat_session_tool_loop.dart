import 'dart:async';
import 'dart:convert';

import 'chat_session.dart';
import 'generation_cancellation.dart';
import '../exceptions.dart';
import '../models/chat/chat_message.dart';
import '../models/chat/chat_role.dart';
import '../models/chat/completion.dart';
import '../models/chat/content_part.dart';
import '../models/inference/generation_params.dart';
import '../models/inference/tool_choice.dart';
import '../models/tools/tool_definition.dart';
import '../models/tools/tool_params.dart';

/// Runs a tool call that has no [ToolDefinition.handler], or that names a
/// tool missing from the `tools` list, and returns its result.
///
/// The result may be any JSON-compatible value.
typedef LlamaToolCallCallback =
    FutureOr<Object?> Function(LlamaToolCallContent call);

/// Turns an error thrown while running [call] into the tool result the model
/// sees, or rethrows it to stop the tool loop.
typedef LlamaToolErrorCallback =
    FutureOr<Object?> Function(
      LlamaToolCallContent call,
      Object error,
      StackTrace stackTrace,
    );

/// Why `ChatSession.sendWithTools` stopped.
enum LlamaToolLoopStopReason {
  /// The model replied without calling a tool.
  completed,

  /// The model called tools after `maxRounds` tool rounds had already run.
  /// The calls were not run.
  maxRounds,

  /// A call names a tool with no [ToolDefinition.handler] and no
  /// `onToolCall` was given. No call of that reply was run.
  unhandledToolCalls,

  /// The request did not fit its context budget
  /// ([ChatSession.lastRequestFitContext] is `false`), so the model may not
  /// have seen the whole turn. Its calls were not run.
  contextExceeded,

  /// `LlamaEngine.cancelGeneration` was called while the loop ran.
  cancelled,
}

/// The outcome of `ChatSession.sendWithTools`.
class LlamaToolLoopResult {
  /// The model's last reply. Its [LlamaCompletion.toolCalls] are the calls
  /// of the last reply, whether or not they were run.
  final LlamaCompletion completion;

  /// Why the loop stopped.
  final LlamaToolLoopStopReason stopReason;

  /// The number of tool rounds that ran: replies whose calls were run and
  /// whose results were added to the history.
  final int rounds;

  /// The calls of [completion] that were not run, in call order.
  ///
  /// Empty when [stopReason] is [LlamaToolLoopStopReason.completed]. To
  /// continue, add one `LlamaChatRole.tool` message per call to the session
  /// and call `completeWithTools(const [], ...)`.
  final List<LlamaToolCallContent> pendingToolCalls;

  /// Creates a tool loop result.
  const LlamaToolLoopResult({
    required this.completion,
    required this.stopReason,
    required this.rounds,
    this.pendingToolCalls = const [],
  });

  /// The text of the last reply.
  String get text => completion.text;

  @override
  String toString() =>
      'LlamaToolLoopResult(stopReason: ${stopReason.name}, rounds: $rounds, '
      'pendingToolCalls: ${pendingToolCalls.length}, '
      'completion: $completion)';
}

/// Tool-calling loops for [ChatSession].
extension ChatSessionToolLoopExtension on ChatSession {
  /// Sends [text] as a user message and runs the model's tool calls until it
  /// answers without one.
  ///
  /// This is [completeWithTools] with a single [LlamaTextContent].
  ///
  /// ```dart
  /// final result = await session.sendWithTools(
  ///   'What is the weather in Seoul?',
  ///   tools: [weatherTool],
  /// );
  /// if (result.stopReason == LlamaToolLoopStopReason.completed) {
  ///   print(result.text);
  /// }
  /// ```
  Future<LlamaToolLoopResult> sendWithTools(
    String text, {
    required List<ToolDefinition> tools,
    int maxRounds = 5,
    LlamaToolCallCallback? onToolCall,
    LlamaToolErrorCallback? onToolError,
    GenerationParams? params,
    ToolChoice? toolChoice,
    bool parallelToolCalls = false,
    bool enableThinking = true,
    Map<String, dynamic>? chatTemplateKwargs,
    void Function(LlamaChatMessage message)? onMessageAdded,
  }) {
    return completeWithTools(
      [LlamaTextContent(text)],
      tools: tools,
      maxRounds: maxRounds,
      onToolCall: onToolCall,
      onToolError: onToolError,
      params: params,
      toolChoice: toolChoice,
      parallelToolCalls: parallelToolCalls,
      enableThinking: enableThinking,
      chatTemplateKwargs: chatTemplateKwargs,
      onMessageAdded: onMessageAdded,
    );
  }

  /// Sends [parts] as a user message and runs the model's tool calls until it
  /// answers without one.
  ///
  /// Each round collects a reply with [ChatSession.create]. When the reply
  /// calls tools, the calls run concurrently, and each result is added to
  /// [ChatSession.history], in call order, as a `LlamaChatRole.tool` message
  /// holding a [LlamaToolResultContent] with the call's id and name. The
  /// next round continues the turn without a new user message. Empty [parts]
  /// continue the current turn, for example after the caller added results
  /// for [LlamaToolLoopResult.pendingToolCalls].
  ///
  /// A call runs the [ToolDefinition.handler] of the tool it names. A call
  /// to a tool without a handler, or to a name missing from [tools], runs
  /// [onToolCall] instead. Without [onToolCall], a reply calling a tool that
  /// has no handler stops the loop before any of its calls runs, with
  /// [LlamaToolLoopStopReason.unhandledToolCalls], and a call to an unknown
  /// name fails as described below.
  ///
  /// A call fails when its tool throws, when it names an unknown tool, or
  /// when its arguments are not a JSON object; the last two fail with a
  /// [LlamaArgumentException]. [onToolError] turns the error into the tool
  /// result the model sees, so the model can recover. By default that
  /// result is `{'error': message}`. Rethrow from [onToolError] to stop the
  /// loop: this call then fails with that error once every call of the
  /// round has finished, and no result of that round is added, so
  /// [ChatSession.history] ends with the reply's calls.
  ///
  /// The loop stops with a [LlamaToolLoopResult] when the model answers
  /// without a tool call, when it calls tools after [maxRounds] tool rounds,
  /// when a request did not fit its context budget (calls proposed from a
  /// trimmed prompt are not run), or when `LlamaEngine.cancelGeneration` is
  /// called. A cancel does not interrupt running tools: their results are
  /// added before the loop stops. [maxRounds] must not be negative, or this
  /// throws [LlamaArgumentException]; `0` returns the first reply's calls
  /// unrun.
  ///
  /// [toolChoice] applies to the first request only; later rounds use
  /// [ToolChoice.auto] so the model can answer. The other arguments have the
  /// same meaning as in [ChatSession.create], and [onMessageAdded] also
  /// reports each tool result message. An error from [ChatSession.create]
  /// fails this call, with that round's history handled as there. Use
  /// [ChatSession.create] directly to stream replies as they are generated.
  Future<LlamaToolLoopResult> completeWithTools(
    List<LlamaContentPart> parts, {
    required List<ToolDefinition> tools,
    int maxRounds = 5,
    LlamaToolCallCallback? onToolCall,
    LlamaToolErrorCallback? onToolError,
    GenerationParams? params,
    ToolChoice? toolChoice,
    bool parallelToolCalls = false,
    bool enableThinking = true,
    Map<String, dynamic>? chatTemplateKwargs,
    void Function(LlamaChatMessage message)? onMessageAdded,
  }) {
    if (maxRounds < 0) {
      return Future.error(
        LlamaArgumentException(
          'maxRounds must not be negative.',
          name: 'maxRounds',
          invalidValue: maxRounds,
        ),
      );
    }
    final cancellation = GenerationCancellation.forEngine(engine);
    return cancellation.request<LlamaToolLoopResult>((request) async* {
      var rounds = 0;
      var nextParts = parts;
      while (true) {
        final reply = await cancellation
            .inherit(
              request,
              () => create(
                nextParts,
                params: params,
                tools: tools,
                toolChoice: rounds == 0 ? toolChoice : null,
                parallelToolCalls: parallelToolCalls,
                enableThinking: enableThinking,
                chatTemplateKwargs: chatTemplateKwargs,
                onMessageAdded: onMessageAdded,
              ),
            )
            .collect();
        LlamaToolLoopResult stop(LlamaToolLoopStopReason reason) =>
            LlamaToolLoopResult(
              completion: reply,
              stopReason: reason,
              rounds: rounds,
              pendingToolCalls: reply.toolCalls,
            );

        if (request.isCancelled()) {
          yield stop(LlamaToolLoopStopReason.cancelled);
          return;
        }
        if (reply.toolCalls.isEmpty) {
          yield stop(LlamaToolLoopStopReason.completed);
          return;
        }
        if (!lastRequestFitContext) {
          yield stop(LlamaToolLoopStopReason.contextExceeded);
          return;
        }
        if (rounds >= maxRounds) {
          yield stop(LlamaToolLoopStopReason.maxRounds);
          return;
        }
        final runs = [
          for (final call in reply.toolCalls) _toolRun(call, tools, onToolCall),
        ];
        if (runs.contains(null)) {
          yield stop(LlamaToolLoopStopReason.unhandledToolCalls);
          return;
        }

        final results = await Future.wait([
          for (final (index, call) in reply.toolCalls.indexed)
            _runTool(call, runs[index]!, onToolError),
        ]);
        for (final (index, call) in reply.toolCalls.indexed) {
          final message = LlamaChatMessage.withContent(
            role: LlamaChatRole.tool,
            content: [
              LlamaToolResultContent(
                id: call.id,
                name: call.name,
                result: results[index],
              ),
            ],
          );
          addMessage(message);
          onMessageAdded?.call(message);
        }
        rounds += 1;

        if (request.isCancelled()) {
          yield LlamaToolLoopResult(
            completion: reply,
            stopReason: LlamaToolLoopStopReason.cancelled,
            rounds: rounds,
          );
          return;
        }
        nextParts = const [];
      }
    }).single;
  }
}

/// Returns how to run [call], or `null` when the app must run it itself.
FutureOr<Object?> Function()? _toolRun(
  LlamaToolCallContent call,
  List<ToolDefinition> tools,
  LlamaToolCallCallback? onToolCall,
) {
  final tool = tools.where((tool) => tool.name == call.name).firstOrNull;
  final handler = tool?.handler;
  if (handler != null) {
    return () => handler(ToolParams(_argumentsOf(call)));
  }
  if (onToolCall != null) return () => onToolCall(call);
  if (tool != null) return null;
  return () => throw LlamaArgumentException(
    'The model called the unknown tool "${call.name}".',
    name: 'name',
    invalidValue: call.name,
  );
}

/// The arguments of [call]; throws [LlamaArgumentException] when the model
/// generated something other than a JSON object.
Map<String, dynamic> _argumentsOf(LlamaToolCallContent call) {
  final raw = call.rawJson.trim();
  if (call.arguments.isNotEmpty || raw.isEmpty) return call.arguments;
  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    decoded = null;
  }
  if (decoded is Map<String, dynamic>) return decoded;
  throw LlamaArgumentException(
    'The arguments of the call to "${call.name}" are not a JSON object.',
    name: 'arguments',
    invalidValue: call.rawJson,
  );
}

Future<Object?> _runTool(
  LlamaToolCallContent call,
  FutureOr<Object?> Function() run,
  LlamaToolErrorCallback? onToolError,
) async {
  try {
    return await run();
  } catch (error, stackTrace) {
    if (onToolError != null) return onToolError(call, error, stackTrace);
    return {'error': error is LlamaException ? error.message : '$error'};
  }
}
