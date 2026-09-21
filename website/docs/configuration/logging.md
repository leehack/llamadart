---
title: Logging
---

`llamadart` supports separate log controls for Dart-side and native runtime
layers.

## Engine log controls

```dart
await engine.setDartLogLevel(LlamaLogLevel.info);
await engine.setNativeLogLevel(LlamaLogLevel.warn);

// or set both to same value
await engine.setLogLevel(LlamaLogLevel.error);
```

## Global Dart logger configuration

```dart
LlamaEngine.configureLogging(
  level: LlamaLogLevel.info,
  handler: (record) {
    print('[${record.level}] ${record.message}');
  },
);
```

## Recommended profiles

- Local debugging: Dart `info`, native `warn`.
- Performance testing: Dart `warn`, native `error`.
- Production app defaults: both `error` or `none`.

## Troubleshooting noisy logs

If you still see too much output, verify:

- You are not re-enabling logs in app startup paths.
- Model load/reload paths set levels before first inference.
- Any custom logger handler is filtering correctly.

## Native output outside llamadart's control

On the native LiteRT-LM backend, `setNativeLogLevel(LlamaLogLevel.none)` is
passed to the runtime as silent before each engine create and stops the
runtime library's own absl, LiteRT and TFLite loggers. The prebuilt WebGPU
accelerator (`libLiteRtWebGpuAccelerator`) links its own absl and exports no
logging control, so a GPU engine create still writes `I0000` info lines to
stderr. A CPU-only load writes nothing. Verified on macOS arm64 with LiteRT-LM
0.17.0-6 and Qwen3-0.6B at `none`; source line numbers and the adapter string
vary by release and GPU:

```text
I0000 ... environment.cc:...] Selected adapter: Apple M4 Max, arch=metal-3, vendor=apple, backend=Metal, ...
I0000 ... delegate_webgpu.cc:...] # of threads to upload weights = 2
I0000 ... delegate_webgpu.cc:...] # of threads to compile kernels = 1
I0000 ... delegate_kernel.cc:...] Total 113 external tensors are used for delegate inputs and outputs
I0000 ... delegate_kernel.cc:...] Initializing WebGPU-based API from serialized data.
```

`llamadart` cannot filter or redirect these lines; an app that must hide them
has to capture the process stderr itself. Tracked in
[#568](https://github.com/leehack/llamadart/issues/568).
