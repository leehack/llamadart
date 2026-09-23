# llamadart CLI Chat Example

A clean, organized CLI application demonstrating the capabilities of the `llamadart` package. It supports both interactive conversation mode and single-response mode.

## Features

- **Interactive Mode**: Have a back-and-forth conversation with an LLM in your terminal.
- **Single Response Mode**: Pass a prompt as an argument for quick tasks.
- **Automatic Model Management**: Accepts local paths, HTTP(S) URLs, and `hf://` Hugging Face model sources, then resolves remote sources through the package-managed cache.
- **Platform Cache Defaults**: Remote model URLs use `DefaultModelDownloadManager`, so desktop/server runs share the per-user `llamadart` model cache while explicit local paths are loaded directly.
- **Backend Optimization**: Defaults to GPU acceleration (Metal/Vulkan) when available.
- **LoRA Adapters**: Load one or more LoRA adapters with repeated `--lora` flags.
- **Structured Output**: Pass `--grammar` for GBNF-constrained generation.
- **Tool Calling Test Mode**: Enable `--tool-test` to exercise function-calling flow.
- **Sampling Controls**: Tune `--temp`, `--top-k`, `--top-p`, and `--penalty`.
- **Embedding Demo**: Includes a dedicated embedding CLI example.
- **SQLite Vector Demo**: Stores embeddings in SQLite and runs nearest-neighbor search with `sqlite_vector`.
- **Decision Model Demo**: Triages a support ticket with a Laya decision model through `DecisionEngine`.

## Usage

First, ensure you have the Dart SDK installed.

### 1. Install Dependencies

```bash
dart pub get
```

### 2. Run Interactive Mode (Default)

This uses a default Hugging Face source, downloads it on first run, and reuses
the package-managed cache on later runs.

```bash
dart run
```

Default model source:

```text
hf://unsloth/Qwen3.5-0.8B-GGUF/Qwen3.5-0.8B-Q4_K_M.gguf
```

### 3. Run with a Specific Model

You can provide a local path, an HTTP(S) URL, or an `hf://` Hugging Face source.

```bash
dart run bin/llamadart_basic_example.dart \
  -m "hf://unsloth/SmolLM2-135M-Instruct-GGUF/SmolLM2-135M-Instruct-Q2_K.gguf"
dart run bin/llamadart_basic_example.dart -m "path/to/model.gguf"
```

### 4. Single Response Mode

Useful for scripting or quick queries.

```bash
dart run bin/llamadart_basic_example.dart \
  -p "What is the capital of France?"
```

### 5. Embedding Example

Generate one or more embedding vectors from text input.

By default, embedding CLIs use
`ggml-org/embeddinggemma-300M-GGUF` (`embeddinggemma-300M-Q8_0.gguf`). Use
`--model` to point to a different embedding GGUF.

```bash
dart run bin/llamadart_embedding_example.dart -i "hello world" -i "rag"
```

For quick retrieval-style experiments, pass a query first and candidate strings
after it:

```bash
dart run bin/llamadart_embedding_example.dart \
  -i "how do I improve embedding throughput?" \
  -i "Increase maxParallelSequences for wider embedding batches." \
  -i "Tune batchSize and ubatchSize together."
```

For closer `llama.cpp` parity, force CPU and align runtime knobs:

```bash
dart run bin/llamadart_embedding_example.dart \
  --cpu --ctx-size 2048 --threads 12 --threads-batch 12 \
  --batch-size 2048 --ubatch-size 2048 --max-seq 2 \
  -i "hello world" -i "semantic search"
```

The embedding CLI prints runtime backend, dimensions, and a value preview for
each input vector.

Embedding CLI flags (`bin/llamadart_embedding_example.dart`):

- `-m, --model`: Path or URL to GGUF model.
- `-i, --input`: Input text (repeat for batch embedding).
- `--[no-]normalize`: Toggle L2 normalization.
- `--cpu`: Force CPU backend.
- `--ctx-size`: Context size.
- `--threads`: Decode threads.
- `--threads-batch`: Batch threads.
- `--batch-size`: `n_batch` override.
- `--ubatch-size`: `n_ubatch` override.
- `--max-seq`: `n_seq_max` override for parallel embedding slots.

### 6. SQLite Vector Search Example

Run a complete local retrieval flow: generate embeddings with `llamadart`,
store them in SQLite as vectors, and query nearest matches with
`sqlite_vector`.

```bash
dart run bin/llamadart_sqlite_vector_example.dart \
  -q "How do I improve embedding throughput?" \
  -d "Increase maxParallelSequences for wider embedding batches." \
  -d "Tune batchSize and ubatchSize together." \
  -d "Use benchmark sweeps to compare sequential and batch throughput."
```

SQLite vector CLI highlights (`bin/llamadart_sqlite_vector_example.dart`):

- Auto-loads SQLite vector extension (`sqlite_vector`).
- Creates a `documents` table with an `embedding` BLOB column.
- Initializes vector search with `vector_init(...)`.
- Supports exact `vector_full_scan(...)` and optional quantized ANN mode via
  `--quantized` (`vector_quantize_scan(...)`).
- Prints both raw distance and translated similarity/relevance labels.
- Supports `--db <path>` to persist the database instead of using memory.

Quantized mode example:

