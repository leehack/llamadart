# Migration guide

## Upgrading to llamadart 0.15

The current plugin requires llamadart `^0.15.0`. Genkit 1.0, Schemantic 1.0
and the Dart 3.12 minimum are unchanged.

Flutter iOS and macOS apps must use matching `^0.15.0` runtime companions:
`llamadart_llama_cpp_flutter`, `llamadart_litert_lm_flutter`, and, for image
generation, `llamadart_stable_diffusion_flutter`. Core and companions now share
the same minor version; pub rejects mismatched minors. The 0.15 upgrade
crosses 0.14's native ABI
break: native v0.6.0 and older overrides are incompatible. Use the matching
v0.7.0-1 llama.cpp runtime and upgrade every Apple companion to 0.15.x.
LiteRT-LM native is v0.18.0-2; Web llama.cpp defaults to bridge v0.1.65.
See the [0.15 release notes](https://pub.dev/packages/llamadart/versions/0.15.0/changelog).

Raw response schemas now reject unsupported or shadowed assertions before
inference. Handle typed unsupported/argument errors when supplying custom
schemas or WebGPU options. Requalify application-specific tool/JSON requests
and native prompt caches against the new runtime; previous 0.13 measurements
in this documentation remain historical evidence.

## Upgrading to 3.0 (Genkit 1.0)

Version 3.0.0 requires Dart 3.12, Genkit 1.0, llamadart 0.11.1, and
Schemantic 1.0. For applications using the previous dependency versions:

- Put the output type first in explicit generation type arguments:
  `ai.generate<T, LlamaDartGenerationConfig>(...)` and
  `ai.generateStream<T, LlamaDartGenerationConfig>(...)`.
- Replace `GenerateResponseHelper<T>` with `GenerateResult<T>`, including
  explicit types for results returned by `prepared.warmUp<T>(ai)`.
- Use `ToolChoice.auto`, `ToolChoice.required`, or `ToolChoice.none` for
  Genkit's `toolChoice`; use `StatusCode.invalidArgument` and other
  lowerCamelCase status values when checking errors.
- Replace `ai.embedMany(...)` with `ai.embed(...)` for multiple documents.
- Define custom Schemantic JSON schemas with plain maps instead of `$Schema`.
- Use `ModelParams(device: ComputeDevice.cpu)` (or `auto`, `gpu`, or `npu`)
  for device selection. The deprecated `LiteRtLmBackendPreference` export
  has been removed; replace it with `ComputeDevice`.
- Use `genkit_otel` 0.2.0 or newer with Genkit 1.0.
- Flutter Apple apps using runtime companions must upgrade them alongside
  llamadart: core 0.11.1 pairs with `llamadart_llama_cpp_flutter` 0.0.21
  and `llamadart_litert_lm_flutter` 0.0.13. See the
  [llamadart 0.11.1 installation notes](https://pub.dev/packages/llamadart/versions/0.11.1#install)
  for the matching runtime packaging.

## Upgrading to 2.0

Version 2.0 requires Dart 3.12, Genkit 0.17, llamadart 0.9, and Schemantic
0.2.3. When upgrading from 1.x (Genkit 0.13–0.15):

- Return `ToolResult.response(value)` from tool callbacks; see
  [Tool calling](usage.md#tool-calling).
- Check generation results for `failed` or `aborted` finish reasons, and
  optionally pass Genkit cancellation tokens; see
  [Lifecycle and cancellation](usage.md#lifecycle-and-cancellation).

See the [changelog](../CHANGELOG.md) for the full list of changes.
