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
- Every API returns a `Stream`. Read `chunk.text` for answer text and
  `chunk.thinking` for reasoning (empty strings when a chunk has none), and
  render the channels separately. `chunk.finishReason` is a typed
  `LlamaFinishReason` (`stop`, `length`, `toolCalls`) on the final chunk only.
  A cancelled generation usually still ends with `stop`, so track cancels in
  the code that issues them.
- To wait for the whole reply, use `await stream.text()`, or
  `await stream.collect()` for a `LlamaCompletion` with `text`, `thinking`,
  assembled `toolCalls`, `finishReason`, `usage` and an assistant `message`.
  `engine.complete(messages)` and `session.send('...')` are one-shot
  shorthands; `stream.textDeltas()` yields only non-empty text deltas.
- Only one generation runs at a time per engine. Starting another while one is
  running (and not cancelled) throws `LlamaStateException`; queue requests in
  app code.
- Stop generation with `engine.cancelGeneration()`, or by cancelling the stream
  subscription (including `break` out of `await for`), which also stops the
  backend. Keep a `StreamSubscription` in UI code so a Stop button can cancel
  it.
- Always set `GenerationParams.maxTokens`. Pass `enableThinking: false` to
  `engine.create` when reasoning output is not wanted.
- Token usage (`chunk.usage`) is only on the final chunk and may be null (for
  example on LiteRT-LM or a cancelled request). Never assume it is present.
- `chunk.model` is the last path segment of the model source (`qwen.gguf`),
  without directories or hosts, or `llama_model`. Compare it with the file
  name, and set your own model id on OpenAI-compatible responses: a URL whose
  last segment is a token reports that token.
- For strict JSON, use `LlamaStructuredOutput` with
  `engine.createStructuredJson`; it constrains decoding with a grammar and
  validates the final output; `session.createStructuredJson(parts, output:)`
  does the same within a `ChatSession`. Runtimes without grammar support
  (LiteRT-LM) throw `LlamaUnsupportedException` before generating. A raw
  `responseFormat` map must be `{'type': 'json_object'}`,
  `{'type': 'json_schema', 'json_schema': {'schema': ...}}` or
  `{'type': 'text'}`; any other type or key throws. Do not parse partial
  stream chunks as JSON.
- `session.reset()` clears history (`keepSystemPrompt: false` also clears the
  system prompt). `session.addMessage(...)` restores saved history.
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

Structured JSON with typed decoding (llama.cpp runtimes only):

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
