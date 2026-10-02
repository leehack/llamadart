---
name: llamadart-tool-calling
description: >-
  Use when adding tool or function calling to a llamadart app: defining
  ToolDefinition and ToolParam, running the tool-call loop with
  ChatSession.sendWithTools or by hand, choosing ToolChoice, or debugging
  models that ignore or malform tool calls.
---

# Tool calling with llamadart

## Guidelines

- Prefer `session.sendWithTools(text, tools: ..., maxRounds: ...)`: it runs
  each call's `ToolDefinition.handler` (concurrently for parallel calls),
  adds a `LlamaChatRole.tool` message per call with the call's id, and
  repeats until the model answers. Check `result.stopReason`
  (`LlamaToolLoopStopReason`): only `completed` means a final answer;
  `maxRounds`, `unhandledToolCalls`, `contextExceeded` and `cancelled` leave
  `result.pendingToolCalls` unrun. `completeWithTools(parts)` takes media
  parts; `completeWithTools(const [])` continues the turn.
- `handler` is optional. Leave it out for a tool the app runs itself (user
  approval, remote execution): give `onToolCall`, or let the loop stop with
  `unhandledToolCalls`, add the results with `session.addMessage(...)` and
  call `completeWithTools(const [], tools: ...)`.
- In the loop, a throwing tool, an unknown tool name or non-object arguments
  become the tool result `{'error': message}` so the model can recover.
  Pass `onToolError` to shape that result, or rethrow from it to fail the
  loop. `toolChoice` applies only to the first request.
- `ChatSession.create` and `engine.create` only return calls in
  `chunk.toolCalls`; use them by hand to stream replies or to run tools
  outside the loop.
- Tool calls arrive complete, with JSON-encoded `arguments`, in the final
  chunk; its `chunk.finishReason` is `LlamaFinishReason.toolCalls`. Collect
  the whole stream with `collect()` (or use `engine.complete` /
  `session.send`): `LlamaCompletion.toolCalls` holds `LlamaToolCallContent`
  entries with decoded `arguments` (empty when they are not a JSON object;
  `rawJson` keeps the text).
- By hand, invoke through `tool.invoke(call.arguments)`, which wraps the
  arguments in `ToolParams` for typed access; it does not validate them, and
  throws `LlamaStateException` for a tool without a handler. Read required
  arguments with `getRequired*`, which throws when one is missing. Catch errors
  and return them to the model as the tool result rather than crashing the
  loop.
- Return results with a `LlamaChatRole.tool` message containing
  `LlamaToolResultContent(id: call.id, name: ..., result: ...)`. `result` can
  be any JSON-compatible value.
- With `ChatSession`, the assistant's tool calls are already in history; add
  the tool results with `session.addMessage(...)` and continue with
  `session.create(const [])`. With `engine.create`, append the collected
  `completion.message` (it carries one `LlamaToolCallContent` per call) and
  the tool messages to your own list.
- Always cap the number of tool rounds (`maxRounds`, default 5); a model can
  call tools forever.
- `ToolChoice.auto` lets the model decide, `ToolChoice.required` forces a call
  and `ToolChoice.none` disables tools for one request.
- Tool quality depends on the model and its template. Templates without a
  native tool format use a generic JSON fallback that constrains the output
  shape but does not guarantee the right tool or arguments. If calls look
  wrong, inspect `engine.chatTemplate(...)` to see whether tool definitions
  reach the prompt, and describe the tools in the system prompt if not. To
  replace a broken GGUF template, load with `ModelParams(chatTemplate: ...)`;
  prompts and tool-call parsing then both follow that template.
- Runtime limits: LiteRT-LM has no grammar enforcement, LiteRT-LM on web does
  not forward tools, and WebGPU `ToolChoice.auto` parses calls best-effort.
  `(await engine.capabilities).supportsToolCalling`,
  `supportsStructuredOutput` and `supportsLazyGrammar` report these per
  loaded model. Test tool flows on every target runtime.

## Examples

Define a tool and run a bounded tool-call loop with `ChatSession`:

```dart
import 'package:llamadart/llamadart.dart';

final ToolDefinition weatherTool = ToolDefinition(
  name: 'get_weather',
  description: 'Get current weather for a city',
  parameters: [
    ToolParam.string('city', description: 'City name', required: true),
    ToolParam.enumType('unit', values: ['celsius', 'fahrenheit']),
  ],
  handler: (params) async {
    final String city = params.getRequiredString('city');
    final String unit = params.getString('unit') ?? 'celsius';
    return {'city': city, 'temperature': 22, 'unit': unit};
  },
);

Future<String?> runTools(LlamaEngine engine, String question) async {
  final ChatSession session = ChatSession(engine);
  final LlamaToolLoopResult result = await session.sendWithTools(
    question,
    tools: [weatherTool],
    maxRounds: 5,
  );
  if (result.stopReason != LlamaToolLoopStopReason.completed) {
    print('Stopped: ${result.stopReason.name}');
    return null;
  }
  return result.text;
}
```

Run a tool that needs approval in the app instead of a handler:

```dart
import 'package:llamadart/llamadart.dart';

const ToolDefinition deleteFileTool = ToolDefinition(
  name: 'delete_file',
  description: 'Delete a file in the workspace',
  parameters: [],
);

Future<LlamaToolLoopResult> runWithApproval(
  ChatSession session,
  String request,
  Future<bool> Function(LlamaToolCallContent call) approve,
) {
  return session.sendWithTools(
    request,
    tools: [deleteFileTool],
    onToolCall: (LlamaToolCallContent call) async =>
        await approve(call) ? {'deleted': true} : {'error': 'Denied by user'},
  );
}
```

Force a single tool call for one request:

```dart
import 'package:llamadart/llamadart.dart';

Future<LlamaToolCallContent?> forceCall(
  LlamaEngine engine,
  List<ToolDefinition> tools,
  String request,
) async {
  final LlamaCompletion reply = await engine.complete(
    [LlamaChatMessage.fromText(role: LlamaChatRole.user, text: request)],
    tools: tools,
    toolChoice: ToolChoice.required,
    params: const GenerationParams(maxTokens: 256, temp: 0),
  );
  return reply.toolCalls.firstOrNull;
}
```

## More

- Tool calling: https://llamadart.leehack.com/docs/guides/tool-calling
- Chat templates and parsing: https://llamadart.leehack.com/docs/guides/chat-template-and-parsing
