---
title: Recent releases
description: Release notes for the current and previous llamadart minor, with a link to the full changelog for older releases.
---

This page keeps the current and previous minor
releases. Notes for every older release are in
[`CHANGELOG.md`](https://github.com/leehack/llamadart/blob/main/CHANGELOG.md).

For upgrade planning, combine this page with the
[Upgrade Checklist](../migration/upgrade-checklist). For breaking changes,
validate against the exact release tag notes.

## 0.22.0

- Keep default WebGPU bridge assets at `v0.1.94` (unchanged from 0.21.0).

Runtime baseline: native llama.cpp `v1.0.0-4` and Web use upstream `v1.0.0@b1b770d90d94cad9e9ea5b993bdbc383a522fb28`; native LiteRT-LM uses `v0.20.0` and stable-diffusion uses `v0.4.0-1`. Web LiteRT-LM uses `@litert-lm/core@0.20.0`. Manifest SHA-256: `24d62c212338dda646a3b815d5883557a01b09997dee4f5b84245c5ab64fa5f6`.

## 0.21.0

- Add `GenerationParams.ignoreEos` to keep native llama.cpp generating past end-of-generation tokens where `supportsIgnoreEos` is true. Grammars, WebGPU and LiteRT-LM reject this option.
- Cancel streamed Web GGUF loads with `ModelLoadOptions.cancelToken` or engine disposal and stop automatic retries.
- Update native LiteRT-LM to `v0.20.0` with C API 1.1.0. The loader also accepts C API 1.0.x.
- Update the chat app and Studio to `@litert-lm/core@0.20.0`. For explicit CPU loads, custom Web preloads must expose the same module's `Backend` enum as `window.LiteRtLmBackendEnum`. Web embeddings remain disabled.
- Report how to re-enable memory64 after a Web wasm32 size refusal and document that a split GGUF size hint sums every shard.
- Enable bundled MTP on LiteRT-LM WebGPU with a load-time probe and per-request opt-in.
- Reject unsupported native LiteRT-LM text LoRA adapters during model load with a typed diagnostic.
- Keep default WebGPU bridge assets at `v0.1.94` (unchanged from 0.20.8).

Runtime baseline: native llama.cpp `v1.0.0-4` and Web use upstream `v1.0.0@b1b770d90d94cad9e9ea5b993bdbc383a522fb28`; native LiteRT-LM uses `v0.20.0` and stable-diffusion uses `v0.4.0-1`. Web LiteRT-LM uses `@litert-lm/core@0.20.0`. Manifest SHA-256: `24d62c212338dda646a3b815d5883557a01b09997dee4f5b84245c5ab64fa5f6`.

