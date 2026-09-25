---
title: "llamadart: on-device LLMs for Flutter and Dart"
sidebar_label: Overview
slug: /intro
description: llamadart runs LLMs on-device in Flutter and Dart apps, with one API for GGUF and LiteRT-LM models on six platforms. See what it does and where to start.
---

`llamadart` is a Dart package for on-device inference. It runs GGUF models
through `llama.cpp` and `.litertlm` bundles through LiteRT-LM, on Android, iOS,
macOS, Linux, Windows and the web, behind one Dart API.

## Who this is for

- Flutter and Dart developers who want AI features that run on the user's
  device: prompts stay private, and there is no inference server or API key.
- Apps that must work offline. Native targets need no network once the model
  is on the device; on the web, the page fetches the runtime and model over the
  network, then runs inference in the browser.
- Teams that want one codebase across mobile, desktop and web instead of a
  separate SDK per platform.
- Tools that need an OpenAI-compatible HTTP endpoint backed by a local model:
  see the [OpenAI-compatible server example](./examples/llamadart-server).

## What you can build

- Streaming chat and text generation, with
  [structured JSON output](./guides/generation-and-streaming#structured-json-output).
- [Tool calling](./guides/tool-calling) driven by the model's chat template.
- [Embeddings](./guides/embeddings) for search and retrieval.
- [Image and audio input](./guides/multimodal) with multimodal models.
- [Speech to text](./guides/speech-to-text) and
  [text to speech](./guides/text-to-speech).
- [Decision models](./guides/decision-models) that answer typed questions
  without generating text.
- Runtime [LoRA adapters](./guides/lora-adapters).

## Core primitives

- `LlamaEngine`: stateless generation API.
- `ChatSession`: stateful chat wrapper over `LlamaEngine`.
- `LlamaBackend`: platform backend abstraction used by the engine.

## Read by workflow

- First setup: [Install llamadart](./getting-started/installation)
- First inference: [Quickstart](./getting-started/quickstart)
- Multi-turn chat: [Your first chat session](./getting-started/first-chat-session)
- Backend choice: [Choosing llama.cpp or LiteRT-LM](./guides/backend-selection)
- Embedding pipelines: [Embeddings](./guides/embeddings)
- Function calling: [Tool calling](./guides/tool-calling)
- Template diagnostics: [Chat templates and output parsing](./guides/chat-template-and-parsing)
- Template internals: [Template engine internals](./guides/template-engine-internals)
- LoRA runtime workflows: [LoRA adapters](./guides/lora-adapters)
- Performance work: [Performance tuning](./guides/performance-tuning)
- Backend benchmark results: [Backend benchmarks](./guides/backend-benchmarks)
- Platform/backend planning: [Platform and backend support matrix](./platforms/support-matrix)
- Upgrade planning: [Upgrade checklist](./migration/upgrade-checklist)
- Maintainer operations: [Maintainer overview](./maintainers/docs-site)
