---
name: llamadart-lora
description: >-
  Use when applying LoRA adapters with llamadart: training an adapter
  elsewhere and converting it to GGUF for a base model, loading, stacking,
  scaling or removing adapters at runtime with setLora, removeLora and
  clearLoras, passing ModelParams.loras, or checking LoRA support on native
  llama.cpp, WebGPU and LiteRT-LM.
---

# LoRA adapters with llamadart

llamadart applies LoRA adapters at inference time; it does not train them.

## Guidelines

- Produce adapters outside llamadart: fine-tune with an external stack (for
  example Hugging Face PEFT/QLoRA, see `example/training_notebook`), then
  convert the adapter directory to a GGUF adapter with llama.cpp's
  `convert_lora_to_gguf.py`. Train and convert against the same base model
  (architecture, size and tokenizer) you serve; an adapter for another base
  model fails to load (`LlamaModelException`).
- Deploy the adapter with the same base model family and a comparable
  quantization to the one you evaluated it on, and keep a small golden-prompt
  set to compare base and adapter output.
- Loading the base model and basic chat are covered by the
  llamadart-getting-started and llamadart-chat-streaming skills.
- Runtime API on `LlamaEngine`, all `Future<void>`, all needing a loaded model
  (otherwise `LlamaContextException`):
  - `setLora(path, scale: 1.0)` loads the adapter on first use and activates
    it; calling it again with the same path only changes the scale.
  - `removeLora(path)` deactivates one adapter.
  - `clearLoras()` returns to base-model behavior.
- Adapters stack: each distinct path passed to `setLora` stays active with its
  own scale until removed. Start tuning scales around `0.4`-`0.8`; lower
  (`0.1`-`0.3`) preserves more base behavior, higher can over-steer.
- Adapters you know at load time go in `ModelParams.loras`. On llama.cpp
  (native and WebGPU) each is applied in list order at its scale, as `setLora`
  would, once the model loads; `setLora`, `removeLora` and `clearLoras` can
  change them afterwards. If one cannot be applied the load fails and the
  engine is left with no model: `LlamaUnsupportedException` (naming the
  adapter) for an unsupported adapter or WebGPU bridge assets, otherwise
  `LlamaModelException` with the adapter and cause in its `details`.
- Adapter state belongs to the loaded model. `unloadModel()` and `dispose()`
  drop it, including `setLora` changes. Each load applies its own
  `ModelParams.loras` again; re-apply `setLora` adapters after a reload or
  model switch.
- An aLoRA (activated LoRA) adapter throws `LlamaUnsupportedException` from
  `setLora` or from a load that lists it in `ModelParams.loras`: llamadart
  applies adapters from the first token and does not implement
  invocation-sequence activation. Use a standard LoRA adapter.
- Runtime support by target:
  - Native llama.cpp (GGUF): `ModelParams.loras` and the full runtime API,
    multiple adapters, custom scales. `path` is a local file path.
  - WebGPU (GGUF on web): needs bridge assets whose
    `getLoraAdapterCapabilities()` reports support (bridge `v0.1.54+`, which
    includes the default pin), for `ModelParams.loras` and the runtime API.
    `path` is a URL, downloaded once per model load. Older bridge assets throw
    `LlamaUnsupportedException` on every LoRA call and on a load with
    `ModelParams.loras`.
  - Native LiteRT-LM (`.litertlm`): exactly one text adapter at scale `1.0`,
    passed as `ModelParams.loras` at load. More than one adapter or a
    non-default scale fails the load with `LlamaUnsupportedException`.
    `setLora`, `removeLora` and `clearLoras` throw `LlamaUnsupportedException`.
  - LiteRT-LM on web: no LoRA. Any `ModelParams.loras` entry fails the load and
    the runtime calls throw `LlamaUnsupportedException`.
- Do not catch and ignore `LlamaUnsupportedException` from LoRA calls; it means
  the adapter is not applied. If output looks unchanged, confirm the model runs
  on llama.cpp (`engine.getBackendName()`) and not LiteRT-LM.

## Examples

Train and convert an adapter (external tooling, not part of llamadart):

```python
# Hugging Face PEFT, run in a Python training environment.
from peft import LoraConfig, get_peft_model
from transformers import AutoModelForCausalLM

base = AutoModelForCausalLM.from_pretrained("Qwen/Qwen2.5-0.5B-Instruct")
model = get_peft_model(
    base,
    LoraConfig(r=16, lora_alpha=32, target_modules=["q_proj", "v_proj"],
               task_type="CAUSAL_LM"),
)
# ... train with your trainer of choice ...
model.save_pretrained("lora-adapter-output")
```

```bash
# llama.cpp conversion: HF PEFT adapter directory -> GGUF adapter.
git clone https://github.com/ggml-org/llama.cpp
pip install -r llama.cpp/requirements.txt
python llama.cpp/convert_lora_to_gguf.py lora-adapter-output \
  --base path/to/Qwen2.5-0.5B-Instruct \
  --outfile my_adapter.gguf --outtype f16
# Try it with the example CLI (same base model by default):
cd example/basic_app && dart run bin/llamadart_basic_example.dart \
  --lora ../../my_adapter.gguf
```

Load stacked adapters with a GGUF model, then rescale and remove them; a
reload applies `ModelParams.loras` again:

```dart
import 'package:llamadart/llamadart.dart';

const ModelParams withAdapters = ModelParams(
  loras: [
    LoraAdapterConfig(path: '/models/lora/style.gguf', scale: 0.35),
    LoraAdapterConfig(path: '/models/lora/domain.gguf', scale: 0.7),
  ],
);

Future<void> main() async {
  final LlamaEngine engine = LlamaEngine(LlamaBackend());
  try {
    await engine.loadModel(
      '/models/base-model.gguf',
      modelParams: withAdapters,
    );

    await engine.setLora('/models/lora/domain.gguf', scale: 0.4);
    await engine.removeLora('/models/lora/style.gguf');
    await engine.clearLoras();

    await engine.unloadModel();
    await engine.loadModel(
      '/models/base-model.gguf',
      modelParams: withAdapters,
    );
  } on LlamaUnsupportedException catch (error) {
    print('LoRA not available here: ${error.message}');
  } finally {
    await engine.dispose();
  }
}
```

Native LiteRT-LM: one default-scale adapter, only at load:

```dart
import 'package:llamadart/llamadart.dart';

Future<void> loadLiteRtLmWithAdapter(LlamaEngine engine) {
  return engine.loadModel(
    '/models/gemma.litertlm',
    modelParams: const ModelParams(
      loras: [LoraAdapterConfig(path: '/models/gemma-text-adapter.bin')],
    ),
  );
}
```

## More

- LoRA adapters: https://llamadart.leehack.com/docs/guides/lora-adapters
- Backend selection: https://llamadart.leehack.com/docs/guides/backend-selection
- Model lifecycle: https://llamadart.leehack.com/docs/guides/model-lifecycle
- WebGPU bridge: https://llamadart.leehack.com/docs/platforms/webgpu-bridge
