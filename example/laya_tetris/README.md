# Laya Tetris

A Flutter app for macOS, iOS, Android and Web in which the
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
`ce2afdc0a8766af56a29a22dcf4a781e1f5c7d3c`, and the Tetris-tuned head
`laya-head-tetris.safetensors` (106 MB) from
[`leehack/laya-tetris-head`](https://huggingface.co/leehack/laya-tetris-head)
at revision `465546a595ee2e8e3b212b8cb16829205d5dfab6`, and shows the
progress. Files are cached in a `laya/` folder, and later launches load them
from there. The folder is in the app's cache directory, which iOS leaves out
of backups and may clear when storage runs low (the app then downloads again),
or on Android in the app's external files directory
(`Android/data/com.example.laya_tetris_example/files/laya`).
The **Backbone** picker also offers `laya-F16.gguf` (791 MB), downloaded when
first selected.

One `LlamaEngine` holds the backbone (`ModelParams(contextSize: 512)`); the
base head and the Tetris-tuned head are two `DecisionEngine`s on it.

## Web

In a browser the app runs on the llama.cpp WebGPU bridge; see
[Decision Models: Web](https://llamadart.leehack.com/docs/guides/decision-models#web).
Live demo: https://leehack-flutter-laya-tetris.static.hf.space, deployed
from `main` by `.github/workflows/laya_tetris_hf_static_deploy.yml`.

Fetch the pinned bridge assets into `web/webgpu_bridge/`, then run:

```bash
# From the repository root
WEBGPU_BRIDGE_OUT_DIR=example/laya_tetris/web/webgpu_bridge \
  ./scripts/fetch_webgpu_bridge_assets.sh
cd example/laya_tetris
flutter run -d chrome
```

The bridge's worker threads need a cross-origin isolated page:
`web_dev_config.yaml` makes `flutter run` send
`Cross-Origin-Opener-Policy: same-origin` and
`Cross-Origin-Embedder-Policy: credentialless`; the deployed Space uses
`require-corp`, which Safari also supports. `flutter build web` copies the
bridge assets into `build/web`; serve it with those headers, for example from
the repository root:

```bash
python3 tool/testing/serve_static_with_headers.py \
  --directory example/laya_tetris/build/web --port 8080
```

Differences from the native app:

- The bridge downloads the files itself and keeps the backbone in the
  browser's Cache Storage, so a reload skips that download. There is no
  `laya/` folder: for a tuned head of your own, pass
  `--dart-define=LAYA_TUNED_HEAD_URL=<url>` with a URL that allows
  cross-origin requests.
- **CPU threads** stops at the bridge's thread pool: up to 4, or 1 on a page
  that is not cross-origin isolated. **Benchmark** skips the larger counts.

Checked in Chromium on an Apple M4 Max: the Q8_0 backbone and both heads
loaded on WebGPU in 43 s, or 17 s with the backbone cached. **Benchmark**
measured 81 ms per six-option choice on WebGPU and 2.4 s on 4 CPU threads, so
keep **Compute** on the GPU. The yes/no checklist over all legal moves took
2.6 s per piece at level 1, and no piece locked before Laya answered. Safari
and Firefox are untested.

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

The published tuned head is the base head fine-tuned on the heuristic-labelled
choice examples that `bin/make_dataset.dart` writes, with the recipe of the
notebook in [`training/`](training/README.md).
The app loads the first tuned head it finds:

1. The URL from `--dart-define=LAYA_TUNED_HEAD_URL=<url>`.
2. `laya-head-tetris.safetensors` in the app's `laya/` folder, such as a
   fine-tune of your own. The app looks for it at launch and whenever it
   reloads the models. On iOS the folder is inside the app sandbox, so use the
   URL.
3. The published head.

If the tuned head fails to load, for example because its download failed, the
app shows the error, how to recover, and a **Reload models** button, and the
tuned player is disabled.

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
