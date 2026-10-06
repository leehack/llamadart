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

## An exit during the last free

`llama_dart_exit_free` takes an object out of the registry before it has
finished freeing it, and teardown returns at once when the registry is empty.
In `v0.5.0-1` a direct C `exit()` that arrives while the last tracked object
is being freed therefore does not wait for that free, and ggml-metal aborts
when the object still has Metal buffers allocated. The `llamadart-native`
investigation reproduced it with a projector or a split (multi-file) model as
the last object, and not with a single-file model. As with the other limits,
only a direct C `exit()` reaches it; the exits that shut the isolates down
wait for the free. The native fix is planned for `v0.5.0-2`, which this
package does not pin yet.

The service is a second layer: `dispose()` and `freeModel` free contexts,
then the projector, then the model, so the last object a service frees is a
model and never a projector. That is also the lifetime order mtmd needs,
since a projector points at its model. A split model freed last stays exposed
on `v0.5.0-1`.

## Which exits are covered

| Exit | What happens |
| --- | --- |
| Flutter macOS quit (`-[NSApplication terminate:]`) | The engine shuts the isolates down before C `exit`, so held objects are freed by their isolate. Teardown frees what no isolate held yet: a quit while a model loads, and a quit after a hot restart during a load, no longer abort. |
| Dart program returns from `main` or dies of an unhandled error; an isolate is killed | The VM shuts the isolates down first. An object created by a native call the isolate never returned from in Dart is freed by teardown. |
| `exit()` from `dart:io` | Runs no static destructors: no teardown and no abort. |
| C `exit()` while an isolate is still running (through FFI, or a native host that skips the engine shutdown) | Covered only while the isolate is idle or inside a guarded call that returns within two seconds. Inside an unguarded call it is a use after free; inside a longer guarded call, or on `v0.5.0-1` during the free of the last tracked object, ggml-metal aborts. |

Image models are not covered: stable-diffusion.cpp has no such teardown.

## Rule for new code

A native call on a model, context, projector or decision-head object that
must not race exit teardown goes through `LlamaCppObjectCalls` or
`ExitTeardownApi`. When libllamadart has no guarded function for it, add one
in `llamadart-native` first; calling the upstream function leaves the call
unprotected at a direct C `exit()`.

## Tests

- `test/unit/backends/llama_cpp/exit_teardown_api_test.dart`: the stage
  values; the lookup requests all 22 names and resolves nothing when any one
  is missing; each member calls the function exported under its own name;
  `LlamaCppObjectCalls.tracked` uses the exit API for every call; one free per
  tracked object.
- `test/integration/backends/llama_cpp/native_symbol_integration_test.dart`:
  the address resolved for each name is the wrapper library's own export of
  that name.
- `test/unit/backends/llama_cpp/llama_cpp_service_exit_teardown_test.dart`: a
  recording `ExitTeardownApi` on a real CPU runtime. The whole recorded
  sequence is compared for creation and frees, plain generation (one decode
  and one sample per token), one-text and batch embedding on a decoder and on
  an encoder, state files, LoRA init, a decision head, a decision head that
  fails after its context was created, and a fake projector. N-gram and
  draft-model speculation are matched against the sequences their loop
  allows. Everything created through the API has to be freed through it.
- `test/unit/backends/llama_cpp/mtmd_chunk_eval_test.dart`: `withExitTeardown`
  replaces the three evaluating calls and keeps the accessors.
- Two cases of the service test do not run in default CI. The restore and
  replay of a rejected draft needs a model whose memory cannot drop a tail:
  set `LLAMADART_LFM2_MODEL` to an LFM2 GGUF. The decision head's device
  backend needs a GPU: it runs on a Mac unless `GGML_METAL_DEVICES=0`.
- No test reaches the free of a model whose vocabulary cannot be read after
  it loaded (`_createModelWrapper`).
- The same test pins the free order of `dispose()` and `freeModel`: context,
  projector, model.
- `native-exit-teardown` in `doc/testing_matrix.md`: local-only process exits
  on Metal, including a C `exit` while a service with a projector disposes.
