# llamadart OpenAI-Compatible API Server Example

This example runs a local API server in Dart using
[`relic`](https://pub.dev/packages/relic), backed by `llamadart`.

It exposes OpenAI-compatible endpoints:

- `GET /v1/models`
- `POST /v1/chat/completions`
- `POST /v1/embeddings`
- `GET /openapi.json`
- `GET /docs` (Swagger UI)

## Features

- OpenAI-style JSON responses
- Streaming (`stream: true`) over SSE with `data: [DONE]`
- Optional Bearer auth (`--api-key`)
- Built-in OpenAPI + Swagger UI docs
- CORS support for local browser clients
- One loaded GGUF model per server process

## Project structure

This example now follows a feature-first structure:

- `lib/src/features/openai_api/` - OpenAI-compatible HTTP server and docs
- `lib/src/features/chat_completion/` - chat request model, parser, mapper, and
  completion use cases
- Model paths, URLs, and Hugging Face sources load through
  `LlamaEngine.loadModelSource(...)`, using the core runtime's cache and
  download policy
- `lib/src/features/server_engine/` - engine contract + llama engine adapter
- `lib/src/features/shared/` - shared API error types
- `lib/src/bootstrap/` - CLI argument parsing and runtime wiring

Public APIs are exported directly from `lib/llamadart_server.dart`.

## Limitations

- Supports a single generation at a time (returns 429 while busy)
- Supports `n = 1` only
- Function tools follow the standard client-managed Chat Completions flow: the
  server returns `tool_calls`, your client executes them, then submits the
  assistant tool-call message and matching `role: "tool"` result in a new
  request. The server never executes application tools.
- No legacy Completions endpoint
- The default Qwen3.6 27B GGUF is loaded text-only; this example does not
  download or load its separate vision projector.

## Run

```bash
dart pub get
dart run llamadart_server
```

With no `--model` override, the first launch downloads the default 17.6 GB
Unsloth model. Pass `--model /path/to/model.gguf` to use a local GGUF instead.
You can also pass a remote GGUF URL or an `hf://owner/repo/path` source for
automatic resolution and download.

Optional flags:

- `--model-id` (default: `llamadart-local`)
- `--host` (default: `127.0.0.1`)
- `--port` (default: `8080`)
- `--api-key` (optional)
- `--context-size` (default: `16384`)
- `--gpu-layers` (default: `999`)
- `--log` (enable verbose Dart + HTTP request logs; native logs stay error-only)

### Exit codes

- `0` - success (including `--help`)
- `64` - invalid CLI usage or argument values
- `70` - runtime/server startup failure

### Sampling defaults

When omitted in a request body, this example server applies the supported
subset of Qwen3.6 27B's non-thinking text profile:

- `temperature = 0.7`
- `top_k = 20`
- `top_p = 0.8`
- `min_p = 0.0`
- `repetition penalty = 1.0`

Request-provided sampling fields (for example `temperature`, `top_p`, `seed`,
`max_tokens`) override these defaults per call.

Qwen also recommends a presence penalty, but this example's current backend
does not expose presence-penalty control. Do not substitute repetition penalty
for it; they have different effects.

### Default model and thinking mode

The default is Unsloth's `Qwen3.6-27B-UD-Q4_K_XL.gguf` (about 17.6 GB). Plan
for at least 32 GB of free unified memory or VRAM plus runtime headroom; use
`--gpu-layers 0` to force CPU inference when GPU memory is insufficient.
The 16,384-token context is a practical server default that leaves room for
normal chat;
increase it cautiously because larger contexts need substantially more memory.

Qwen3.6 thinks by default, but this API server intentionally disables thinking
unless a request sets `"enable_thinking": true`, so ordinary calls return
assistant `content` promptly. Thinking responses use a separate
`reasoning_content` channel and the Qwen thinking profile (`temperature: 1.0`,
`top_p: 0.95`). `max_tokens` covers both reasoning and the final answer; the
server's inherited default is 4,096 tokens. Use streaming and raise the limit
for thought-intensive requests while leaving room for the prompt in the
16,384-token context. A request that ends during reasoning can correctly have
`reasoning_content` but no final `content`.

## API Examples

### 0. OpenAPI and Swagger UI

- OpenAPI JSON: `http://127.0.0.1:8080/openapi.json`
- Swagger UI: `http://127.0.0.1:8080/docs`
- Swagger includes ready-made chat request examples for basic and streaming
  completions, initial tool calls, streamed tool calls, thinking plus streamed
  tool calls, and the client-executed tool-result follow-up.

```bash
curl http://127.0.0.1:8080/openapi.json
```

If `--api-key` is enabled, use Swagger UI's **Authorize** button and enter your
API key value.

### 1. List models

```bash
curl http://127.0.0.1:8080/v1/models
```

### 2. Non-streaming chat completion

```bash
curl http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "llamadart-local",
    "messages": [
      {"role": "system", "content": "You are concise."},
      {"role": "user", "content": "Give me one sentence about Seoul."}
    ],
    "max_tokens": 128,
    "enable_thinking": false
  }'
```

### 3. Streaming chat completion (SSE)

```bash
curl -N http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "llamadart-local",
    "stream": true,
    "messages": [
      {"role": "user", "content": "Write a 3-line poem."}
    ]
  }'
```

### 4. Tool calling (client-executed)

This server uses the standard OpenAI Chat Completions sequence:

1. Send the user messages, `tools`, and a `tool_choice`.
2. Receive an assistant response with `finish_reason: "tool_calls"` and
   `message.tool_calls`.
3. Execute each function in your application.
4. Append the entire assistant tool-call message and one `role: "tool"` message
   per result. Each result must use the exact returned `tool_call_id`.
5. Send the expanded transcript in a new `POST /v1/chat/completions` request.

Set `parallel_tool_calls: true` to permit multiple calls in one response when
the active model template supports it; append a result for every returned call.

Use Swagger's **Tool call: request a function** example for step 1 and
**Tool call: submit the function result** for step 5. Swagger cannot transfer
a runtime call ID between requests, so replace `call_weather_example` and its
illustrative assistant message with the actual response from step 1. The
minimal standard tool-result message does not need a `name` field.

For a streaming tool call, accumulate `delta.tool_calls` fragments by index
until the terminal `finish_reason` is `tool_calls`; then follow the same steps.
The **Tool call: reasoning + function request (SSE)** Swagger example also
demonstrates Qwen's optional `reasoning_content` stream.

### 5. With API key

```bash
curl http://127.0.0.1:8080/v1/models \
  -H "Authorization: Bearer YOUR_KEY"
```

### 6. Embeddings

```bash
curl http://127.0.0.1:8080/v1/embeddings \
  -H "Content-Type: application/json" \
  -d '{
    "model": "llamadart-local",
    "input": [
      "llamadart supports local inference.",
      "Embeddings are useful for semantic search."
    ],
    "encoding_format": "float"
  }'
```

## Tests

```bash
dart test
```
