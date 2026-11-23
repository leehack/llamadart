---
title: Basic app example
sidebar_label: Basic app
description: Minimal Dart console apps for chat, embeddings, SQLite vector retrieval, decision models and image generation, the quickest way to see the core llamadart API.
---

Path: `example/basic_app` · Platforms: Dart console on macOS, Linux and
Windows · First-run download: `Qwen3.5-0.8B-Q4_K_M.gguf` (533 MB)

Dart console apps that show the core API: chat, embeddings, vector retrieval,
decision models and image generation, without Flutter.

## Run

```bash
cd example/basic_app
dart pub get
dart run
```

Variants:

```bash
# Embeddings (downloads embeddinggemma-300M-Q8_0.gguf, 334 MB)
dart run bin/llamadart_embedding_example.dart -i "hello world" -i "rag"

# Retrieval: embeddings stored and searched in SQLite with sqlite_vector
dart run bin/llamadart_sqlite_vector_example.dart \
  -q "How do I improve embedding throughput?" \
  -d "Increase maxParallelSequences for wider embedding batches." \
  -d "Tune batchSize and ubatchSize together."

# Decision model: triage a support ticket
# (downloads laya-Q8_0.gguf, 421 MB, and laya-head.safetensors, 106 MB)
dart run bin/llamadart_decision_example.dart

# Image generation: write a PNG with SDXS (downloads the stable_diffusion
# runtime and the pinned sdxs-512-tinySDdistilled_Q8_0.gguf, 683 MB);
# Ctrl-C cancels
dart run bin/llamadart_image_example.dart -p "a red fox in autumn leaves"
```

For LiteRT-LM media embeddings on CPU, first add `litert_lm` to
`llamadart_native_runtimes` in `example/basic_app/pubspec.yaml` (the example's
checked-in list omits `litert_lm` so GGUF and image runs skip downloading it;
`all` also keeps all three):

```yaml
hooks:
  user_defines:
    llamadart:
      llamadart_native_runtimes: [llama_cpp, litert_lm, stable_diffusion]
```

Then run `dart pub get` and supply an existing compatible `.litertlm` embedding
bundle and local PNG or JPEG (CPU only; macOS arm64, iOS arm64, Android arm64,
Linux x64/arm64, or Windows x64; no automatic model download):

```bash
dart run bin/llamadart_litert_embedding_example.dart model.litertlm image.png
```

## What it demonstrates

- Loading a model from an `hf://` source into the shared cache, streaming a
  chat reply, and disposing the engine
  ([Generation and streaming](../guides/generation-and-streaming)).
- LoRA adapters (`--lora`), GBNF-constrained output (`--grammar`) and a
  sample tool call (`--tool-test`) in the chat CLI
  ([LoRA adapters](../guides/lora-adapters),
  [Tool calling](../guides/tool-calling)).
- Single and batched embeddings, query-versus-candidate probes, and ordered
  text/image embeddings through a compatible LiteRT-LM CPU embedding engine
  ([Embeddings](../guides/embeddings)).
- Local retrieval with SQLite vector search, exact or quantized, with a
  recall check against exact search ([Embeddings](../guides/embeddings)).
