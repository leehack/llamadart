---
title: Laya Command Bar Example
description: A Flutter text field that reshapes as you type, read by a Laya decision model through DecisionEngine, by EmbeddingGemma and labelled examples, or by a small LLM's next-token scores, with a confidence gate and a latest-wins read loop that keep it responsive.
---

Path: `example/laya_command_bar`

A Flutter app for macOS, iOS and Android with one text field that changes
shape as you type. On every change, a reader picks one of eight intents for
the text: search, task, event, reminder, message, calculate, ask or settings.
When it is confident, the bar shows that intent's controls, such as time and
day chips for a reminder, a recipient for a message, or the result of a
calculation. A switch in the header compares three readers:

- **Laya**: a [Laya](https://huggingface.co/convaiinnovations/laya) decision
  model answers one choice question through
  [`DecisionEngine`](../guides/decision-models), with a head tuned on
  command data.
- **EmbeddingGemma**: [EmbeddingGemma](https://huggingface.co/google/embeddinggemma-300m)
  embeds the text through `LlamaEngine.embedBatch`, and the intent whose
  closest labelled examples are most similar wins. Every intent the user
  picks joins the examples at once, so a correction changes the next reading
  without training.
- **Qwen2.5**: [Qwen2.5 1.5B Instruct](https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct)
  reads a prompt listing the intents and labelled examples, and
  [`LlamaEngine.scoreNextToken`](../guides/generation-and-streaming#next-token-scores)
  returns the probability of each intent name's first token as the reply.
  Nothing is generated.

## What it demonstrates

- One typed [`ChoiceKey.enumOf`](../guides/decision-models#typed-questions)
  question per text change, with the text as the state, read back with
  `answerOf` as the chosen intent, its `optionProbabilities` and its
  `confidence`.
- Nearest-example classification with embeddings, as an alternative that
  needs no trained head and learns from corrections as they happen.
- An LLM as a classifier through next-token scores. The typed text comes
  last in the prompt, so each read evaluates only the text after the cached
  instructions.
- A read loop for interactive UI: at most one read runs, and texts typed
  meanwhile collapse into the latest, which runs next. The bar is never more
  than one read behind the text, even when a read is slower than typing.
- A confidence gate with hysteresis: the bar changes shape only when the
  reader is confident, and keeps its shape through weaker readings that still
  favor the shown intent, so it does not flicker between keystrokes.
- A division of labor: the reader picks the intent, and rule-based parsers
  fill in the times, days, people and numbers the controls show.
- A label log of run commands, marking which intents the user picked, as
  training data for a tuned head.

## Run

```bash
cd example/laya_command_bar
flutter pub get
flutter run -d macos   # or an iOS or Android device
```

Each reader downloads its model on first use and caches it in a `laya/`
folder in the app's cache directory, or on Android in the app's external
files directory:

| Reader | Files | Source |
| --- | --- | --- |
| Laya | `laya-Q8_0.gguf` (421 MB) | [`fr0stbit3/laya-gguf`](https://huggingface.co/fr0stbit3/laya-gguf) at `ce2afdc0a8766af56a29a22dcf4a781e1f5c7d3c` |
| Laya | `laya-head-commands.safetensors` (106 MB), under Apache 2.0 | [`leehack/laya-command-head`](https://huggingface.co/leehack/laya-command-head) at `770c4c21e2185e44bf40075ee22989adc28a3771` |
| EmbeddingGemma | `embeddinggemma-300M-Q8_0.gguf` (334 MB), under the Gemma Terms of Use | [`ggml-org/embeddinggemma-300M-GGUF`](https://huggingface.co/ggml-org/embeddinggemma-300M-GGUF) at `0f741b5a6585bd53aeb15cd1372c56f2a0f65e12` |
| Qwen2.5 | `qwen2.5-1.5b-instruct-q4_k_m.gguf` (1.1 GB), under Apache 2.0 | [`Qwen/Qwen2.5-1.5B-Instruct-GGUF`](https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF) at `91cad51170dc346986eccefdc2dd33a9da36ead9` |

Models run on the best GPU, or on Android on the CPU. The platform projects match the [Laya Tetris example](./laya-tetris):
iOS `16.4`, macOS `14.0` with the network client entitlement, and Android 10
(API 29) or newer with extracted native libraries.

Type a command, or tap a **Type it** chip to watch one typed a character at a
time. Enter runs the command, Esc clears the bar, and tapping an intent chip
overrides the reader until the bar is cleared. The **Gate** button sets the
confidence at which the bar changes shape: 0.3 by default for Laya and
EmbeddingGemma, and 0.5 for Qwen2.5. Laya's confidence is one minus the
normalized entropy of its probabilities; the others report the lead of the
top intent over the second. Settings commands change the app itself: dark mode and large text
apply at once.

## Accuracy and speed

`bin/bench.dart` scores a reader on 48 development commands, which chose the
gates, 32 held-out commands, which did not, and eight commands typed one
prefix at a time. A command is good when the bar shows its intent, or stays
plain for a question; wrong when it shows another intent; and a miss when it
stays plain for a command. On an Apple M4 Max with Metal:

| Reader | Development: good, wrong, miss | Held-out: good, wrong, miss | Typed commands ending in the right shape | Time per read, median |
| --- | --- | --- | --- | --- |
| Laya, command-tuned head | 45, 1, 2 | 26, 4, 2 | 8 of 8 | 14.9 ms |
| EmbeddingGemma | 47, 1, 0 | 29, 3, 0 | 8 of 8 | 5.0 ms |
| Qwen2.5 1.5B Instruct, Q4_K_M | 46, 2, 0 | 28, 2, 2 | 8 of 8 | 19.6 ms |
| Qwen3 4B, Q4_K_M | 48, 0, 0 | 30, 2, 0 | 8 of 8 | 41.5 ms |

EmbeddingGemma is the smallest and fastest reader, and a wrong reading can be
fixed by picking the right intent once. A larger LLM is the most accurate
reader here, at a few times the size and read time; Qwen3 4B is not in the
app, but `bench.dart --reader llm` scores any instruction-tuned GGUF. Hybrid
models with recurrent layers, such as Qwen3.5, cannot reuse part of their
cache and evaluate the whole prompt on every read: Qwen3.5 0.8B took 83 ms
per read.

```bash
dart run bin/bench.dart --reader laya --model laya-Q8_0.gguf --head laya-head-commands.safetensors
dart run bin/bench.dart --reader embedding --embedding-model embeddinggemma-300M-Q8_0.gguf
dart run bin/bench.dart --reader llm --llm-model qwen2.5-1.5b-instruct-q4_k_m.gguf
```

`--enter` sets the gate, `--cpu` runs on the CPU, and `--verbose` prints every
command.

## Test

```bash
cd example/laya_command_bar
flutter test
```

The tests cover the gate, the read loop (one read at a time, latest text
next, cleared text dropped), the parsers, the example bank against a fake
embedder, the LLM reader against a fake scorer, reader loading and retry, the label log, and the page against fake
readers: the bar stays plain while the reader is unsure, takes an intent's
shape when it is sure, runs commands on Enter, applies a picked setting,
teaches a picked intent to the readers, switches readers, and keeps the caret
at the end of the text after an intent chip is tapped.
