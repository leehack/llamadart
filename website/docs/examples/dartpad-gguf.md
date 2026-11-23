---
title: DartPad GGUF example
sidebar_label: DartPad GGUF
description: Download a small GGUF and stream text in a Flutter DartPad preview without cross-origin isolation.
---

[Open in DartPad](https://dartpad.dev/?package=llamadart&root=example/dartpad_gguf&file=example/dartpad_gguf/lib/main.dart)
with llamadart 0.20.7 or later. Run the preview, choose a model, then select
**Load** and **Run**. **Stop** cancels the current generation.

| Preset | Download | API |
| --- | --- | --- |
| Stories15M Q8_0 | 39.4 MB | Continue a prompt with `LlamaEngine.generate`. |
| SmolLM2 135M Instruct Q4_K_M | 105.5 MB | Answer a single chat turn with `LlamaEngine.create`. |

DartPad runs the app in a non-isolated iframe. The example opts into the
[single-thread GGUF core](../platforms/webgpu-bridge#single-threaded-gguf-without-isolation)
and imports the pinned bridge module from Dart. All bridge URLs are absolute
so the browser can resolve them from the iframe. After loading, the app
reports the backend, Wasm core variant, execution mode, and threading.
Inference runs in the browser. The bridge can use a compatible WebGPU
adapter for GPU offload.

For the source and local Chrome instructions, see
[`example/dartpad_gguf`](https://github.com/leehack/llamadart/tree/main/example/dartpad_gguf).
