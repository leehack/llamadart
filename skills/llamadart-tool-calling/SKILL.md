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
  template renders them and the parser returns calls in `delta.toolCalls`.
  llamadart never runs a handler for you: the app executes each call.
- Tool calls arrive complete, with JSON-encoded `arguments`, in the final
  chunk; its `finishReason` is `tool_calls`. Collect them over the whole
  stream.
- Invoke through `tool.invoke(decodedArguments)`, which wraps the arguments in
  `ToolParams` for typed access; it does not validate them. Read required
  arguments with `getRequired*`, which throws when one is missing. Catch errors
  and return them to the model as the tool result rather than crashing the
  loop.
- Return results with a `LlamaChatRole.tool` message containing
  `LlamaToolResultContent(id: call.id, name: ..., result: ...)`. `result` can
  be any JSON-compatible value.
- With `ChatSession`, the assistant's tool calls are already in history; add
  the tool results with `session.addMessage(...)` and continue with
  `session.create(const [])`. With `engine.create`, append the assistant
  message (one `LlamaToolCallContent` per call) and the tool messages to your
  own list.
- Always cap the number of tool rounds; a model can call tools forever.
- `ToolChoice.auto` lets the model decide, `ToolChoice.required` forces a call
  and `ToolChoice.none` disables tools for one request.
- Tool quality depends on the model and its template. Templates without a
  native tool format use a generic JSON fallback that constrains the output
  shape but does not guarantee the right tool or arguments. If calls look
  wrong, inspect `engine.chatTemplate(...)` to see whether tool definitions
  reach the prompt, and describe the tools in the system prompt if not.
- Runtime limits: LiteRT-LM has no grammar enforcement, LiteRT-LM on web does
  not forward tools, and WebGPU `ToolChoice.auto` parses calls best-effort.
  Test tool flows on every target runtime.

## Examples

Define a tool and run a bounded tool-call loop with `ChatSession`:

```dart
import 'dart:convert';

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
    final List<LlamaCompletionChunkToolCall> calls = [];
    await for (final chunk in session.create(parts, tools: tools)) {
      final LlamaCompletionChunkDelta delta = chunk.choices.first.delta;
      if (delta.content != null) print(delta.content);
      calls.addAll(delta.toolCalls ?? const []);
    }
    if (calls.isEmpty) break;

    for (final call in calls) {
      final String name = call.function?.name ?? '';
      final String arguments = call.function?.arguments ?? '';
      Object? result;
      try {
        final ToolDefinition tool = tools.firstWhere((t) => t.name == name);
        result = await tool.invoke(
          arguments.isEmpty
              ? const {}
              : jsonDecode(arguments) as Map<String, dynamic>,
        );
      } catch (error) {
        result = 'Error: $error';
      }
      session.addMessage(
        LlamaChatMessage.withContent(
          role: LlamaChatRole.tool,
          content: [
            LlamaToolResultContent(id: call.id, name: name, result: result),
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

Future<LlamaCompletionChunkToolCall?> forceCall(
  LlamaEngine engine,
  List<ToolDefinition> tools,
  String request,
) async {
  await for (final chunk in engine.create(
    [LlamaChatMessage.fromText(role: LlamaChatRole.user, text: request)],
    tools: tools,
    toolChoice: ToolChoice.required,
    params: const GenerationParams(maxTokens: 256, temp: 0),
  )) {
    final List<LlamaCompletionChunkToolCall>? calls =
        chunk.choices.first.delta.toolCalls;
    if (calls != null && calls.isNotEmpty) {
      return calls.first;
    }
  }
  return null;
}
```

## More

- Tool calling: https://llamadart.leehack.com/docs/guides/tool-calling
- Chat templates and parsing: https://llamadart.leehack.com/docs/guides/chat-template-and-parsing
