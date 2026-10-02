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
/// rolls the turn back; see [LlamaToolLoopResult.messages].
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

  /// `LlamaEngine.cancelGeneration` was called while the loop ran. A partial
  /// reply without tool calls stays in the history as the turn's answer;
  /// otherwise the turn was rolled back.
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
  /// whose results were added to the turn.
  final int rounds;

  /// The calls of [completion] that were not run, in call order.
  ///
  /// Empty when [stopReason] is [LlamaToolLoopStopReason.completed]. After
  /// [LlamaToolLoopStopReason.unhandledToolCalls], answer each call with a
  /// `LlamaChatRole.tool` message through `ChatSession.addMessage`, then call
  /// `completeWithTools(const [], ...)`.
  final List<LlamaToolCallContent> pendingToolCalls;

  /// Every message the loop added to `ChatSession.history`, in order: the
  /// user message, each reply and each tool result.
  ///
  /// When the turn was rolled back (see [LlamaToolLoopStopReason]), none of
  /// them is in the history any more, but tools that ran keep their effects
  /// and their results are here. To resume such a turn, add these messages
  /// back with `ChatSession.addMessage`, answer [pendingToolCalls], and call
  /// `completeWithTools(const [], ...)`.
  final List<LlamaChatMessage> messages;

  /// Creates a tool loop result.
  const LlamaToolLoopResult({
    required this.completion,
    required this.stopReason,
    required this.rounds,
    this.pendingToolCalls = const [],
    this.messages = const [],
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
  /// result is `{'error': message}`, which puts the exception's text into
  /// the prompt and [ChatSession.history]; use [onToolError] to redact it.
  /// Rethrow from [onToolError] to stop the loop: this call then fails with
  /// that error once every call of the round has finished.
  ///
  /// The loop stops with a [LlamaToolLoopResult] when the model answers
  /// without a tool call, when it calls tools after [maxRounds] tool rounds,
  /// when a request did not fit its context budget (calls proposed from a
  /// trimmed prompt are not run), or when `LlamaEngine.cancelGeneration` is
  /// called. A cancel does not interrupt running tools. [maxRounds] must not
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
  /// `contextExceeded`, a cancel before an answer started) and any error
  /// this call throws roll the turn back: the history returns to what it
  /// was before this call. If the app changed the history meanwhile with
  /// [ChatSession.addMessage] or [ChatSession.reset], only the loop's own
  /// messages are removed. [LlamaToolLoopResult.messages] keeps the
  /// rolled-back messages, and [onMessageAdded] has already reported them.
  ///
  /// [toolChoice] applies to the first request only; later rounds use
  /// [ToolChoice.auto] so the model can answer. The other arguments have the
  /// same meaning as in [ChatSession.create], and [onMessageAdded] also
  /// reports each tool result message. Use [ChatSession.create] directly to
  /// stream replies as they are generated.
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
      final turn = _ToolLoopTurn(this, onMessageAdded);
      try {
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
                  onMessageAdded: turn.report,
                ),
              )
              .collect();
          LlamaToolLoopResult stop(
            LlamaToolLoopStopReason reason, {
            bool rollBack = true,
          }) {
            if (rollBack) turn.rollBack();
            return LlamaToolLoopResult(
              completion: reply,
              stopReason: reason,
              rounds: rounds,
              pendingToolCalls: reply.toolCalls,
              messages: List.unmodifiable(turn.added),
            );
          }

          if (reply.toolCalls.isEmpty) {
            yield request.isCancelled()
                ? stop(
                    LlamaToolLoopStopReason.cancelled,
                    rollBack: !turn.endsWithReply,
                  )
                : stop(LlamaToolLoopStopReason.completed, rollBack: false);
            return;
          }
          if (request.isCancelled()) {
            yield stop(LlamaToolLoopStopReason.cancelled);
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
            turn.rollBack();
            yield LlamaToolLoopResult(
              completion: reply,
              stopReason: LlamaToolLoopStopReason.cancelled,
              rounds: rounds,
              messages: List.unmodifiable(turn.added),
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

/// The [ChatSession.history] changes of one tool loop, so an abandoned turn
/// can be rolled back without discarding changes made by the app.
class _ToolLoopTurn {
  _ToolLoopTurn(this._session, this._onMessageAdded)
    : _before = _session.history,
      _editCount = _session.historyEditCount;

  final ChatSession _session;
  final void Function(LlamaChatMessage message)? _onMessageAdded;
  final List<LlamaChatMessage> _before;
  final int _editCount;

  final List<LlamaChatMessage> added = [];

  /// Whether the latest message the loop added is a reply.
  bool get endsWithReply => added.lastOrNull?.role == LlamaChatRole.assistant;

  void add(LlamaChatMessage message) {
    _session.addToolLoopMessage(message);
    report(message);
  }

  void report(LlamaChatMessage message) {
    added.add(message);
    _onMessageAdded?.call(message);
  }

  /// Restores the history from before the loop when the app did not change
  /// it since; otherwise removes only the loop's messages.
  void rollBack() {
    _session.replaceHistory(
      _session.historyEditCount == _editCount
          ? _before
          : [
              for (final message in _session.history)
                if (!added.any((own) => identical(own, message))) message,
            ],
    );
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
