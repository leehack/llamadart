---
title: LoRA Adapters
---

This guide covers practical LoRA usage in `llamadart` with runtime adapter
management APIs.

`llamadart` itself is an inference/runtime library. LoRA training is done in a
separate training workflow, then adapters are loaded at inference time.

## Runtime API surface

`LlamaEngine` exposes three LoRA operations:

- `setLora(path, scale: ...)`: load or update an adapter scale.
- `removeLora(path)`: remove one adapter from the active set.
- `clearLoras()`: remove all active adapters from the current context.

## Basic runtime flow

```dart
import 'package:llamadart/llamadart.dart';

Future<void> main() async {
  final engine = LlamaEngine(LlamaBackend());

  try {
    await engine.loadModel('/models/base-model.gguf');

    await engine.setLora('/models/lora/domain.gguf', scale: 0.7);

    await for (final chunk in engine.generate(
      'Answer as a domain specialist in one paragraph.',
    )) {
      print(chunk);
    }
  } finally {
    await engine.dispose();
  }
}
```

## Stacking adapters

You can activate multiple adapters on the same loaded model:

```dart
await engine.setLora('/models/lora/style.gguf', scale: 0.35);
await engine.setLora('/models/lora/domain.gguf', scale: 0.70);
```

- Calling `setLora(...)` again with the same path updates scale.
- Use `removeLora(path)` to disable one adapter.
- Use `clearLoras()` to reset to base model behavior.

Stacking and non-`1.0` scales are GGUF llama.cpp features. Native LiteRT-LM
`.litertlm` currently accepts one LiteRT-LM adapter at scale `1.0`.

## Training your own LoRA adapters

For end-to-end training + conversion, start with the official notebook:

- [LoRA Training Notebook](https://github.com/leehack/llamadart/blob/main/example/training_notebook/lora_training.ipynb)

Recommended workflow:

1. Pick a base model family that you will also serve in `llamadart`.
2. Train LoRA weights (for example, QLoRA/PEFT flow in the notebook).
3. Export adapter artifacts from training.
4. Convert adapter artifacts into llama.cpp-compatible GGUF adapter files.
5. Validate outputs in a native test run, then load adapters with `setLora(...)`.

Practical compatibility checks:

- Keep tokenizer/model family aligned between base model and adapter.
- Validate adapter behavior on the same quantized base model class you deploy.
- Keep a small golden-prompt set to compare base vs adapter output drift.

## Scale tuning guidance

- Start around `0.4` to `0.8` for first-pass evaluation.
- Lower scales (`0.1` to `0.3`) help preserve base-model behavior.
- Higher scales can over-steer outputs; validate with representative prompts.

## Lifecycle notes

- LoRA activation is tied to the active context.
- `unloadModel()` or `dispose()` releases model/context resources and clears
  active adapter state.
- Re-apply adapters after reloading a model.

## Platform notes

- Native llama.cpp/GGUF backends implement runtime LoRA operations with
  multiple weighted adapters.
- Native LiteRT-LM `.litertlm` supports one LiteRT-LM adapter at scale `1.0`
  through `ModelParams.loras` or the runtime LoRA APIs when the loaded
  `litert-lm-native` library exports
  `litert_lm_session_config_set_lora_file`.
- Web bridge and LiteRT-LM web runtimes do not expose LoRA effects.

## Troubleshooting

- If `setLora(...)` fails, verify the adapter path is accessible at runtime.
- Ensure adapter/base-model compatibility (architecture/family alignment).
- If a `.litertlm` model reports that the LoRA C symbol is missing, use a
  `litert-lm-native` build that exports
  `litert_lm_session_config_set_lora_file` or switch to a GGUF model on a
  llama.cpp backend.
- When behavior seems unchanged, confirm you are testing on a native target and
  not a web fallback path.
