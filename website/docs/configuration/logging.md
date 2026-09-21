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

## Backend worker isolates

The native llama.cpp and LiteRT-LM backends run in a worker isolate. Each
worker reads the `configureLogging` level when it starts, on the first request
after the backend is created or disposed, and forwards only records at or
above that level to the main isolate, where the handler receives them. A later
`configureLogging` call changes the handler and the main-isolate level, but
not what a running worker forwards, so configure logging before the first
request. At the default `none` nothing is forwarded. A worker forwards at most
1000 `debug` records; records above `debug` are never capped. Web backends run
on the main isolate and are unaffected.

## Recommended profiles

- Local debugging: Dart `info`, native `warn`.
- Performance testing: Dart `warn`, native `error`.
- Production app defaults: both `error` or `none`.

## Troubleshooting noisy logs

If you still see too much output, verify:

- You are not re-enabling logs in app startup paths.
- Model load/reload paths set levels before first inference.
- Any custom logger handler is filtering correctly.
