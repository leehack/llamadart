---
title: Examples overview
sidebar_label: Overview
description: Choose the right runnable example in the llamadart repository by task, from Dart console apps to a Flutter chat app, decision-model games, CLI, server and coding agent.
---

The repository ships runnable examples under `example/`, one per integration
style.

## Which one should I start with?

| Task | Example | What it shows |
| --- | --- | --- |
| Learn the core Dart API, embeddings, SQLite vector retrieval, decision models, or image generation (Preview) | [Basic app](./basic-app) | Minimal Dart console CLIs for chat, embeddings, retrieval, `DecisionEngine`, and `ImageGenerationEngine`. |
| Build or explore a full Flutter product UI | [Chat app](./chat-app) | Flutter app with model downloads, runtime controls, multimodal input, speech, and image generation (Preview). |
| Run a small GGUF in a browser without cross-origin isolation | [DartPad GGUF](./dartpad-gguf) | Multi-turn SmolLM2-135M-Instruct chat with prompt presets, generation settings, and live stats. |
| Run decision models in a real-time app | [Laya Tetris](./laya-tetris) | Flutter game played in real time by a Laya decision model through `DecisionEngine`. |
| Drive interactive UI from a classifier or scorer | [Laya Command Bar](./laya-command-bar) | Flutter text field reshaped as you type using `DecisionEngine`, `embedBatch`, or `scoreNextToken`. |
| Keep a `llama.cpp` terminal workflow | [llama.cpp-Style CLI](./llamadart-cli) | Terminal chat with `llama.cpp`-style arguments and parity harnesses. |
| Serve chat, tools, and embeddings over HTTP | [OpenAI-compatible server](./llamadart-server) | Local OpenAI-style HTTP API backed by `LlamaEngine`. |
| Build an interactive coding agent in the terminal | [TUI coding agent](./tui-coding-agent) | `nocterm` terminal agent with one conversation and four file/shell tools. |
| Train your own LoRA adapter | [LoRA Training Notebook](https://github.com/leehack/llamadart/blob/main/example/training_notebook/lora_training.ipynb) | Jupyter notebook that fine-tunes Qwen2.5 0.5B with `peft` and converts to GGUF for [LoRA adapters](../guides/lora-adapters). |

## Example catalog

Merged into the task-to-example table in
[Which one should I start with?](#which-one-should-i-start-with).

## Global example requirements

SDK versions, Apple deployment targets and the first-run runtime download are
in [Installation](../getting-started/installation#requirements).

- The Chat App enables both native runtime families, `llama.cpp` and LiteRT-LM,
  because it demonstrates GGUF and `.litertlm` models.
