# Laya Command Bar

A Flutter app for macOS, iOS, Android and the web with one text field that changes
shape as you type. On every change, a reader picks one of eight intents for
the text: search, task, event, reminder, message, calculate, ask or settings.
When it is confident, the bar shows that intent's controls: time and day chips
for a reminder, a recipient for a message, the result for a calculation, live
switches for a setting. A switch in the header compares four readers:

- **Laya**: the [Laya](https://huggingface.co/convaiinnovations/laya)
  decision model answers one choice question through `DecisionEngine`, with
  a head tuned on command data (`training/`).
- **EmbeddingGemma**: [EmbeddingGemma](https://huggingface.co/google/embeddinggemma-300m)
  embeds the text, and the intent whose closest labelled examples are most
  similar wins (`lib/src/example_bank.dart`). The bank starts from 48 seed
  commands and eight intent descriptions, and every intent you pick joins it
  at once, so a correction changes the next reading without training.
- **Qwen2.5**: [Qwen2.5 1.5B Instruct](https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct)
  reads a prompt that lists the intents and the same 48 seed commands, and
  `LlamaEngine.scoreNextToken` returns the probability of each intent name's
  first token as the reply (`lib/src/llm.dart`). Nothing is generated. Every
  intent you pick joins the prompt's examples.
- **decider**: [decider-2b](https://huggingface.co/Mapika/decider-2b), a
  Qwen3.5 2B model trained to answer typed decision questions, reads the
  same question as Laya with the intents as lettered options, and
  `scoreNextToken` returns the probability of each option letter at the
  answer slot (`lib/src/decider.dart`). It needs no examples and does not
  learn from corrections.

Each reader only picks the intent. Times, days, names and numbers come from
the rule-based parsers in `lib/src/slots.dart`.

## Run

```bash
cd example/laya_command_bar
flutter pub get
flutter run -d macos   # or an iOS or Android device
```

Each reader downloads its model on first use and caches it in a `laya/`
folder: in the app's cache directory, or on Android in its external files
directory.

| Reader | Files | Source |
| --- | --- | --- |
| Laya | `laya-Q8_0.gguf` (421 MB) | [`fr0stbit3/laya-gguf`](https://huggingface.co/fr0stbit3/laya-gguf) at `ce2afdc0a8766af56a29a22dcf4a781e1f5c7d3c` |
| Laya | `laya-head-commands.safetensors` (106 MB), under Apache 2.0 | [`leehack/laya-command-head`](https://huggingface.co/leehack/laya-command-head) at `770c4c21e2185e44bf40075ee22989adc28a3771` |
| EmbeddingGemma | `embeddinggemma-300M-Q8_0.gguf` (334 MB), under the Gemma Terms of Use | [`ggml-org/embeddinggemma-300M-GGUF`](https://huggingface.co/ggml-org/embeddinggemma-300M-GGUF) at `0f741b5a6585bd53aeb15cd1372c56f2a0f65e12` |
| Qwen2.5 | `qwen2.5-1.5b-instruct-q4_k_m.gguf` (1.1 GB), under Apache 2.0 | [`Qwen/Qwen2.5-1.5B-Instruct-GGUF`](https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF) at `91cad51170dc346986eccefdc2dd33a9da36ead9` |
| decider | `decider-2b-q8_0.gguf` (2.0 GB), decider-2b v10, under Apache 2.0 | [`cosetoenor/decider-2b-GGUF`](https://huggingface.co/cosetoenor/decider-2b-GGUF) at `dcc6e5537f922266d1126c15682ac0929517ee33` |

Models run on the best GPU, or on Android on the CPU, where the Tetris
example's prototype found Vulkan slower. Laya and EmbeddingGemma use a
512-token context, as does decider, and Qwen2.5 4,096 tokens for its
instructions.

### Web

In a browser the readers run on the llama.cpp WebGPU bridge. Fetch the
pinned bridge assets into `web/webgpu_bridge/`, then run:

```bash
# From the repository root
WEBGPU_BRIDGE_OUT_DIR=example/laya_command_bar/web/webgpu_bridge \
  ./scripts/fetch_webgpu_bridge_assets.sh
cd example/laya_command_bar
flutter run -d chrome
```

The bridge's worker threads need a cross-origin isolated page:
`web_dev_config.yaml` makes `flutter run` send
`Cross-Origin-Opener-Policy: same-origin` and
`Cross-Origin-Embedder-Policy: credentialless`. `flutter build web` copies
the bridge assets into `build/web`; serve it with those headers, for example
from the repository root:

```bash
python3 tool/testing/serve_static_with_headers.py \
  --directory example/laya_command_bar/build/web --port 8080
```

Differences from the native app:

- The bridge downloads each model itself and keeps it in the browser's Cache
  Storage. The status line shows no byte count while it downloads.
- There is no `laya/` folder: the app always uses the published command
  head, and keeps the label log in `localStorage`.

Type a command, or tap a **Type it** chip to watch one typed a character at a
time. Enter runs the command, Esc clears the bar, and tapping an intent chip
overrides the reader until the bar is cleared. The **Gate** button (the gauge
icon) sets the confidence at which the bar changes shape. Each reader has its
own default gate, because they measure confidence differently: Laya reports
one minus the normalized entropy of its probabilities, EmbeddingGemma and
Qwen2.5 the lead of the top intent over the second, and decider the
probability of the top intent after its fitted temperature, 1.3.

## How it stays responsive

- **Read on every change, never queue.** `IntentRunner` keeps at most one
  read running. Texts typed meanwhile collapse into the latest, which runs
  next, so the bar is never more than one read behind the text, even on a
  slow CPU. The header counts reads and skipped texts.
- **Change shape only when sure.** `IntentGate` shows an intent once a
  reading's confidence reaches the gate: 0.3 for Laya and EmbeddingGemma,
  0.5 for Qwen2.5, 0.6 for decider. All four wait for a second word,
  because they are confident about fragments such as `rem`. A weaker reading
  keeps the shown intent
  while that intent stays on top or keeps 0.25 probability, so the bar does
  not flicker between keystrokes. Below the gate the bar stays a plain text
  field, and the chips show the reader's probabilities.
- **Reads off the UI thread.** All readers run on the llama.cpp worker
  isolate. Parsing and animation stay on the UI isolate.
- **Warm start.** Each reader runs once while loading, so the first typed
  text does not pay for GPU pipeline setup.
- **Evaluate only what changed.** The Qwen2.5 prompt puts the typed text
  last, and `scoreNextToken` reuses the cached prefix it shares with the
  previous read, so a read evaluates the text, not the instructions. Hybrid
  models with recurrent layers, such as Qwen3.5, cannot drop part of their
  cache and evaluate the whole prompt on every read: Qwen3.5 0.8B took 83 ms
  per read here, Qwen2.5 1.5B 20 ms. decider is a Qwen3.5 model too, so it
  keeps its prompt short, with the typed text first.

## Accuracy

`bin/bench.dart` scores a reader on 48 development commands, which chose the
gates, and 32 held-out commands, which did not. A command is good when the
bar shows its intent, or stays plain for a question; wrong when the bar shows
another intent; and a miss when the bar stays plain for a command. On an
Apple M4 Max with Metal:

| Reader | Development: good, wrong, miss | Held-out: good, wrong, miss | Typed commands ending in the right shape | Time per read, median |
| --- | --- | --- | --- | --- |
| Laya, command-tuned head | 45, 1, 2 | 26, 4, 2 | 8 of 8 | 14.9 ms |
| EmbeddingGemma | 47, 1, 0 | 29, 3, 0 | 8 of 8 | 5.0 ms |
| Qwen2.5 1.5B Instruct, Q4_K_M | 46, 2, 0 | 28, 2, 2 | 8 of 8 | 19.6 ms |
| Qwen3 4B, Q4_K_M | 48, 0, 0 | 30, 2, 0 | 8 of 8 | 41.5 ms |
| decider-2b v10, Q8_0 | 46, 0, 2 | 27, 0, 5 | 7 of 8 | 49.2 ms |

EmbeddingGemma is the smallest and fastest reader, and a command it gets
wrong is fixed by picking the right intent once. An LLM reads more of the
command's meaning, so a larger one is the most accurate reader here, at a
few times the size and read time; Qwen3 4B is not in the app, but
`bench.dart --reader llm` scores any instruction-tuned GGUF. LLM readings
are overconfident: Qwen2.5's wrong readings still had a lead of 0.95 or more.
Laya's tuned head is the least accurate on held-out commands. decider is
the only reader with no wrong shape on either set, with no examples in its
prompt, because its confidence is calibrated: its five wrong top intents all
stayed under the gate. It reads `remind me to call mom` as a task (0.73), so
that typed command ends as a task.

Each run command is appended to `labels.jsonl` in the `laya/` folder with the
intent it ran as, the reader that was selected (`reader`), that reader's top
intent and confidence (`reader_top`, `reader_confidence`), and whether you
picked the intent (`"source": "picked"`) or the reader did
(`"source": "reader"`). Picked rows are corrections: EmbeddingGemma adds them
to its bank and Qwen2.5 to its examples when they load, and they are usable
as training labels.

## Benchmark

The benchmark uses local files and no downloads:

```bash
dart run bin/bench.dart --reader laya --model laya-Q8_0.gguf --head laya-head-commands.safetensors
dart run bin/bench.dart --reader embedding --embedding-model embeddinggemma-300M-Q8_0.gguf
dart run bin/bench.dart --reader llm --llm-model qwen2.5-1.5b-instruct-q4_k_m.gguf
dart run bin/bench.dart --reader decider --decider-model decider-2b-q8_0.gguf
```

It prints both scores, the intent the bar shows after each typing pause of
eight commands, and the read time. `--enter` sets the gate, `--cpu` runs on
the CPU, and `--verbose` prints every command.

## Test

```bash
flutter test
```
