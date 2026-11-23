---
title: DartPad GGUF example
sidebar_label: DartPad GGUF
description: Download a small GGUF and stream text on preview.dartpad.dev without cross-origin isolation.
---

[Open on preview.dartpad.dev](https://preview.dartpad.dev/?package=llamadart&root=example/dartpad_gguf&file=example/dartpad_gguf/lib/main.dart)
The link always opens the latest published llamadart.
The example is available starting in 0.20.7.

Run the Flutter preview and choose **Load** to download Stories15M MoE Q8_0
(39.4 MB). Select **Generate** to stream a continuation of your prompt.
**Stop** cancels generation and keeps the text already received.

DartPad Preview runs the app in a non-isolated iframe. The example opts into the
[single-thread GGUF core](../platforms/webgpu-bridge#single-threaded-gguf-without-isolation)
and imports the pinned bridge module using absolute asset URLs. Inference runs
in the browser and can use a compatible WebGPU adapter.

For the source and local Chrome instructions, see
[`example/dartpad_gguf`](https://github.com/leehack/llamadart/tree/main/example/dartpad_gguf).
