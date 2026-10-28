---
name: llamadart-chat-streaming
description: >-
  Use when generating text with llamadart: choosing between engine.generate,
  engine.create and ChatSession, streaming content and thinking deltas,
  managing chat history and context, cancelling generation, or producing
  structured JSON output.
---

# Chat and streaming with llamadart

## Guidelines

- Pick the entry point by who owns history:
  - `ChatSession.create(parts)` for multi-turn chat. It applies the system
    prompt, appends user and assistant turns, and trims the oldest turns to fit
    `maxContextTokens` (default: the loaded context size).
  - `engine.create(messages)` when the app owns the transcript (servers,
    one-shot tasks, edited or persisted histories). Pass the full message list
    every call and append the assistant reply yourself.
  - `engine.generate(prompt)` only for an already-rendered raw prompt; it skips
    the chat template.
- Opt in with the portable `LlamaBackend.withTextHistory()` factory, or the
  direct Web `LiteRtLmBackend.withTextHistory()` factory, for ordered
  system/user/assistant text through
  `engine.create` and `ChatSession` when the loaded runtime's preface/history
  API probe passes; check `supportsMultiTurnChat` after loading. Each request
  owns a new conversation and supplies its visible transcript once. Stored
  assistant reasoning stays in app history and is omitted from replay/accounting. Use a Web-compatible
  `.litertlm` bundle. Existing default/direct constructors keep legacy LiteRT
  Web single-user-text
  routing and subclass hooks. Native selection is unchanged; Genkit adoption is
  separate. On this Web path, tools, tool/media and user/system thinking parts, a final assistant/system
  message, custom templates, `enableThinking: false`, template kwargs and explicit
  template clocks throw `LlamaUnsupportedException`. Model-default thinking stays
  unchanged. Old runtimes reject history/system input and retain one-user-text
  completion. Budget trimming uses a full-transcript UTF-8 estimate because
  the JS tokenizer/template count is unavailable; accounting JSON is not sent
  as a replacement model prompt. This text slice leaves tools/media/template work in
  [#1152](https://github.com/leehack/llamadart/issues/1152).
- For reproducible Dart-rendered template dates, use
  `TemplateTimeChatSession(engine, templateNow: DateTime.utc(2026, 1, 2))`.
  Each listened request snapshots the value before budget rendering and
  generation. A change affects the next request (including a tool-loop round);
  `reset()` keeps the setting and `null` restores the normal clock.
  Runtime-owned LiteRT-LM templates retain their runtime clock.
- Embedded and custom Jinja templates accept `\xHH` string escapes;
  `\x00` matches NUL, and `\\x41` preserves literal `\x41`. A malformed
  escape raises `LlamaException` naming the template source. A valid template
  also needs a runtime that supports the model architecture.
- Every API returns a `Stream`. Read `chunk.text` for answer text and
  `chunk.thinking` for reasoning (empty strings when a chunk has none), and
  render the channels separately. `chunk.finishReason` is a typed
  `LlamaFinishReason` (`stop`, `length`, `toolCalls`) on the final chunk only.
  On native llama.cpp and LiteRT-LM a cancelled generation usually still ends
  with `stop`; on WebGPU `cancelGeneration()` can surface as a generation
  error. `ChatSession` cancellation before any reply content instead throws
  `LlamaStateException` and rolls back the turn, including structured JSON.
  Track cancels in the code that issues them.
  On LiteRT-LM Web, only the exact `Task cancelled` runtime error after a
  cancel request ends normally. Other failures still surface as
  `LlamaInferenceException`; keep the stream's error handler after stopping.
- Ministral-format replies stopped inside a leading `[THINK]` block without
  `[TOOL_CALLS]` keep the unfinished thought in `thinking`, including after
  cancellation or a token limit. A normal end under `ToolChoice.required` still
  throws `LlamaInferenceException` when the required call is missing.
- To wait for the whole reply, use `await stream.text()`, or
  `await stream.collect()` for a `LlamaCompletion` with `text`, `thinking`,
  assembled `toolCalls`, `finishReason`, `usage` and an assistant `message`.
  `engine.complete(messages)` and `session.send('...')` are one-shot
  shorthands; `stream.textDeltas()` yields only non-empty text deltas.
- Only one generation runs at a time per engine. Starting another while one is
  running (and not cancelled) throws `LlamaStateException`; queue requests in
  app code.
- On native llama.cpp, await text-to-speech (including cancellation) before
  using the same context for generation, embeddings, scoring, state save/load
  or LoRA changes. Overlap throws `LlamaStateException` from speaker-reference
  loading through synthesis cleanup and preserves the active request's counters.
- Stop generation with `engine.cancelGeneration()`, or by cancelling the stream
  subscription (including `break` out of `await for`), which also stops the
  backend. Keep a `StreamSubscription` in UI code so a Stop button can cancel
  it.
- Native llama.cpp and LiteRT-LM report `getPerformanceContext() == null`
  after a queued generation is cancelled before it runs, including a request
  already sent to the LiteRT-LM worker. LiteRT-LM validation failures,
  llama.cpp option-validation failures before its counter reset, and failed
  dispatches also invalidate counters. On native llama.cpp, generation,
  embedding (the whole batch), scoring and text-to-speech reset counters
  before execution and restore diagnostics for only that request. Request
  validation failures in the native worker leave diagnostics unavailable;
  rejections during active text-to-speech preserve its counters. Argument
  checks that fail before dispatch leave them unchanged. Native token counts retain llama.cpp's
  minimum of one; embedding and scoring report `0` ms timings. LiteRT-LM recovers counters on generation.
  After an early cancellation, pending or failed embedding, scoring and speech
  calls keep diagnostics unavailable, including calls started before cancellation.
  Generation dispatch restores availability immediately; embedding, scoring and
  speech restore it only on success, using the backend's counter semantics.
  Web backends always
  return `null` diagnostics. Reloaded contexts keep their own counter availability. Treat null as
  unavailable diagnostics for the cancelled or unsent request.
- Native CPU Qwen3-0.6B: prefer the updated litert-community artifact at revision
  `e6687177e00897731e7716267eebd4eba0dde7c2`, SHA-256
  `c5f39b4191926786c3e6668b62af4d6eb15248dfc7a5348252a9b406f33f2108`.
  The legacy bundle can emit `ĠðŁĺĬ` in place of emoji; replace the bundle,
  preserve literal user text, and validate GPU/device/Web paths separately.
- Always set `GenerationParams.maxTokens`. Pass `enableThinking: false` to
  `engine.create` when reasoning output is not wanted; a `<think>` block a
  DeepSeek V3.1, Qwen3, QwQ or Qwen3.5 model still writes then stays in
  `chunk.text`, as in llama-server. A boolean
  `enable_thinking` or `thinking` in `chatTemplateKwargs` overrides it, as in
  llama-server, and every chat template receives the result as
  `enable_thinking`. A template's own setting in `chatTemplateKwargs`, such as
  `reasoning_effort` (Hy3, Cohere2 MoE) or `thinking_mode` (MiniMax M3), wins
  over the value derived from `enableThinking`. Native LiteRT-LM
  recognizes renamed Qwen 3 bundles only from a Qwen 3 model-type declaration
  (field 6), or the complete canonical Qwen 3 template in field 7 or
  `ModelParams.chatTemplate`. Legacy litert-community Qwen3-0.6B bundles have
  neither metadata field: keep `Qwen3` in the filename or use the
  `ModelParams(chatTemplate: liteRtLmQwen3ChatTemplate)` override. Import it
  from `package:llamadart/llamadart.dart`; get the string from this accessor
  when constructing parameters, rather than copying or persisting Jinja across
  upgrades. Web `@litert-lm/core@0.18.0` has no template setter and rejects
  this canonical override with `LlamaUnsupportedException` at load; use native
  LiteRT-LM for this contract. Otherwise disabled thinking
  can still return empty content after renaming. Generic thinking markers are
  insufficient. Other families keep native bundle templates and adapters;
  overrides still drive Dart-side metadata and parsing. Media routing is unchanged.
- Gate `penalty`, `presencePenalty` and `thinkingBudget` on
  `await engine.capabilities` (`supportsPenalty`, `supportsPresencePenalty`,
  `supportsThinkingBudget`); an unsupported value throws
  `LlamaUnsupportedException`. Native LiteRT-LM penalties count only the
  tokens of the current send, leave the default `penalty` unapplied and
  reject values below `1.0`. Its thinking budget applies to `engine.create`
  on bundles with a thinking channel (Gemma 4), closes that channel with the
  bundle's own marker, and rejects `0`, `forcedMessage` and speculative
  decoding. Min-P stays unsupported there.
- Token usage (`chunk.usage`) is only on the final chunk and may be null (for
  example on LiteRT-LM or a cancelled request). Never assume it is present.
- `chunk.model` is the last path segment of the model source (`qwen.gguf`),
  without directories or hosts, or `llama_model`. Compare it with the file
  name, and set your own model id on OpenAI-compatible responses: a URL whose
  last segment is a token reports that token (unless it repeats the URL's
  userinfo credential). LiteRT-LM Web omits a URL-derived name when its decoded
  basename contains URL delimiters, preventing encoded query text from becoming
  model metadata.
- For strict JSON, use `LlamaStructuredOutput` with
  `engine.createStructuredJson`; it constrains decoding and validates the
  final output. Native LiteRT-LM supports canonical Qwen3 text on
  macOS arm64 CPU after provider admission, with `enableThinking: false` and an
  object schema limited to scalar properties, required, enum/const and boolean
  additionalProperties. Only the corrected Qwen3-0.6B artifact above has model-backed qualification.
  It rejects tools/media/custom templates/speculation/caller stops and broader schemas; GBNF remains unsupported. Web LiteRT-LM
  rejects strict schemas. `session.createStructuredJson(parts, output:)`
  does the same within a `ChatSession`. Runtimes without either enforcement path throw `LlamaUnsupportedException` before generating. A raw
  `responseFormat` map must be `{'type': 'json_object'}`,
  `{'type': 'json_schema', 'json_schema': {'schema': ...}}`, where
  `json_schema` may also hold `name`, `description` and `strict`, or
  `{'type': 'text'}`; a `null`-valued key counts as absent, and any other type
  or key throws. Raw and typed schemas share strict validation: unsupported
  assertions (number bounds, formats other than uuid/uuid1–uuid5/date/time/date-time,
  multipleOf, uniqueness/contains, property/dependency constraints, conditionals,
  unevaluated keywords, additionalItems and dynamic/recursive references),
  shadowed siblings and length/item bounds above 2000 throw with a schema path.
  Exceptions: `uniqueItems: false`, `minProperties: 0` and integer `multipleOf: 1`
  are trivial and accepted. UUID aliases use the same lexical rule as uuid, with
  uppercase hex allowed. Bounded arrays do not require items; their elements can
  be any JSON value. Negative integer maxima reject leading-zero JSON.
  Integer bounds, compatible fixed tuples (`items: [...]` or `prefixItems`),
  additive allOf object merges and enum intersections are supported. Object
  merges ignore annotation-only components. AllOf primitive/nested/union
  components, annotation-only components outside an object merge, duplicate
  properties and constrained additional properties are rejected. Annotations and unknown vocabulary are
  ignored as constraints; refs must target schema positions. Unused $defs and
  definitions are ignored; referenced entries are validated. See MIGRATION.md
  for combination, integer-range and upstream suffix limits. Nonempty annotation-only
  untyped schemas accept any value; `{}` keeps its object grammar. JSON nesting,
  including annotation payloads, is limited to 128 containers. A `ChatSession` turn that throws this way, or fails or has
  its subscription cancelled before any reply content, removes its user
  message from `session.history`; empty terminal chunks are not content.
  Generation cancellation before content throws `LlamaStateException`.
  One stopped later keeps the partial reply as the assistant turn only if
  the session has not reset and its initiating message remains. A history
  edit during context preparation throws `LlamaStateException`. Do not parse partial stream chunks as JSON.
- `session.reset()` clears history (`keepSystemPrompt: false` also clears the
  system prompt). `session.addMessage(...)` restores saved history.
- Reply text keeps whitespace the model ended it with (`reply.text` can end
  in `\n`, also before a stop sequence); `trimRight()` it before an exact
  comparison. `session.history` stores the assistant turn without it.
- Use `engine.getTokenCount(text)` for context budgeting instead of estimating
  from characters.

## Examples

Multi-turn chat with cancellation:

```dart
import 'dart:async';

import 'package:llamadart/llamadart.dart';

Future<String> ask(ChatSession session, String question) async {
  final LlamaCompletion reply = await session.send(
    question,
    params: const GenerationParams(maxTokens: 256, temp: 0.7),
  );
  return reply.text;
}

Future<void> chat(LlamaEngine engine) async {
  final ChatSession session = ChatSession(
    engine,
    systemPrompt: 'You are concise.',
  );
  print(await ask(session, 'What is quantization?'));
  print(await ask(session, 'Give one downside of it.'));

  final Timer timeout = Timer(
    const Duration(seconds: 10),
    engine.cancelGeneration,
  );
  try {
    print(await ask(session, 'Write a long story.'));
  } finally {
    timeout.cancel();
  }
}
```

Stateless completion that separates reasoning from the answer:

```dart
import 'package:llamadart/llamadart.dart';

Future<void> explain(LlamaEngine engine) async {
  final List<LlamaChatMessage> messages = [
    const LlamaChatMessage.fromText(
      role: LlamaChatRole.system,
      text: 'Answer in one paragraph.',
    ),
    const LlamaChatMessage.fromText(
      role: LlamaChatRole.user,
      text: 'Explain top-p sampling.',
    ),
  ];

  LlamaCompletionChunk? last;
  await for (final chunk in engine.create(
    messages,
    params: const GenerationParams(maxTokens: 512, topP: 0.95),
  )) {
    if (chunk.thinking.isNotEmpty) print('[thinking] ${chunk.thinking}');
    if (chunk.text.isNotEmpty) print(chunk.text);
    last = chunk;
  }

  final LlamaGenerationUsage? usage = last?.usage;
  if (usage != null) {
    print('prompt ${usage.promptTokens}, completion ${usage.completionTokens}');
  }
}
```

Structured JSON with typed decoding:

```dart
import 'package:llamadart/llamadart.dart';

class Ticket {
  Ticket(this.priority, this.category);

  final String priority;
  final String category;

  static Ticket fromJson(Map<String, dynamic> json) =>
      Ticket(json['priority'] as String, json['category'] as String);
}

Future<Ticket> classify(LlamaEngine engine, String text) {
  final LlamaStructuredOutput<Ticket> output =
      LlamaStructuredOutput<Ticket>.jsonSchema(
        schema: const {
          'type': 'object',
          'properties': {
            'priority': {
              'type': 'string',
              'enum': ['low', 'medium', 'high'],
            },
            'category': {'type': 'string'},
          },
          'required': ['priority', 'category'],
          'additionalProperties': false,
        },
        decoder: Ticket.fromJson,
      );

  return engine.createStructuredJson(
    [
      LlamaChatMessage.fromText(
        role: LlamaChatRole.user,
        text: 'Classify this ticket: $text',
      ),
    ],
    output: output,
    params: const GenerationParams(maxTokens: 96, temp: 0),
  );
}
```

## More

- Generation and streaming: https://llamadart.leehack.com/docs/guides/generation-and-streaming
- First chat session: https://llamadart.leehack.com/docs/getting-started/first-chat-session
