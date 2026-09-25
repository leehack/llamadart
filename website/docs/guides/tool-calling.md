---
title: Tool calling with local models
sidebar_label: Tool calling
description: Define tools with ToolDefinition, control them with ToolChoice, and run a template-aware tool-calling loop with a local model.
---

`llamadart` supports template-aware tool calling through `ToolDefinition` and
`ToolChoice`.

## Define a tool

```dart
final weatherTool = ToolDefinition(
  name: 'get_weather',
  description: 'Get current weather for a city',
  parameters: [
    ToolParam.string('city', description: 'City name', required: true),
    ToolParam.enumType('unit', values: ['celsius', 'fahrenheit']),
  ],
  handler: (params) async {
    final city = params.getRequiredString('city');
    final unit = params.getString('unit') ?? 'celsius';
    return {'city': city, 'temperature': 22, 'unit': unit};
  },
);
```

## Run completion with tools

```dart
final stream = engine.create(
  [
    LlamaChatMessage.fromText(
      role: LlamaChatRole.user,
      text: 'What is the weather in Seoul?',
    ),
  ],
  tools: [weatherTool],
  toolChoice: ToolChoice.auto,
  parallelToolCalls: false,
);
```

## Typical execution loop

1. Stream assistant response.
2. Detect tool call content from deltas/messages.
3. Execute matching tool handler.
4. Append tool result message.
5. Call `engine.create(...)` again for final assistant response.

`LlamaToolResultContent.result` can contain JSON-compatible objects, arrays,
scalars, or null. The shared template renderer encodes these as JSON text;
string results remain unchanged. This conversion does not mutate the typed
result or change its public JSON representation. Multimodal templates receive
the encoded result as a text part.

Qwen XML tool calls are validated against the tools supplied to `engine.create`.
Schema-declared strings such as `"123"` retain their type. Unknown functions,
unknown or duplicate parameters, missing required values, and invalid value
types remain response content instead of producing callable tool deltas.
Tool calls are emitted after final validation; malformed output is preserved
through the existing rollback behavior. Direct schema-free template parsing
retains its legacy behavior, so pass tool definitions when validating calls.

For an end-to-end OpenAI-compatible reference, see
`example/llamadart_server` and the docs page
[OpenAI-Compatible Server](../examples/llamadart-server).

## Tool choice semantics

- `ToolChoice.none`: disable tool calls for that request.
- `ToolChoice.auto`: model decides whether to call tools.
- `ToolChoice.required`: model must emit tool calls.

On Web with WebGPU (llama.cpp), the bridge applies a grammar from the first
token and cannot wait for a tool-call trigger. `ToolChoice.auto` therefore skips
a lazy tool-call grammar, and tool calls are parsed from the output
best-effort. `ToolChoice.required` keeps a grammar that starts at the first
token and fails early with `LlamaUnsupportedException` when the chat format's
required-tool grammar is lazy.

Without that grammar, Qwen2.5 can copy the double braces its GGUF template
prints in the tool prompt:
`<tool_call>{{"name": "get_weather", "arguments": {"city": "Paris"}}}</tool_call>`,
sometimes with fewer or more closing braces. The Hermes/Qwen parser extracts
the call. When only closing braces and whitespace follow the call before
`</tool_call>`, the envelope leaves no content, as for the single-brace form;
otherwise its text stays in content. This deliberately differs from upstream
llama.cpp (`7fe450e1`), which fails to parse this output and returns no tool
call.
