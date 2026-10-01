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
- Every API returns a `Stream`. Read `chunk.choices.first.delta.content` for
  answer text and `delta.thinking` for reasoning; both are nullable. Render the
  channels separately.
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
- `chunk.model` is the model's file name (`qwen.gguf`), never its directory or
  URL; compare it with the file name, and set your own model id on
  OpenAI-compatible responses.
- For strict JSON, use `LlamaStructuredOutput` with
  `engine.createStructuredJson`; it constrains decoding with a grammar and
  validates the final output. Runtimes without grammar support (LiteRT-LM)
  throw `LlamaUnsupportedException` before generating. Do not parse partial
  stream chunks as JSON.
- `session.reset()` clears history (`keepSystemPrompt: false` also clears the
  system prompt). `session.addMessage(...)` restores saved history.
- Use `engine.getTokenCount(text)` for context budgeting instead of estimating
  from characters.

## Examples

Multi-turn chat with streaming and cancellation:

```dart
import 'dart:async';

import 'package:llamadart/llamadart.dart';

Future<String> ask(ChatSession session, String question) async {
  final StringBuffer answer = StringBuffer();
  await for (final chunk in session.create(
    [LlamaTextContent(question)],
    params: const GenerationParams(maxTokens: 256, temp: 0.7),
  )) {
    final String? text = chunk.choices.first.delta.content;
    if (text != null) {
      answer.write(text);
    }
  }
  return answer.toString();
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
    final String? thinking = chunk.choices.first.delta.thinking;
    final String? text = chunk.choices.first.delta.content;
    if (thinking != null) print('[thinking] $thinking');
    if (text != null) print(text);
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
