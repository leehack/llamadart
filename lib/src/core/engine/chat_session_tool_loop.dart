import 'dart:async';
import 'dart:convert';

import '../../backends/backend.dart';
import 'chat_session.dart';
import 'generation_cancellation.dart';
import '../exceptions.dart';
import '../models/chat/chat_message.dart';
import '../models/chat/chat_role.dart';
import '../models/chat/completion.dart';
import '../models/chat/completion_chunk.dart';
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
///
/// Without this callback the result is `{'error': message}`, where message
/// is the exception's text. That text then reaches the prompt and
/// `ChatSession.history`; return a redacted result here when an error can
/// carry secrets such as tokens, signed URLs or file paths.
typedef LlamaToolErrorCallback =
    FutureOr<Object?> Function(
      LlamaToolCallContent call,
      Object error,
      StackTrace stackTrace,
    );

/// Why `ChatSession.sendWithTools` stopped.
///
/// Only [completed], [unhandledToolCalls] and a [cancelled] stop that kept a
/// partial answer leave the turn in `ChatSession.history`. Every other stop
/// rolls the turn back; see [LlamaToolLoopResult.rolledBack].
enum LlamaToolLoopStopReason {
  /// The model replied without calling a tool. The turn stays in the
  /// history.
  completed,

  /// The model called tools after `maxRounds` tool rounds had already run.
  /// The calls were not run, and the turn was rolled back.
  maxRounds,

  /// A call names a tool with no [ToolDefinition.handler] and no
  /// `onToolCall` was given. No call of that reply was run. The turn stays
  /// in the history, ending with the reply's calls, for the app to answer.
  unhandledToolCalls,

  /// The request did not fit its context budget
  /// ([ChatSession.lastRequestFitContext] is `false`), so the model may not
  /// have seen the whole turn. Its calls were not run, and the turn was
  /// rolled back.
  contextExceeded,

  /// `LlamaEngine.cancelGeneration` was called while the loop ran. A reply
  /// without tool calls stays in the history as the turn's answer, even an
  /// empty one; otherwise the turn was rolled back.
  ///
  /// Which of the two a cancel near the start of a reply gives depends on
  /// its timing, the backend, the chat template and its parser: an empty
  /// reply that parses stays as an empty answer. Check
  /// [LlamaToolLoopResult.rolledBack].
  cancelled,

  /// The reply was cut off ([LlamaFinishReason.length]): it reached
  /// `GenerationParams.maxTokens` or filled the context before the model
  /// ended it. Its text may be an unfinished tool call or thinking rather
  /// than an answer, so its calls were not run and the turn was rolled back.
  /// [LlamaToolLoopResult.completion] keeps the partial reply; raise
  /// `maxTokens` and send the turn again.
  truncated,
}

/// The outcome of `ChatSession.sendWithTools`.
class LlamaToolLoopResult {
  /// The model's last reply. Its [LlamaCompletion.toolCalls] are the calls
  /// of the last reply, whether or not they were run.
  final LlamaCompletion completion;

  /// Why the loop stopped.
  final LlamaToolLoopStopReason stopReason;

  /// The number of tool rounds that ran: replies whose calls were run and
  /// whose results were added to the turn.
  final int rounds;

  /// The calls of [completion] that were not run, in call order.
  ///
  /// Empty when [stopReason] is [LlamaToolLoopStopReason.completed]. After
  /// [LlamaToolLoopStopReason.unhandledToolCalls], answer each call with a
  /// `LlamaChatRole.tool` message through `ChatSession.addMessage`, then call
  /// `completeWithTools(const [], ...)`.
  final List<LlamaToolCallContent> pendingToolCalls;

  /// The messages of the turn, in order: its user message, each reply and
  /// each tool result, including those of an open turn that
  /// `completeWithTools(const [], ...)` continued.
  ///
  /// When [rolledBack] is `true`, none of them is in the history any more,
  /// but tools that ran keep their effects and their results are here.
  final List<LlamaChatMessage> messages;

