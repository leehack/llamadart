---
name: llamadart-tool-calling
description: >-
  Use when adding tool or function calling to a llamadart app: defining
  ToolDefinition and ToolParam, running the tool-call loop with ChatSession or
  engine.create, choosing ToolChoice, or debugging models that ignore or
  malform tool calls.
---

# Tool calling with llamadart

## Guidelines

- Pass `tools:` to `ChatSession.create` or `engine.create`. The model's chat
  template renders them and the parser returns calls in `chunk.toolCalls`.
  llamadart never runs a handler for you: the app executes each call.
- Tool calls arrive complete, with JSON-encoded `arguments`, in the final
  chunk; its `chunk.finishReason` is `LlamaFinishReason.toolCalls`. Collect
  the whole stream with `collect()` (or use `engine.complete` /
  `session.send`): `LlamaCompletion.toolCalls` holds `LlamaToolCallContent`
  entries with decoded `arguments` (empty when they are not a JSON object;
  `rawJson` keeps the text).
- Invoke through `tool.invoke(call.arguments)`, which wraps the arguments in
  `ToolParams` for typed access; it does not validate them. Read required
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
- Always cap the number of tool rounds; a model can call tools forever.
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

Future<void> runTools(LlamaEngine engine, String question) async {
  final List<ToolDefinition> tools = [weatherTool];
  final ChatSession session = ChatSession(engine);

  List<LlamaContentPart> parts = [LlamaTextContent(question)];
  for (int round = 0; round < 5; round++) {
    final LlamaCompletion reply = await session
        .create(parts, tools: tools)
        .collect();
    if (reply.text.isNotEmpty) print(reply.text);
    if (reply.toolCalls.isEmpty) break;

    for (final LlamaToolCallContent call in reply.toolCalls) {
      Object? result;
      try {
        final ToolDefinition tool = tools.firstWhere(
          (t) => t.name == call.name,
        );
        result = await tool.invoke(call.arguments);
      } catch (error) {
        result = 'Error: $error';
      }
      session.addMessage(
        LlamaChatMessage.withContent(
          role: LlamaChatRole.tool,
          content: [
            LlamaToolResultContent(
              id: call.id,
              name: call.name,
              result: result,
            ),
          ],
        ),
      );
    }
    parts = const [];
  }
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
