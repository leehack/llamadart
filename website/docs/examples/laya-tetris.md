---
title: Laya Tetris Example
description: A Flutter app in which a Laya decision model plays real-time Tetris through DecisionEngine, with first-launch model downloads and an optional fine-tuned head.
---

Path: `example/laya_tetris`

A Flutter app for macOS, iOS and Android in which a
[Laya](https://huggingface.co/convaiinnovations/laya) decision model plays
real-time Tetris through [`DecisionEngine`](../guides/decision-models).
Gravity keeps running while Laya decides; a piece that lands first locks where
it falls.

## What it demonstrates

- One `LlamaEngine` holding the backbone GGUF with
  `ModelParams(contextSize: 512)`, shared by two `DecisionEngine`s: the
  published base head and an optional Tetris-tuned head.
- First-launch downloads through the engine's model download manager:
  `loadModelSource` for the backbone and `ensureModel` for the heads, with
  progress in the UI and a cache that later launches reuse.
- Yes/no (`noul`) and `choice` questions sent as one `systemOneBatch` call per
  piece, or per knockout round, from the UI isolate while the llama.cpp worker
  isolate does the work.
- Switching between GPU and CPU, backbones and thread counts at runtime by
  disposing the engine and loading a new one.

## Run

```bash
cd example/laya_tetris
flutter pub get
flutter run -d macos   # or an iOS or Android device
```

On first launch the app downloads `laya-Q8_0.gguf` (421 MB) and
`laya-head.safetensors` (106 MB) from
[`fr0stbit3/laya-gguf`](https://huggingface.co/fr0stbit3/laya-gguf) at
revision `ce2afdc0a8766af56a29a22dcf4a781e1f5c7d3c`. The files are cached in a
`laya/` folder in the app's cache directory, which iOS leaves out of backups
and may clear when storage runs low (the app then downloads again), or on
Android in the app's external files directory. The **Backbone** picker also
offers `laya-F16.gguf` (791 MB), downloaded when first selected.

The Apple projects target iOS `16.4` and macOS `14.0`. The macOS app is
sandboxed with the network client entitlement for the downloads. The Android
app keeps native libraries extracted (`useLegacyPackaging`) so llama.cpp can
load its backend modules, and needs Android 10 (API 29) or newer.

## Players

| Player | Laya questions per piece |
| --- | --- |
| Heuristic bot: Yiyuan Lee's linear evaluation over every landing | none |
| Random candidate | none |
| Laya yes/no checklist: does the move clear a line, does it add a hole; plays the best p(clear) - p(hole) | 2 per candidate |
| Laya yes/no: good move? | 1 per candidate |
| Laya choice (A-F): one choice over up to six candidates, with the board as state | 1 |
| Laya choice (Tetris-tuned): knockout of six-option choices | 1 per group of up to six, per round: 1 for 6 candidates, 7 for 34 |

**Laya considers** sets the candidates: every legal landing, the three best by
heuristic plus three random, the six best, or six random. Android defaults to
CPU, 6 threads and "3 best + 3 random", the fastest setup of the app's
prototype on a Pixel 9 Pro, where Vulkan was slower than the CPU. Other
platforms default to the best GPU, 4 threads and all legal moves.

**Benchmark** times one six-option choice on the best device and at 2, 4, 6
and 8 CPU threads, each in a fresh engine; the game and the model settings
wait until it finishes.

## Tetris-tuned head

The tuned head is not published. `bin/make_dataset.dart` writes the
heuristic-labelled choice examples it is fine-tuned on (`train.jsonl` and
`val.jsonl` in the Laya request format, with target probabilities):

```bash
dart run bin/make_dataset.dart dataset 16000 2000
```

A notebook that fine-tunes the head on this data is planned
([#604](https://github.com/leehack/llamadart/issues/604)). Save the result as
`laya-head-tetris.safetensors` in the app's `laya/` folder, whose full path the
app shows, and tap **Reload models**. Alternatively, build with
`--dart-define=LAYA_TUNED_HEAD_URL=<url>` to download it; on iOS, where the
folder is inside the app sandbox, this is the only way. Without a loaded tuned
head the tuned player is disabled.

## Headless runs

`bin/bench.dart` plays games through `DecisionEngine` with local model files
and no downloads:

```bash
# Turn-based: every player, 150 pieces x 5 seeds
dart run bin/bench.dart --model laya-Q8_0.gguf --head laya-head.safetensors \
  --tuned-head laya-head-tetris.safetensors

# Real-time games on the wall clock
dart run bin/bench.dart ... --realtime --seeds 2 --minutes 3

# Time per question by device and CPU thread count
dart run bin/bench.dart ... --speed
```

`--cpu`, `--threads`, `--players`, `--modes`, `--pieces` and `--seeds` narrow
a run; `--help` lists every option.

## Measured

With `bin/bench.dart` on an Apple M4 Max (16 CPU cores) and the Q8_0
backbone. The tuned rows use a local fine-tune of the head, which is not
published.

Time for one six-option choice (175 tokens), each row in a fresh engine,
over three runs:

| Device | ms per question |
| --- | --- |
| Metal | 20 to 21 |
| CPU, 2 threads | 330 to 336 |
| CPU, 4 threads | 166 to 174 |
| CPU, 6 threads | 114 to 118 |
| CPU, 8 threads | 88 to 111 |

Turn-based games on Metal, means over 5 seeds of up to 150 pieces:

| Player | Candidates | Pieces | Lines | Questions per piece |
| --- | --- | --- | --- | --- |
| Heuristic bot | all | 150 | 56 | 0 |
| Random candidate | 3 best + 3 random | 31 | 1 | 0 |
| Laya yes/no checklist | 3 best + 3 random | 120 | 35 | 11.9 |
| Laya yes/no checklist | all | 83 | 18 | 41.0 |
| Laya yes/no: good move? | 3 best + 3 random | 86 | 18 | 5.9 |
| Laya yes/no: good move? | all | 53 | 6 | 21.3 |
| Laya choice (A-F) | 3 best + 3 random | 33 | 1 | 1 |
| Laya choice (Tetris-tuned) | 3 best + 3 random | 122 | 34 | 1 |
| Laya choice (Tetris-tuned) | all | 134 | 40 | 5 |

The base head asked to choose among six candidates plays about as well as a
random pick. The tuned player asks in the format the tuned head was trained
on; with the base head, that format also plays like a random pick (36 pieces,
1 line), while the tuned head keeps up with the checklist and asks one
question instead of twelve.

Real-time games on Metal from level 1, 60 ms per key, two games each played
until the stack topped out:

| Player | Candidates | Lines per game | Mean think time |
| --- | --- | --- | --- |
| Heuristic bot | all | 127, 161 | 0 ms |
| Laya yes/no checklist | 3 best + 3 random | 17, 50 | 161 ms |
| Laya yes/no checklist | all | 23, 23 | 573 to 677 ms |
| Laya choice (Tetris-tuned) | 3 best + 3 random | 12, 85 | 30 to 31 ms |
| Laya choice (Tetris-tuned) | all | 73, 57 | 101 to 124 ms |

## Test

```bash
cd example/laya_tetris
flutter test
```

The tests cover the game rules (line clears, hold, T-spins, gravity and lock
delay), the move planner, the players against a fake decision function, the
model folder and load settings, and the app's model reloads, benchmark and
tuned-head handling against a fake loader.

`LAYA_MODEL_DIR=<folder> flutter test test/laya_models_local_test.dart` also
loads `laya-Q8_0.gguf` and `laya-head.safetensors` from `<folder>`, and checks
that a tuned head that fails to load leaves the base head working.
