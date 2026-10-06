# llama.cpp exit teardown

ggml-metal aborts in its static destructor
(`GGML_ASSERT([rsets->data count] == 0)`) when a process exits while a Metal
buffer is still allocated. `libllamadart` (`llamadart-native` `v0.5.0-1` and
later) keeps a registry of live objects and, on Apple platforms, frees what is
left of it during C `exit`, before that destructor. On other platforms nothing
runs at exit. The native contract is `src/llama_dart_wrapper.h` in
`llamadart-native`.

## Dart side

`lib/src/backends/llama_cpp/exit_teardown_api.dart` holds both ways a
`LlamaCppService` reaches llama.cpp:

- `ExitTeardownApi`: the tracked creators (`llama_dart_model_load_from_file`,
  `llama_dart_init_from_model`, `llama_dart_mtmd_init_from_file`),
  `llama_dart_exit_track` for the decision head's ggml objects,
  `llama_dart_exit_free`, and the guarded calls (decode, encode, synchronize,
  sample, state file and sequence state, LoRA init, mtmd tokenize and
  evaluation, scheduler graph compute). Every function is bound through the
  address `tryResolve` resolves, so the API exists only when the runtime
  exports all of them.
- `LlamaCppObjectCalls.upstream`: the upstream functions, which a runtime
  older than `v0.5.0-1` leaves as the only choice. The service then logs one
  warning at its first model load (visible at log level `warn` or lower) and
  exits behave as they did before exit teardown.

One service uses one of the two for all of its calls.
`IsolateShutdownReleases` still holds every object and frees it when its
isolate shuts down; with exit teardown the hold's free function is
`llama_dart_exit_free`, which does nothing for an object teardown already
freed. `llama_dart_exit_call_begin`, `llama_dart_exit_call_end` and
`llama_dart_exit_teardown` are excluded from the bindings (`ffigen.yaml`):
they are not safe from an isolate that can be killed.

## What teardown waits for

Teardown waits up to two seconds for guarded calls in flight, then for a
250 ms settle after the end of the last guarded call, and frees the tracked
objects. It knows nothing about other native calls:

- An unguarded call on a tracked object (tokenize, detokenize, metadata
  reads, sampler construction, media decode) that is in flight when teardown
  runs is not protected, however short it is. Teardown frees the object under
  it.
- A guarded call that is still running after two seconds (an image or audio
  evaluation, a long batch) makes teardown free nothing, and ggml-metal
  aborts as before.

## Which exits are covered

| Exit | What happens |
| --- | --- |
| Flutter macOS quit (`-[NSApplication terminate:]`) | The engine shuts the isolates down before C `exit`, so held objects are freed by their isolate. Teardown frees what no isolate held yet: a quit while a model loads, and a quit after a hot restart during a load, no longer abort. |
| Dart program returns from `main` or dies of an unhandled error; an isolate is killed | The VM shuts the isolates down first. An object created by a native call the isolate never returned from in Dart is freed by teardown. |
| `exit()` from `dart:io` | Runs no static destructors: no teardown and no abort. |
| C `exit()` while an isolate is still running (through FFI, or a native host that skips the engine shutdown) | Covered only while the isolate is idle or inside a guarded call that returns within two seconds. Inside an unguarded call it is a use after free; inside a longer guarded call ggml-metal aborts. |

Image models are not covered: stable-diffusion.cpp has no such teardown.

## Rule for new code

A native call on a model, context, projector or decision-head object that
must not race exit teardown goes through `LlamaCppObjectCalls` or
`ExitTeardownApi`. When libllamadart has no guarded function for it, add one
in `llamadart-native` first; calling the upstream function leaves the call
unprotected at a direct C `exit()`.

## Tests

- `test/unit/backends/llama_cpp/exit_teardown_api_test.dart`: the stage
  values, the all-or-nothing lookup, one free per tracked object.
- `test/unit/backends/llama_cpp/llama_cpp_service_exit_teardown_test.dart`: a
  recording `ExitTeardownApi` shows that creation, generation, speculative
  checkpoints, embedding, state files, LoRA init, a decision head and a fake
  projector go through it.
- `native-exit-teardown` in `doc/testing_matrix.md`: local-only process exits
  on Metal.
