---
title: DartPad GGUF example
sidebar_label: DartPad GGUF
description: Chat with SmolLM2-135M-Instruct on preview.dartpad.dev without cross-origin isolation.
---

[Open on preview.dartpad.dev](https://preview.dartpad.dev/?package=llamadart&root=example/dartpad_gguf&file=example/dartpad_gguf/lib/main.dart)
The link always opens the latest published llamadart.
The example is available starting in 0.20.7.

Run the Flutter preview and choose **Load** to download SmolLM2-135M-Instruct
Q4_K_M (about 106 MB). Enter a prompt or choose a preset and select **Send**.
The app streams a reply, and the model gets the conversation history on each
follow-up. **Stop** keeps the partial reply, including text flushed during
cancellation. **Clear** starts a new conversation.

Open **Settings** to change temperature, maximum output tokens, or the system
prompt. The stats show the running backend and elapsed time while streaming,
then token count and throughput when available.

DartPad Preview runs the app in a non-isolated iframe. The example imports the
pinned bridge module using absolute asset URLs, so the bridge automatically
selects the
[single-thread GGUF core](../platforms/webgpu-bridge#single-threaded-gguf-without-isolation).
Inference runs in the browser and can use a compatible WebGPU adapter.

For the source and local Chrome instructions, see
[`example/dartpad_gguf`](https://github.com/leehack/llamadart/tree/main/example/dartpad_gguf).