  /// Whether the turn was removed from `ChatSession.history`.
  ///
  /// To resume a rolled-back turn, add [messages] back with
  /// `ChatSession.addMessage`, answer [pendingToolCalls], and call
  /// `completeWithTools(const [], ...)`.
  final bool rolledBack;

  /// Creates a tool loop result.
  const LlamaToolLoopResult({
    required this.completion,
    required this.stopReason,
    required this.rounds,
    this.pendingToolCalls = const [],
    this.messages = const [],
    this.rolledBack = false,
  });

  /// The text of the last reply.
  String get text => completion.text;

  @override
  String toString() =>
      'LlamaToolLoopResult(stopReason: ${stopReason.name}, rounds: $rounds, '
      'pendingToolCalls: ${pendingToolCalls.length}, '
      'rolledBack: $rolledBack, '
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
  /// result is `{'error': message}`, which puts the exception's text into
  /// the prompt and [ChatSession.history]; use [onToolError] to redact it.
  /// Rethrow from [onToolError] to stop the loop: this call then fails with
  /// that error once every call of the round has finished.
  ///
  /// The loop stops with a [LlamaToolLoopResult] when the model answers
  /// without a tool call, when it calls tools after [maxRounds] tool rounds,
  /// when a request did not fit its context budget (calls proposed from a
  /// trimmed prompt are not run), when a reply is cut off at
  /// `GenerationParams.maxTokens` or the end of the context, or when
  /// `LlamaEngine.cancelGeneration` is called. A cancel does not interrupt running tools. [maxRounds] must not
  /// be negative, or this throws [LlamaArgumentException]; `0` returns the
  /// first reply's calls unrun.
  ///
  /// After every stop, [ChatSession.history] ends with a reply without tool
  /// calls, so a new user turn can follow, except after
  /// [LlamaToolLoopStopReason.unhandledToolCalls], where it ends with the
  /// calls for the app to answer: add a tool message per call, then call
  /// `completeWithTools(const [], ...)`. Templates such as Ministral 3's
  /// reject a user turn that follows unanswered calls or tool results. So
  /// the other stops that end without an answer (`maxRounds`,
  /// `contextExceeded`, `truncated`, a cancel that left no reply without
  /// tool calls) and
  /// any error this call throws roll the whole turn back, from its user
  /// message on. A cancel during a reply without tool calls keeps that reply
  /// as the answer, which can be empty when the cancel came before its first
  /// token; whether such a cancel keeps an empty answer or rolls back
  /// depends on timing, backend, template and parser, so check
  /// [LlamaToolLoopResult.rolledBack].
  /// For empty [parts] that is the open turn being continued, including the
  /// messages added before this call, such as the app's tool results.
  /// Messages that other callers added meanwhile stay. Older turns that
  /// context trimming dropped stay dropped, as after [ChatSession.create].
  /// [LlamaToolLoopResult.rolledBack] reports a rollback,
  /// [LlamaToolLoopResult.messages] keeps the turn, and [onMessageAdded] has
  /// already reported the messages this call added.
  ///
  /// Tool results are added with [ChatSession.addMessage]. A rollback edits
  /// the history without calling [ChatSession.addMessage] or
  /// [ChatSession.reset], so a subclass that mirrors the history should use
  /// [LlamaToolLoopResult.rolledBack]. A class that implements
  /// [ChatSession] without extending it is rolled back by calling
  /// [ChatSession.reset] and adding the remaining messages again.
  ///
  /// A cancel that a backend reports as a stream error, as WebGPU does,
  /// also stops the loop with [LlamaToolLoopStopReason.cancelled]. An error
  /// thrown by [onMessageAdded], or one raised before the cancel, still
  /// fails this call.
  ///
  /// To start a new chat while the loop runs, call
  /// `LlamaEngine.cancelGeneration`, await this call, then call
  /// [ChatSession.reset]: a reset while a reply is generating can leave that
  /// reply in the new chat
  /// ([#888](https://github.com/leehack/llamadart/issues/888)).
  ///
  /// [toolChoice] applies to the first request only; later rounds use
  /// [ToolChoice.auto] so the model can answer. The other arguments have the
  /// same meaning as in [ChatSession.create], and [onMessageAdded] also
  /// reports each tool result message. Use [ChatSession.create] directly to
  /// stream replies as they are generated.
  ///
  /// Throws [LlamaUnsupportedException] before changing history or generating
  /// when the backend declares that it cannot reliably report generation limits.
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
    final backend = engine.backend;
    if (backend is BackendGenerationLimitSupport) {
      final reason = (backend as BackendGenerationLimitSupport)
          .generationLimitUnsupportedReason;
      if (reason != null) {
        return Future.error(
          LlamaUnsupportedException(
            'Automatic tool loops require reliable generation-limit reporting. '
            '$reason Use a backend/runtime that reports why generation stopped.',
          ),
        );
      }
    }
    final cancellation = GenerationCancellation.forEngine(engine);
    return cancellation.request<LlamaToolLoopResult>((request) async* {
      final turn = _ToolLoopTurn(
        this,
        onMessageAdded,
        continuesTurn: parts.isEmpty,
      );
      try {
        var rounds = 0;
        var nextParts = parts;
        while (true) {
          final accumulator = LlamaCompletionAccumulator();
          bool? cancelledAtReply;
          try {
            final stream = cancellation.inherit(
              request,
              () => create(
                nextParts,
                params: params,
                tools: tools,
                toolChoice: rounds == 0 ? toolChoice : null,
                parallelToolCalls: parallelToolCalls,
                enableThinking: enableThinking,
                chatTemplateKwargs: chatTemplateKwargs,
                onMessageAdded: (message) {
                  if (message.role == LlamaChatRole.assistant) {
                    cancelledAtReply = request.isCancelled();
                  }
                  turn.report(message);
                },
              ),
            );
            await for (final chunk in stream) {
              accumulator.add(chunk);
            }
          } catch (error) {
            // Some backends, such as WebGPU, end a cancelled generation with
            // an error instead of closing the stream. `create` adds a partial
            // reply, and runs the app's callback, before that error reaches
            // here, so a cancel is judged from when the reply was added.
            final cancelled = cancelledAtReply ?? request.isCancelled();
            if (!cancelled || turn.isCallbackError(error)) rethrow;
          }
          final reply = accumulator.build();
          LlamaToolLoopResult stop(
            LlamaToolLoopStopReason reason, {
            bool rollBack = true,
            List<LlamaToolCallContent>? pendingToolCalls,
          }) {
            if (rollBack) turn.rollBack();
            return LlamaToolLoopResult(
              completion: reply,
              stopReason: reason,
              rounds: rounds,
              pendingToolCalls: pendingToolCalls ?? reply.toolCalls,
              messages: List.unmodifiable(turn.messages),
              rolledBack: rollBack,
            );
          }

          if (request.isCancelled()) {
            yield stop(
              LlamaToolLoopStopReason.cancelled,
              rollBack: reply.toolCalls.isNotEmpty || !turn.endsWithReply,
            );
            return;
          }
          if (reply.finishReason == LlamaFinishReason.length) {
            yield stop(LlamaToolLoopStopReason.truncated);
            return;
          }
          if (reply.toolCalls.isEmpty) {
            yield stop(LlamaToolLoopStopReason.completed, rollBack: false);
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
            for (final call in reply.toolCalls)
              _toolRun(call, tools, onToolCall),
          ];
          if (runs.contains(null)) {
            yield stop(
              LlamaToolLoopStopReason.unhandledToolCalls,
              rollBack: false,
            );
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
            turn.add(message);
          }
          rounds += 1;

          if (request.isCancelled()) {
            yield stop(
              LlamaToolLoopStopReason.cancelled,
              pendingToolCalls: const [],
            );
            return;
          }
          nextParts = const [];
        }
      } catch (_) {
        turn.rollBack();
        rethrow;
      }
    }).single;
  }
}

