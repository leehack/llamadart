# Fine-tune the Laya head for Tetris

[`laya_head_tuning.ipynb`](laya_head_tuning.ipynb) fine-tunes the decision
head of [Laya](https://huggingface.co/convaiinnovations/laya) on Tetris
`choice` questions and writes `laya-head-tetris.safetensors`, the head the
**Laya choice (Tetris-tuned)** player uses. The encoder stays frozen, so the
app keeps its backbone GGUF and only the head changes.

## Prerequisites

- Python 3.12 with these packages, plus Jupyter or another notebook runner.
  From `example/laya_tetris`, where git ignores `.venv/`:

  ```bash
  python3.12 -m venv .venv
  source .venv/bin/activate
  pip install laya==0.3.5 torch==2.14.0 safetensors==0.8.0 \
    transformers==5.17.0 tokenizers==0.23.2 huggingface_hub==1.32.0 \
    numpy==2.5.3
  ```

- Memory: a default run peaked at 11.0 GB on an Apple M4 Max, 5.3 GB of it
  the encoder's hidden states, which the notebook keeps.

The first run downloads the official checkpoint (846 MB) into the Hugging Face
cache.

## Train

From `example/laya_tetris`:

```bash
dart run bin/make_dataset.dart dataset
```

This writes `dataset/train.jsonl` (16,000 questions) and `dataset/val.jsonl`
(2,000, from other games). Each line holds `state` and `q` in Laya's request
format, `target` (the heuristic-best options share probability 1) and `h`
(each option's heuristic value). The generator is seeded, so every run writes
the same files.

Then open `training/laya_head_tuning.ipynb` with the environment above and run
all cells. The first code cell holds the settings, including `OUT_PATH` and
`OUT_DTYPE`: `"F32"` (106 MB) or `"F16"` (53 MB).

With the defaults on an Apple M4 Max (MPS), encoding took 3 to 6 minutes and
the 12 epochs 17 to 24, depending on other load. On the 2,000 validation
questions:

| Head | Runs | Accuracy | Mean regret |
| --- | --- | --- | --- |
| Base (`laya-head.safetensors`) | | 0.305 | 1.621 |
| Tuned, 12 epochs (default) | 8 | 0.755 to 0.785 | 0.157 to 0.242 |
| Tuned, 8 epochs | 10 | 0.705 to 0.780 | 0.214 to 0.388 |

A question counts as right when the head's top option is one of the
heuristic-best options; a random pick scores 0.275. Regret is the heuristic
value lost against the best option.

Training on MPS is not bit-for-bit repeatable, even with the same `SEED`, so
the kept head differs between runs. In some runs the training loss stays near
its starting value for about two epochs before it falls. With 8 epochs too few
steps were left after that, and 2 of 10 runs stopped at 0.705 and 0.707, still
improving. With 12, the two runs whose loss fell latest reached 0.755 and
0.773. The **Train** cell prints the kept head's scores; if its accuracy is
well below 0.75, change `SEED` in the first cell and run all cells again.

## Use the head

- **App:** copy `laya-head-tetris.safetensors` into the app's `laya/` folder
  and relaunch the app; a file there takes precedence over the published head.
  The folder is in the app's cache directory, or on Android in its external
  files directory, which `adb push` can reach. On iOS, host the file and build
  with `--dart-define=LAYA_TUNED_HEAD_URL=<url>` so the app downloads it.
- **Headless:** from `example/laya_tetris`,

  ```bash
  dart run bin/bench.dart --model laya-Q8_0.gguf --head laya-head.safetensors \
    --tuned-head training/laya-head-tetris.safetensors
  ```

- **Your code:** `DecisionEngine.load(engine, headPath: ...)`. The file carries
  Laya's config as `laya.config` metadata, so no `configPath` is needed.

## Backbone GGUF from the official checkpoint

The app downloads its backbones from
[`fr0stbit3/laya-gguf`](https://huggingface.co/fr0stbit3/laya-gguf). To build
them from the official checkpoint instead, save its encoder without the
`encoder.` prefix, next to its config and tokenizer:

```python
import shutil
from pathlib import Path

from huggingface_hub import snapshot_download
from safetensors.torch import load_file, save_file

ckpt = Path(snapshot_download(
    "convaiinnovations/laya",
    revision="1c5edc17a7acd8701df6fc341c0d179f1c62c982",
    allow_patterns=["model.safetensors", "encoder/*", "tokenizer/*"],
))
out = Path("laya-encoder")
out.mkdir(exist_ok=True)
weights = load_file(ckpt / "model.safetensors")
encoder = {k.removeprefix("encoder."): v for k, v in weights.items() if k.startswith("encoder.")}
save_file(encoder, out / "model.safetensors", metadata={"format": "pt"})
shutil.copy(ckpt / "encoder" / "config.json", out)
for name in ("tokenizer.json", "tokenizer_config.json"):
    shutil.copy(ckpt / "tokenizer" / name, out)
```

Then convert it with `convert_hf_to_gguf.py` from llama.cpp `v0.4.1`
(`b29c606e28a01b1bc8c1351026a0fa6e616bf6c4`), the release llamadart's native
runtime is built from, and quantize it with `llama-quantize` from the same
release:

```bash
python llama.cpp/convert_hf_to_gguf.py laya-encoder --outtype f32 \
  --outfile laya-F32.gguf
llama-quantize laya-F32.gguf laya-F16.gguf F16
llama-quantize laya-F32.gguf laya-Q8_0.gguf Q8_0
```

The conversion runs in the environment above. The files are 1.58 GB, 791 MB
and 421 MB; `laya-Q8_0.gguf` has the same tensors as the published
`laya-Q8_0.gguf` and differs only in `general.name`. Pass one to
`bin/bench.dart --model`. The
[decision models guide](https://llamadart.leehack.com/docs/guides/decision-models#accuracy-and-speed)
compares how closely each precision matches Laya.
