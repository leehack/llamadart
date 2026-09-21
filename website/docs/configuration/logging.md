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

`setDartLogLevel` and `setLogLevel` also apply the Dart level to a running
native backend worker (see [Backend worker isolates](#backend-worker-isolates)).

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

The native llama.cpp and LiteRT-LM backends run in a worker isolate. A worker
takes the Dart logger level when it starts and forwards only records at or
above that level to the main isolate, where the `configureLogging` handler
receives them after the main-isolate level is applied again.
`engine.setDartLogLevel` and `engine.setLogLevel` change the level of a
running worker too; a later `configureLogging` call changes only the handler
and the main-isolate level. At the default `none` nothing is forwarded.
A forwarded record carries its error as `toString` text and its stack trace
rebuilt from text. A worker forwards
at most 1000 `debug` records; records above `debug` are never capped. An error
thrown by the handler on a forwarded record is printed, not thrown. Web
backends run on the main isolate and are unaffected.

## Recommended profiles

- Local debugging: Dart `info`, native `warn`.
- Performance testing: Dart `warn`, native `error`.
- Production app defaults: both `error` or `none`.

## Troubleshooting noisy logs

If you still see too much output, verify:

- You are not re-enabling logs in app startup paths.
- Model load/reload paths set levels before first inference.
- Any custom logger handler is filtering correctly.