/// The turn one tool loop works on, so it can be rolled back without
/// removing messages that other callers added meanwhile.
class _ToolLoopTurn {
  _ToolLoopTurn(
    this._session,
    this._onMessageAdded, {
    required bool continuesTurn,
  }) {
    if (continuesTurn) {
      final history = _session.history;
      messages.addAll(history.skip(_openTurnStart(history)));
    }
  }

  final ChatSession _session;
  final void Function(LlamaChatMessage message)? _onMessageAdded;

  /// The open turn a continuation picks up, then every message the loop
  /// added.
  final List<LlamaChatMessage> messages = [];
  final List<LlamaChatMessage> _appended = [];
  LlamaChatMessage? _lastAdded;
  Object? _callbackError;

  /// Whether the latest message the loop added is a reply.
  bool get endsWithReply => _lastAdded?.role == LlamaChatRole.assistant;

  /// Whether [error] was thrown by the app's `onMessageAdded`.
  bool isCallbackError(Object error) => identical(error, _callbackError);

  /// Adds [message] with [ChatSession.addMessage] and reports it.
  ///
  /// Every instance the call appended to the stored history is also
  /// removed on a rollback, since an override may store a copy or append
  /// more messages.
  void add(LlamaChatMessage message) {
    List<LlamaChatMessage> stored() =>
        mutableChatSessionHistory(_session) ?? _session.history;
    final countBefore = stored().length;
    _session.addMessage(message);
    final after = stored();
    if (after.length > countBefore) {
      _appended.addAll(
        after
            .sublist(countBefore)
            .where((stored) => !identical(stored, message)),
      );
    }
    report(message);
  }

