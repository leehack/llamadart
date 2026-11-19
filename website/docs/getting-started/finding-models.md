---
title: Find and choose GGUF and LiteRT-LM models
sidebar_label: Finding models
description: How to choose a model format, quantization, template diagnostic, and capability probe for LlamaEngine, plus where to find runnable app presets.
---

`LlamaEngine` (chat, text generation, embeddings, tool calling and multimodal
input) loads two model artifact formats:

- **GGUF** (`.gguf`), run through `llama.cpp` natively and the WebGPU bridge in
  browsers.
- **`.litertlm`** bundles, run through LiteRT-LM.

`LlamaEngine` cannot load raw PyTorch (`.bin`) or generic `.safetensors` LLM
checkpoints directly; convert them to a quantized GGUF or use a published
`.litertlm` bundle that matches the pinned runtime.

Other `llamadart` engines have their own format rules:

- [`ImageGenerationEngine`](../guides/image-generation#weight-formats-and-layouts)
  (Preview) loads compatible image GGUF and `.safetensors` files directly (and
  explicit-role `.ckpt`/`.pth`/`.pt` checkpoints in bounded recipes).
- [`DecisionEngine`](../guides/decision-models) pairs a GGUF backbone with a
  `.safetensors` decision head.
- [`SpeechToTextEngine`](../guides/speech-to-text) and
  [`TextToSpeechEngine`](../guides/text-to-speech) use GGUF or `.litertlm`
  artifacts depending on the adapter; check each guide for requirements.

Thousands of pre-converted GGUF models are available. LiteRT-LM bundles are
more specialized; use them when your target model is distributed for LiteRT-LM
or when you are intentionally targeting or benchmarking that runtime path.

## Where to find models

The best place to find GGUF models is
**[Hugging Face](https://huggingface.co/models?search=gguf)**. Search for a
model name followed by `gguf` (for example, `Llama-3-8B-Instruct-GGUF`). To
learn more about the GGUF format and quantization:

- [The GGUF format specification](https://github.com/ggml-org/ggml/blob/master/docs/gguf.md)
- [Hugging Face's official GGUF documentation](https://huggingface.co/docs/hub/en/gguf)
- [Quantization in llama.cpp](https://github.com/ggml-org/llama.cpp/wiki/Tensor-Encoding-and-Quantization)

For LiteRT-LM, look for repositories that publish `.litertlm` files and
document LiteRT-LM compatibility. If both GGUF and `.litertlm` variants exist,
see [Choosing llama.cpp or LiteRT-LM](../guides/backend-selection) before
treating them as equivalent artifacts.

## Understanding Quantization

GGUF models usually ship at several quantization levels, denoted by tags like
`Q4_K_M` or `Q8_0`. Quantization reduces weight precision to save memory and
speed up inference, at a small cost to output quality (perplexity):

- **`Q4_K_M`**: The recommended baseline. Balances small file size, fast
  generation, and model quality.
- **`Q5_K_M`**: Slightly larger and slower than `Q4_K_M`, retaining more
  quality when you have RAM to spare.
- **`Q8_0`**: Close to unquantized quality, but requires roughly twice the RAM
  of 4-bit variants.
- **`Q2_K` / `Q3_K`**: Highly compressed for severely memory-constrained
  devices, with noticeable degradation on reasoning and instruction following.

## Recommended constraints per platform

Your target device needs enough **free RAM** (or VRAM for GPU offloading) to
hold the downloaded artifact plus the KV cache/context window and runtime
buffers. Check the file size on Hugging Face alongside your target device's
available memory rather than relying on parameter counts alone.

After loading a model, probe what the active runtime and model actually support
instead of branching on file names or device labels:

- Call `await engine.capabilities` (and `engine.getBackendName()`) to check
  tool calling, vision, thinking budget, and sampling support before exposing
  controls ([Checking the loaded runtime](../guides/backend-selection#checking-the-loaded-runtime)).
- Call `await engine.chatTemplate(...)` to inspect the rendered prompt and
  detected template format ([Model compatibility](./model-families)).
- For memory tuning and context sizing, see
  [Performance tuning](../guides/performance-tuning) and the
  [Support matrix](../platforms/support-matrix).

## Starting points

Start with one small reproducible chat GGUF, then branch out to task guides or
runnable app presets:

- **Small chat onboarding:**
  `hf://unsloth/Qwen3.5-0.8B-GGUF/Qwen3.5-0.8B-Q4_K_M.gguf` (about 533 MB). Used
  by the [Basic app example](../examples/basic-app). Add `mmproj-F16.gguf` from
  the same repository when testing vision. (The [Quickstart](./quickstart) uses
  the 88 MB `SmolLM2-135M-Instruct-Q2_K.gguf` only as a fast pipeline smoke
  test, not to judge model quality.)

Format-specific exceptions and specialist guides:

- **Multimodal GGUF vs `.litertlm`:** GGUF vision/audio models require a
  matching `mmproj` projector file; `.litertlm` multimodal bundles package media
  weights inside the bundle ([Multimodal input](../guides/multimodal)).
- **Other tasks:** [Embeddings](../guides/embeddings),
  [Speech to text](../guides/speech-to-text),
  [Text to speech](../guides/text-to-speech),
  [Decision models](../guides/decision-models), and
  [Image generation](../guides/image-generation).
- **Runnable presets and scoped receipts:** See the
  [Basic app](../examples/basic-app) and [Chat app](../examples/chat-app)
  examples for curated presets, and the
  [Support matrix](../platforms/support-matrix) and
  [Feature validation evidence](../maintainers/feature-validation) for qualified
  combinations.

## Downloading a model

Once you find a model on Hugging Face:

1. Open the **Files and versions** tab of the model repository.
2. Pick a file ending in `.gguf` (for example, `model-q4_k_m.gguf`) or
   `.litertlm`.
3. Pass the exact repository path to
   `ModelSource.parse('hf://owner/repo/path/to/model.gguf')` and load it with
   `LlamaEngine.load(LlamaModel(...))`. Keep the real file extension in the path
   so `LlamaBackend()` can route to the correct runtime.

`ModelSource.path(...)` takes a filesystem path on native targets; on web it is a
URL relative to the document. `llamadart` has no asset loader: to ship a model
as a Flutter asset on native, copy the asset to a file first (for example into
the app support directory) and pass that path.

Revisions, private repositories, `mmproj` projector files and sharded GGUFs:
see [Download and cache models](../guides/model-downloads).