- Typed choice, score and yes/no answers from a decision model with
  `ChoiceKey.enumOf`, `ScoreKey.of`, `NoulKey.of` and `answerOf`
  ([Decision models](../guides/decision-models#typed-questions)).
- Experimental image generation with SDXS, SD-Turbo, or the desktop
  models (SDXL-Lightning, FLUX.1-schnell, SD 3.5 Large Turbo, Z-Image-Turbo)
  from the example's pinned downloads and settings: file and phase progress,
  Ctrl-C cancellation and PNG output, with the `stable_diffusion` runtime
  opted in through the example's `pubspec.yaml`
  ([Image generation](../guides/image-generation)).

## Image generation presets

Use `--preset <name>` with `bin/llamadart_image_example.dart`. The
[`ImagePreset` source](https://github.com/leehack/llamadart/blob/main/example/basic_app/lib/services/image_cli_options.dart)
owns the pinned files, component overrides and request defaults. All six
presets use guidance 1.

| Preset | Task and default settings | Components |
| --- | --- | --- |
| `sdxs` | Small phone or desktop run, 512x512, one step | SDXS-512 checkpoint with its own decoder (683 MB) |
| `sd-turbo` | Phone or desktop run, 512x512, one step by default, up to four | SD-Turbo checkpoint (2.0 GB). Use `--taesd default` for the faster tiny decoder (10 MB) to reduce memory on phones |
| `sdxl-lightning` | Desktop, 1024x1024, four Euler steps on the `sgmUniform` schedule | SDXL-Lightning 4-step checkpoint (6.9 GB). Use `--taesd default` for TAESDXL (10 MB) |
| `flux1-schnell` | Desktop, 1024x1024, four steps | Q4_0 transformer, FLUX autoencoder, CLIP-L and T5-XXL (12.3 GB). Use `--taesd default` for TAEF1 |
| `sd35-large-turbo` | Desktop, 1024x1024, four steps | Q4_0 transformer, CLIP-L, CLIP-G, T5-XXL and TAESD3 (10.9 GB). The full VAE is gated |
| `z-image-turbo` | Desktop, 1024x1024, eight steps | Q4_K transformer, Qwen3-4B text encoder and FLUX autoencoder (6.7 GB) |

See [desktop model timings](../maintainers/feature-validation#desktop-model-timings)
for the measured hardware and runtime.

### Model licenses

Check the linked model and component licenses before shipping weights or
using them commercially. Terms vary by file.

| Model | Model license | Other files |
| --- | --- | --- |
| SDXS | CreativeML Open RAIL++-M, per [`concedo/sdxs-512-tinySDdistilled-GGUF`](https://huggingface.co/concedo/sdxs-512-tinySDdistilled-GGUF) and its upstream [`IDKiro/sdxs-512-dreamshaper`](https://huggingface.co/IDKiro/sdxs-512-dreamshaper) | None |
| SD-Turbo | [Stability AI Community License](https://huggingface.co/stabilityai/sd-turbo/blob/main/LICENSE.md), per [`stabilityai/sd-turbo`](https://huggingface.co/stabilityai/sd-turbo), whose card says to see [stability.ai/license](https://stability.ai/license) for commercial use | TAESD: MIT ([`madebyollin/taesd`](https://huggingface.co/madebyollin/taesd)) |
| SDXL-Lightning | [CreativeML Open RAIL++-M](https://huggingface.co/ByteDance/SDXL-Lightning/blob/main/LICENSE.md), per [`ByteDance/SDXL-Lightning`](https://huggingface.co/ByteDance/SDXL-Lightning) | TAESDXL: MIT ([`madebyollin/taesdxl`](https://huggingface.co/madebyollin/taesdxl)) |
| FLUX.1-schnell | Apache 2.0, per [`black-forest-labs/FLUX.1-schnell`](https://huggingface.co/black-forest-labs/FLUX.1-schnell) and [`second-state/FLUX.1-schnell-GGUF`](https://huggingface.co/second-state/FLUX.1-schnell-GGUF), which hosts the preset's `ae` | CLIP-L and T5-XXL from [`second-state/stable-diffusion-3.5-medium-GGUF`](https://huggingface.co/second-state/stable-diffusion-3.5-medium-GGUF): Stability AI Community License; TAEF1: MIT ([`madebyollin/taef1`](https://huggingface.co/madebyollin/taef1)) |
| SD 3.5 Large Turbo | [Stability AI Community License](https://huggingface.co/stabilityai/stable-diffusion-3.5-large-turbo/blob/main/LICENSE.md), per the gated [`stabilityai/stable-diffusion-3.5-large-turbo`](https://huggingface.co/stabilityai/stable-diffusion-3.5-large-turbo), whose card limits free commercial use to organizations or individuals under $1M in total annual revenue and asks those above it for an Enterprise License; [`city96/stable-diffusion-3.5-large-turbo-gguf`](https://huggingface.co/city96/stable-diffusion-3.5-large-turbo-gguf) keeps the original terms | Text encoders from [`second-state/stable-diffusion-3.5-medium-GGUF`](https://huggingface.co/second-state/stable-diffusion-3.5-medium-GGUF): Stability AI Community License; TAESD3: MIT ([`madebyollin/taesd3`](https://huggingface.co/madebyollin/taesd3)) |
| Z-Image-Turbo | Apache 2.0, per [`Tongyi-MAI/Z-Image-Turbo`](https://huggingface.co/Tongyi-MAI/Z-Image-Turbo) and [`leejet/Z-Image-Turbo-GGUF`](https://huggingface.co/leejet/Z-Image-Turbo-GGUF) | Qwen3-4B-Instruct-2507: [Apache 2.0](https://huggingface.co/Qwen/Qwen3-4B-Instruct-2507/blob/main/LICENSE) ([`unsloth/Qwen3-4B-Instruct-2507-GGUF`](https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF)); `ae` as for FLUX.1-schnell |

### Other image model families

For other families supported by the bundled stable-diffusion.cpp, supply
the matching components using the [image model roles](../guides/image-generation#roles).
SD 3.5 Medium and Qwen-Image were tried on desktop-class hardware with these
inputs and request settings:

| Model | Files | Request settings |
| --- | --- | --- |
| SD 3.5 Medium | `sd3.5_medium-Q8_0.gguf` (a checkpoint with its VAE) plus `clip_l`, `clip_g` and `t5xxl` from [`second-state/stable-diffusion-3.5-medium-GGUF`](https://huggingface.co/second-state/stable-diffusion-3.5-medium-GGUF) | 1024x1024, 28 steps, guidance 4.5 |
| Qwen-Image | `Qwen_Image-Q4_0.gguf`, `qwen_image_vae.safetensors`, `Qwen2.5-VL-7B-Instruct.Q4_K_M.gguf` | 1024x1024, 20 steps, guidance 2.5, `flowShift: 3` |

Left unset, `sampler`, `scheduler` and `flowShift` are the runtime's own for
the model: Euler for SD 3.5, FLUX and Z-Image, Euler ancestral with the
discrete schedule for SD 1.x, 2.x and SDXL. `flowShift` applies only to
flow-matching models.

See [other family timings](../maintainers/feature-validation#other-image-family-timings)
for the observed runs.

## Test

```bash
cd example/basic_app
dart test
```

Full options, the retrieval result fields and
the decision-model head options are in the
[example README](https://github.com/leehack/llamadart/tree/main/example/basic_app).
