# llamadart CLI Chat Example

A clean, organized CLI application demonstrating the capabilities of the `llamadart` package. It supports both interactive conversation mode and single-response mode.

## Features

- **Interactive Mode**: Have a back-and-forth conversation with an LLM in your terminal.
- **Single Response Mode**: Pass a prompt as an argument for quick tasks.
- **Automatic Model Management**: Automatically downloads models from Hugging Face if a URL is provided.
- **Platform Cache Defaults**: Remote model URLs use `DefaultModelDownloadManager`, so desktop/server runs share the per-user `llamadart` model cache while explicit local paths are loaded directly.
- **Backend Optimization**: Defaults to GPU acceleration (Metal/Vulkan) when available.
- **LoRA Adapters**: Load one or more LoRA adapters with repeated `--lora` flags.
- **Structured Output**: Pass `--grammar` for GBNF-constrained generation.
- **Tool Calling Test Mode**: Enable `--tool-test` to exercise function-calling flow.
- **Sampling Controls**: Tune `--temp`, `--top-k`, `--top-p`, and `--penalty`.
- **Embedding Demo**: Includes a dedicated embedding CLI example.
- **SQLite Vector Demo**: Stores embeddings in SQLite and runs nearest-neighbor search with `sqlite_vector`.

## Usage

First, ensure you have the Dart SDK installed.

### 1. Install Dependencies

```bash
dart pub get
```

### 2. Run Interactive Mode (Default)

This will download a small default model (Qwen 2.5 0.5B) if not already present and start a chat session.

```bash
dart run
```

### 3. Run with a Specific Model

You can provide a local path or a Hugging Face GGUF URL.

```bash
dart run -- -m "path/to/model.gguf"
```

### 4. Single Response Mode

Useful for scripting or quick queries.

```bash
dart run -- -p "What is the capital of France?"
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

## Options

- `-m, --model`: Path or URL to the GGUF model file.
- `-l, --lora`: Path to LoRA adapter(s). Can be set multiple times.
- `-p, --prompt`: Prompt for single response mode.
- `-i, --interactive`: Start in interactive mode (default if no prompt provided).
- `-g, --log`: Enable native engine logging output (defaults to off).
- `-G, --grammar`: GBNF grammar string for constrained output.
- `-t, --tool-test`: Enables sample `get_weather` tool-calling flow.
- `--temp`: Temperature (default `0.8`).
- `--top-k`: Top-k sampling (default `40`).
- `--top-p`: Top-p sampling (default `0.95`).
- `--penalty`: Repeat penalty (default `1.1`).
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
- **`lib/services/llama_service.dart`**: High-level wrapper for the `llamadart` engine.
- **`lib/services/model_service.dart`**: Handles model downloading and path verification.
- **`lib/models.dart`**: Data structures for the application.
