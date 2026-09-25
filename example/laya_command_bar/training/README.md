# Fine-tune the Laya head for the command bar

[`laya_head_tuning.ipynb`](laya_head_tuning.ipynb) fine-tunes the decision
head of [Laya](https://huggingface.co/convaiinnovations/laya) on the command
bar's intent question and writes `laya-head-commands.safetensors`, the head
the **Laya** reader uses. The encoder stays frozen, so the app keeps its
backbone GGUF and only the head changes. The published head,
[`leehack/laya-command-head`](https://huggingface.co/leehack/laya-command-head),
came from this pipeline.

## Prerequisites

- Python 3.13 with these packages, plus Jupyter or another notebook runner.
  From `example/laya_command_bar`, where git ignores `.venv/`:

  ```bash
  python3.13 -m venv .venv
  source .venv/bin/activate
  pip install laya==0.3.5 torch==2.14.0 safetensors==0.8.0 \
    transformers==5.17.0 tokenizers==0.23.2 huggingface_hub==1.32.0 \
    numpy==2.5.3
  ```

- Optional: an instruction-tuned chat GGUF to generate more commands. The
  published head used Qwen3.8-27B at Q4_K_M.

The first run downloads the official checkpoint (846 MB) into the Hugging Face
cache.

## Build the dataset

From `example/laya_command_bar`, optionally generate commands with a chat
model, then keep only those it labels the same when asked again:

```bash
dart run bin/generate_commands.dart --model chat.gguf --out generated.jsonl
dart run bin/verify_commands.dart --model chat.gguf --in generated.jsonl --out verified.jsonl
```

The generator asks for 20 commands per prompt, 16 prompts per intent, across
a grid of styles and topics, and never returns a development or held-out
command. For the published head it wrote 1,949 commands, and 1,669 passed
the check.

Then write the dataset:

```bash
dart run bin/make_dataset.dart --generated verified.jsonl dataset
```

`dataset/train.jsonl` holds the 48 seed commands, up to 250 template commands
per intent, and the generated ones, minus any that normalize to a command
already in it or in the benchmark: 3,063 rows for the published head.
`val.jsonl` holds the 48 development commands and `test.jsonl` the 32
held-out ones. Each line holds `state` and `q` in Laya's request format, and
a one-hot `target` and `h`. The templates are seeded, so the same generated
file always gives the same dataset. Without `--generated`, the training set
is the seeds and templates alone.

## Train

Open `training/laya_head_tuning.ipynb` with the environment above and run all
cells. The first code cell holds the settings, including `SEEDS`, `OUT_PATH`
and `OUT_DTYPE`: `"F32"` (106 MB) or `"F16"` (53 MB). Each seed keeps its
epoch with the best development accuracy, and the notebook exports the seed
that scores best there. Held-out accuracy is printed but chooses nothing.

With the defaults on an Apple M4 Max (MPS), three seeds of 60 epochs took
about 41 minutes and peaked at 3.9 GB. The published head, seed 0 at epoch
29 of the second of two runs, has 27 of the 32 held-out commands right in
PyTorch; the other seeds' kept heads had up to four fewer. Training on MPS is
not bit-for-bit repeatable, so another run keeps a different head.

## Use the head

- **App:** copy `laya-head-commands.safetensors` into the app's `laya/`
  folder and relaunch the app; a file there takes precedence over the
  published head. The folder is in the app's cache directory, or on Android
  in its external files directory, which `adb push` can reach.
- **Headless:** from `example/laya_command_bar`,

  ```bash
  dart run bin/bench.dart --reader laya --model laya-Q8_0.gguf \
    --head training/laya-head-commands.safetensors
  ```