  void report(LlamaChatMessage message) {
    messages.add(message);
    _lastAdded = message;
    try {
      _onMessageAdded?.call(message);
    } catch (error) {
      _callbackError = error;
      rethrow;
    }
  }

  /// Removes the turn's messages from the history.
  ///
  /// A [ChatSession] is edited in place, without calling its overridable
  /// [ChatSession.addMessage] or [ChatSession.reset]; a class that only
  /// implements [ChatSession] is rebuilt through those two methods.
  void rollBack() {
    final turn = [...messages, ..._appended];
    final history = mutableChatSessionHistory(_session);
    if (history != null) {
      _removeTurn(history, turn);
      return;
    }
    final rebuilt = _session.history.toList();
    _removeTurn(rebuilt, turn);
    _session.reset(keepSystemPrompt: true);
    rebuilt.forEach(_session.addMessage);
  }
}

/// Removes [turn] from [history], matching each message by identity from
/// the end, so an earlier turn that holds the same (for example `const`)
/// instance keeps it.
void _removeTurn(List<LlamaChatMessage> history, List<LlamaChatMessage> turn) {
  final remaining = List.of(turn);
  for (var index = history.length - 1; index >= 0; index--) {
    if (remaining.isEmpty) return;
    final match = remaining.lastIndexWhere(
      (message) => identical(message, history[index]),
    );
    if (match < 0) continue;
    remaining.removeAt(match);
    history.removeAt(index);
  }
}

/// The index where the turn that ends [history] starts, or `history.length`
/// when that turn already has an answer: a reply without tool calls.
int _openTurnStart(List<LlamaChatMessage> history) {
  for (var index = history.length - 1; index >= 0; index--) {
    final message = history[index];
    if (message.role == LlamaChatRole.assistant &&
        !message.parts.any((part) => part is LlamaToolCallContent)) {
      break;
    }
    if (message.role == LlamaChatRole.user && !message.continuesPreviousTurn) {
      return index;
    }
  }
  return history.length;
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