```bash
dart run bin/llamadart_sqlite_vector_example.dart \
  --quantized --top-k 5 \
  -q "How do I improve embedding throughput?" \
  -d "Increase maxParallelSequences for wider embedding batches." \
  -d "Tune batchSize and ubatchSize together."
```

Quantized quality-check example (compare ANN vs exact recall):

```bash
dart run bin/llamadart_sqlite_vector_example.dart \
  --quantized --compare-exact --quantized-qtype INT8 \
  --quantized-max-memory 64MB --top-k 5 --min-similarity 0.45 \
  -q "How do I improve embedding throughput?" \
  -d "Increase maxParallelSequences for wider embedding batches." \
  -d "Tune batchSize and ubatchSize together."
```

How to translate result values:

- Lower `distance` is always better.
- With default `--normalize` (COSINE metric), similarity is approximately
  `1 - distance` (clamped to `[-1, 1]`).
- Without normalization (`L2` metric), similarity is shown as
  `1 / (1 + distance)` for quick intuition.
- `relevance` buckets (`very-high`, `high`, `medium`, `low`, `very-low`) are
  convenience labels derived from similarity.
- `--min-similarity` filters low-confidence rows from printed output.
- `--compare-exact` prints `recall@k` and distance deltas for quantized vs exact
  search quality.
- `--quantized-qtype` (`UINT8`, `INT8`, `1BIT`) and
  `--quantized-max-memory` tune quantization behavior.

### 7. Decision Model Example

Triage a support ticket with a Laya decision model: a `department` choice, an
`urgency` score and a `refund` yes/no question, answered by `DecisionEngine`
without generating text. The questions are typed keys (`ChoiceKey.enumOf` over
a `Department` enum, `ScoreKey.of` and `NoulKey.of`), and each answer is read
with `result.answerOf(key)`. See the
[Decision Models guide](https://llamadart.leehack.com/docs/guides/decision-models)
for the API.

```bash
dart run bin/llamadart_decision_example.dart
```

On first run it downloads `laya-Q8_0.gguf` (421 MB) and
`laya-head.safetensors` (106 MB) from `fr0stbit3/laya-gguf` at revision
`ce2afdc0a8766af56a29a22dcf4a781e1f5c7d3c` into the package-managed cache, and
reuses them on later runs.
Each answer is printed with its `confidence` and `actProbability`; `--json`
adds Laya's `{model, answers, usage}` response.

```bash
dart run bin/llamadart_decision_example.dart --json \
  --state "The app crashes on login since the last update."
dart run bin/llamadart_decision_example.dart \
  --state '{"from": "ops@globex.io", "body": "Checkout returns 503."}'
```

`laya-Q8_0.gguf` can change decisions compared with Laya; see the guide's
[accuracy section](https://llamadart.leehack.com/docs/guides/decision-models#accuracy-and-speed).
To use the official
[`convaiinnovations/laya`](https://huggingface.co/convaiinnovations/laya)
checkpoint as the head, pass its config too:

```bash
dart run bin/llamadart_decision_example.dart \
  --head path/to/model.safetensors \
  --config path/to/rl_agent_config.json
```

Decision CLI flags (`bin/llamadart_decision_example.dart`):

- `-m, --model`: Backbone GGUF as a local path, HTTP(S) URL, or `hf://` source.
- `--head`: Decision head safetensors, in the same forms.
- `--config`: `rl_agent_config.json` for a head without `laya.config` metadata.
- `-s, --state`: Ticket to triage: text, or a JSON object or array.
- `--cpu`: Run the backbone and head on the CPU.
- `--threads`: CPU threads for the encoder and head
  (`ModelParams.numberOfThreadsBatch`; `0` keeps the default).
- `--json`: Also print the Laya response JSON.

## Options

- `-m, --model`: Local path, HTTP(S) URL, or `hf://` Hugging Face source for a GGUF model.
- `-l, --lora`: Path to LoRA adapter(s). Can be set multiple times.
- `-p, --prompt`: Prompt for single response mode.
- `-i, --interactive`: Start in interactive mode (default if no prompt provided).
- `-g, --log`: Enable native engine logging output (defaults to off).
- `-G, --grammar`: GBNF grammar string for constrained output.
- `-t, --tool-test`: Enables sample `get_weather` tool-calling flow.
- `--temp`: Temperature (default `0.7`).
- `--top-k`: Top-k sampling (default `20`).
- `--top-p`: Top-p sampling (default `0.8`).
- `--penalty`: Repeat penalty (default `1.0`).
- `-h, --help`: Show help message.

## Tests

Run the basic app test suite with:

```bash
dart test
```

## Project Structure

- **`bin/llamadart_basic_example.dart`**: The CLI entry point and user interface logic.
- **`bin/llamadart_embedding_example.dart`**: Embedding-only CLI entry point.
- **`bin/llamadart_sqlite_vector_example.dart`**: SQLite vector retrieval CLI example.
- **`bin/llamadart_decision_example.dart`**: Decision model CLI example.
- **`lib/services/decision_cli_options.dart`**: Decision CLI flags and pinned model sources.
- **`lib/services/decision_ticket_triage.dart`**: Typed ticket question keys and answer formatting.
- **`lib/services/llama_service.dart`**: High-level wrapper for the `llamadart` engine.
- **`lib/services/model_service.dart`**: Handles model downloading and path verification.
- **`lib/models.dart`**: Data structures for the application.
