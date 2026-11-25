---
title: Model compatibility
sidebar_label: Model compatibility
description: How llamadart recognizes model families from chat templates, what CI template tests vs runtime qualification prove, and format-specific exceptions.
---

`llamadart` has no model allowlist. Any GGUF that the pinned `llama.cpp` runtime
can load will generate text. What varies by family is how chat messages, tool
calls and reasoning are formatted and parsed, and that follows from the
model's chat template rather than a hardcoded model list.

## How a family is recognized

- **GGUF:** `llamadart` reads the chat template embedded in the file
  (`tokenizer.chat_template`, or `tokenizer.chat_template.tool_use` when tools
  are passed) and detects its format from marker strings, in `llama.cpp`'s
  priority order. It does not look at the model name or architecture.
- **`.litertlm`:** `llamadart` picks a template from the file name (`gemma-4`,
  `gemma-3n`, `gemma-3`/`gemma-2`, `qwen3` or `qwen2.5`) for format detection
  and output parsing. Set `ModelParams.chatTemplate` to override it. On
  native LiteRT-LM, `getMetadata()` reports the template the runtime renders
  as `tokenizer.chat_template`, and the parsing template, when it differs, as
  `llamadart.chat_template.parsing`. A bundle with no matching family and no
  override reports no template.
- **No match:** the template renders as-is, with no tool-call or reasoning
  parsing. If you pass tools, `llamadart` adds a generic JSON tool-call
  instruction instead.

To inspect what a loaded model will receive and which format was detected, call
`engine.chatTemplate(...)` and check `await engine.capabilities`; see
[Chat templates and output parsing](../guides/chat-template-and-parsing) and
[Checking the loaded runtime](../guides/backend-selection#checking-the-loaded-runtime).
For native `.litertlm`, the prompt comes from the template the runtime renders
for text-only requests: the file-name template for Qwen3 bundles, and the
bundle's embedded template for the others, such as Qwen3.5 and Gemma. Dart
renders it, so it shows what that template produces, not the runtime's exact
bytes; requests with media always use the embedded template. The other result
fields, such as `format`, still come from the parsing template.

## Evidence levels

`llamadart` separates template checks from executed runtime qualification:

- **Template-tested (CI):** CI detects and renders published chat templates from
  `llama.cpp`'s template set and real GGUF fixtures, and parses recorded sample
  outputs. This verifies template detection, rendering and parsing in Dart, not
  model execution on a device.
- **Runtime-qualified (run receipt):** Verified by an executed run recorded in
  the [Support matrix](../platforms/support-matrix) and
  [Feature validation evidence](../maintainers/feature-validation) (including
  local/device runs of `packages/llamadart_validation` and platform scenarios).
  Having a validation profile mapping alone is not a qualifying run.

## Chat families

Rather than maintaining an allowlist, the Dart template engine implements
`llama.cpp`'s published chat and tool-call formats (including Gemma 4,
Qwen3-Coder XML, Hermes, FunctionGemma, Llama 3, Ministral, DeepSeek, GLM,
Granite, LFM2, GPT-OSS, and others; see
[Template engine internals](../guides/template-engine-internals)).

For a compact onboarding example, `Qwen3.5-0.8B` GGUF
(`hf://unsloth/Qwen3.5-0.8B-GGUF/Qwen3.5-0.8B-Q4_K_M.gguf`) uses the
Qwen3-Coder XML format and is used in the
[Basic app example](../examples/basic-app). For runnable chat presets across
GGUF and `.litertlm`, see the [Chat app example](../examples/chat-app).

Key format-specific behavior and exceptions:

- **Generic JSON fallback:** When a selected template has no recognized native
  tool-call format (for example, Gemma 2/3/3n, Phi-3.5, or SmolLM3),
  `llamadart` asks the model to answer with a `tool_call` or `response` JSON
  object and parses that. This is an intentional extension to `llama.cpp`, not
  evidence of native tool support or reliable tool selection; templates can
  omit tool definitions even when a grammar constrains the output. See
  [Generic JSON fallback](../guides/tool-calling#generic-json-fallback).
- **Reasoning markers:** Where a format defines reasoning markers, such as
  `<think>`, Gemma 4's thought channel, or Mistral's `[THINK]`, the parser
  returns reasoning separately from the reply. See
  [Text generation and streaming](../guides/generation-and-streaming).
- **Qwen3.5 `.litertlm` bundles:** These bundles render their own embedded chat
  template ([#1134](https://github.com/leehack/llamadart/issues/1134)), so
  `ModelParams.chatTemplate` is ignored for them. The `Qwen3.5-0.8B_int8`,
  `Qwen3.5-0.8B-VL_int8` and `Qwen3.5-0.8B_int8_gpu_composite_v0190` bundles
  (LiteRT-LM 0.19 and earlier) close an empty `<think>` block in the generation
  prompt and never read `enable_thinking`, so `enableThinking: true` produces
  no reasoning there. The `Qwen3.5-0.8B_dynamic_wi8_afp32` bundle reads
  `enable_thinking` but needs LiteRT-LM 0.20.0 or later, so it fails on the
  pinned 0.19.1 runtime. Use GGUF for Qwen3.5 thinking; Qwen3 and Gemma 4
  `.litertlm` bundles support thinking.

## Vision and audio

GGUF vision and audio models require a matching projector (`mmproj`) file loaded
alongside the text GGUF. `.litertlm` multimodal bundles package and process
media inputs internally. See [Multimodal input](../guides/multimodal) and the
[Chat app example](../examples/chat-app).

## Speech, embeddings and decision models

Specialized engines and task formats live in their own guides, with runnable
demos in [Basic app](../examples/basic-app) and [Chat app](../examples/chat-app),
and scoped platform receipts in the
[Support matrix](../platforms/support-matrix) and
[Feature validation evidence](../maintainers/feature-validation):

- **Speech to text:** [Speech to text](../guides/speech-to-text) (GGUF
  `Qwen3-ASR`, `llama.cpp` multimodal PCM streaming, and `.litertlm` ASR
  adapters).
- **Text to speech:** [Text to speech](../guides/text-to-speech) (GGUF and
  companion/ONNX setups per TTS adapter).
- **Embeddings:** [Embeddings](../guides/embeddings) (`LlamaEngine` text
  embeddings with GGUF, and LiteRT-LM CPU multimodal embeddings with `.litertlm`).
- **Decision models:** [Decision models](../guides/decision-models)
  (`DecisionEngine` pairing a GGUF backbone with a `.safetensors` head).
- **Image generation (Preview):** [Image generation](../guides/image-generation)
  (`ImageGenerationEngine` loading compatible GGUF, `.safetensors`, and
  explicit-role `.ckpt`/`.pth`/`.pt` weights — separate from `LlamaEngine`).

## If a family behaves oddly

1. Render the prompt with `engine.chatTemplate(...)` and compare it with the
   model card.
2. Check which format was detected: `ChatTemplateEngine.detectFormat(template)`.
3. Inspect `await engine.capabilities`, and check the
   [Support matrix](../platforms/support-matrix) and
   [Feature validation evidence](../maintainers/feature-validation) for
   runtime-qualified combinations before debugging your own prompts.
4. Report the model repo and file in a
   [GitHub issue](https://github.com/leehack/llamadart/issues).
