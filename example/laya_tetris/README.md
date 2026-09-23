# Laya Tetris

A Flutter app for macOS, iOS and Android in which the
[Laya](https://huggingface.co/convaiinnovations/laya) decision model plays
real-time Tetris through `DecisionEngine`. Gravity keeps falling while Laya
thinks. Decisions run on the llama.cpp worker isolate, so the UI stays
responsive.

## Run

```bash
cd example/laya_tetris
flutter pub get
flutter run -d macos   # or an iOS or Android device
```

On first launch the app downloads `laya-Q8_0.gguf` (421 MB) and
`laya-head.safetensors` (106 MB) from
[`fr0stbit3/laya-gguf`](https://huggingface.co/fr0stbit3/laya-gguf) at revision
`ce2afdc0a8766af56a29a22dcf4a781e1f5c7d3c` and shows the progress. Files are
cached in a `laya/` folder, and later launches load them from there. The
folder is in the app's cache directory, which iOS leaves out of backups and
may clear when storage runs low (the app then downloads again), or on Android
in the app's external files directory
(`Android/data/com.example.laya_tetris_example/files/laya`).
The **Backbone** picker also offers `laya-F16.gguf` (791 MB), downloaded when
first selected.

One `LlamaEngine` holds the backbone (`ModelParams(contextSize: 512)`); the
base head and the Tetris-tuned head are two `DecisionEngine`s on it.

## Players

| Player | Laya questions per piece |
| --- | --- |
| Heuristic bot: Yiyuan Lee's linear evaluation over every landing | none |
| Random candidate | none |
| Laya yes/no checklist: "Does this move clear at least one line?" and "Does this move add any new holes?"; plays the best p(clear) - p(hole) | 2 per candidate |
| Laya yes/no: good move? | 1 per candidate |
| Laya choice (A-F): one choice over up to six candidates, with the board as state | 1 |
| Laya choice (Tetris-tuned): knockout of six-option choices with the tuned head | 1 per group of up to six, per round: 1 for 6 candidates, 7 for 34 |

**Laya considers** sets the candidates: every legal landing, or six of them.
All questions about one piece go to `systemOneBatch` in one call; the knockout
sends one call per round.

Defaults: on Android, CPU with 6 threads and "3 best + 3 random", because the
prototype of this app ran fastest that way on a Pixel 9 Pro, where Vulkan was
slower than the CPU; elsewhere the best GPU, 4 threads and all legal moves.
**CPU threads** sets `numberOfThreadsBatch`, which drives the encoder and the
head on the CPU.
**Benchmark** times one six-option choice on the GPU and at 2, 4, 6 and 8 CPU
threads, each in a fresh engine; the game and the model settings wait until it
finishes.

Keys: left and right or A and D to move, down or S to soft drop, up, W or X to
rotate clockwise, Q or Z to rotate counter-clockwise, Space to hard drop, C or
Shift to hold, Enter to start, P or Esc to pause. On a phone, tap the
on-screen keys.

## Tetris-tuned head

The tuned head is not published. `bin/make_dataset.dart` writes the
heuristic-labelled choice examples it is fine-tuned on:

```bash
dart run bin/make_dataset.dart dataset 16000 2000
```

A notebook that fine-tunes the head on this data is planned
([#604](https://github.com/leehack/llamadart/issues/604)). Save the result as
`laya-head-tetris.safetensors` in the app's `laya/` folder (the app shows the
full path) and tap **Reload models**, or build with
`--dart-define=LAYA_TUNED_HEAD_URL=<url>` to download it. On iOS the folder is
inside the app sandbox, so use the URL. Without a loaded tuned head the tuned
player is disabled.

## Headless runs

`bin/bench.dart` plays games through `DecisionEngine` with local files and no
downloads:

```bash
dart run bin/bench.dart --model laya-Q8_0.gguf --head laya-head.safetensors \
  --tuned-head laya-head-tetris.safetensors            # turn-based table
dart run bin/bench.dart ... --realtime --seeds 2      # wall-clock games
dart run bin/bench.dart ... --speed                   # time per question
```

`--cpu`, `--threads`, `--players`, `--modes`, `--pieces` and `--seeds` narrow
a run; `--help` lists every option.

## Test

```bash
flutter test
LAYA_MODEL_DIR=<folder> flutter test test/laya_models_local_test.dart
```

The second command loads `laya-Q8_0.gguf` and `laya-head.safetensors` from
`<folder>`; without `LAYA_MODEL_DIR` those tests are skipped.
