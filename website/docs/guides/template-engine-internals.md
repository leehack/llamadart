---
title: Template engine internals
description: How the Dart port of the llama.cpp chat template, render and parse pipeline is structured, and how to debug template routing.
---

`llamadart` reimplements the `llama.cpp` chat-template/render/parse stack in
Dart so routing and parser behavior stay consistent across native and web
targets.

## Design goal

The template system prioritizes llama.cpp parity:

- format detection behavior
- handler routing logic
- tool-grammar attachment rules
- parse behavior for thinking and tool-call envelopes

## End-to-end pipeline

```mermaid
sequenceDiagram
    autonumber
    participant App as App/ChatSession
    participant Engine as LlamaEngine
    participant Detect as Format detector
    participant Handler as ChatTemplateHandler
    participant Dinja as dinja runtime
    participant Backend as Generation backend
    participant Parser as Chunk parser

    App->>Engine: create(messages, tools, params)
    Engine->>Detect: detect template format
    Detect-->>Engine: format + capability hints
    Engine->>Handler: select handler/workarounds
    Handler->>Dinja: render chat template
    Dinja-->>Handler: rendered prompt
    Handler-->>Engine: prompt + stops + grammar/parser payload
    Engine->>Backend: generate from rendered prompt

    loop streaming tokens
        Backend-->>Engine: token bytes
        Engine->>Parser: incremental decode/parse
        Parser-->>App: content/thinking/tool deltas
    end

    Engine->>Parser: finalize parse
    Parser-->>App: final tool-call structures + finish reason
```

## Main components

### 1. Format detection

- `ChatTemplateEngine` detects format from template signatures.
- Each detected format maps to a concrete `ChatTemplateHandler`.
- Handlers live under `lib/src/core/template/handlers/`.

### 2. Template capabilities and routing

- `TemplateCaps` estimates whether a template supports system role, tools,
  parallel tool calls, typed content, and thinking channels.
- `JinjaAnalyzer` augments regex checks with AST analysis and probe rendering.
- Routing workarounds mirror llama.cpp behavior for schema mode, tool-choice
  behavior, and system-message adaptation.

### 3. Render stage

- Handler `render(...)` builds the final prompt and metadata payload.
- Result includes:
  - prompt text
  - stop sequences
  - optional grammar
  - optional PEG parser payload
  - preserved tokens and lazy grammar triggers

### 4. Parse stage

- During streaming, partial output is parsed incrementally for content/thinking
  deltas and tool-call envelopes.
- On completion, final parse produces stable tool-call structures and finish
  reason semantics.
- PEG-backed parse paths are used when parser payloads are present.

## Tool-call parsing

Qwen XML tool calls are validated against the tools supplied to `engine.create`.
Schema-declared strings such as `"123"` retain their type. Unknown functions,
unknown or duplicate parameters, missing required values, and invalid value
types remain response content instead of producing callable tool deltas.
Tool calls are emitted after final validation; malformed output is preserved
through the existing rollback behavior. Direct schema-free template parsing
retains its legacy behavior, so pass tool definitions when validating calls.

Without a tool-call grammar, as with `ToolChoice.auto` on WebGPU, Qwen2.5 can
copy the double braces its GGUF template prints in the tool prompt:
`<tool_call>{{"name": "get_weather", "arguments": {"city": "Paris"}}}</tool_call>`,
sometimes with fewer or more closing braces. The Hermes/Qwen parser extracts
the call. When only closing braces and whitespace follow the call before
`</tool_call>`, the envelope leaves no content, as for the single-brace form;
otherwise its text stays in content. This deliberately differs from upstream
llama.cpp (`7fe450e1`), which fails to parse this output and returns no tool
call.

## `dinja` integration

`llamadart` uses [`dinja`](https://pub.dev/packages/dinja), the Dart Jinja
runtime used as the execution layer for model-provided chat templates
(`tokenizer.chat_template`).

`dinja` was built in the `llamadart` ecosystem as a Dart port of the
llama.cpp-style minimal Jinja execution model, then used as the foundation of
the template engine in this package.

Inside `llamadart`, the `jinja/` integration layer acts as the Dinja-plugin
surface: it wires llama.cpp-specific globals and capability analysis into
template execution.

Why this matters:

- no Python runtime dependency in app environments
- on-device template rendering in pure Dart
- reusable lexer/parser access for capability analysis (`JinjaAnalyzer`)

In practice, our template integration stack is:

1. `dinja` template execution for render.
2. `llamadart` routing/parity logic around it.
3. `llamadart` parser/grammar infrastructure for streamed output.

## Practical debugging flow

1. Call `engine.chatTemplate(...)` to inspect prompt/format/stops.
2. Verify tool schema and grammar expectations before generation.
3. Compare parsed output in partial vs final streaming stages.
4. Re-test after model/runtime upgrades to catch routing shifts early.

## Related docs

- [Chat Templates and Parsing](./chat-template-and-parsing)
- [Tool Calling](./tool-calling)
- [Generation and Streaming](./generation-and-streaming)
