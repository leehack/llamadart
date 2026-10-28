# Bounded hires-fix qualification

`HiresFixImageGenerationRequest` adds a second, refining pass to
text-to-image generation: the runtime samples the request's size, enlarges
each latent bilinearly (`ImageHiresUpscaler.latent`) to the `ImageHiresFix`
final size, adds noise for `denoisingStrength` and samples again at the final
size, then decodes the final latents. The admitted recipe is the pinned
stable-diffusion-native v0.3.0-1 runtime on macOS with the CPU or Metal and
one native-detected SD 1.x or SD 2.x checkpoint with a header-detected
embedded full VAE and no component overrides.

## Contract

| Rule | Value |
| --- | --- |
| Final size | `ImageHiresFix.scale` (> 1, ≤ 2) or `ImageHiresFix.size`; the two are separate constructors |
| Alignment | First-pass and final sides are multiples of 64; a scale that does not land on one is rejected, never rounded |
| Bounds | Each final side ≥ the first-pass side and ≤ twice it, final area > first-pass area, final ≤ 1024x1024 (1,048,576 px), `count` ≤ 4 |
| Second-pass steps | 1 to 150, default the first pass's; the runtime runs the tail of a `steps / denoisingStrength` schedule, which can be one step more |
| Strength | 0.05 to 1, default 0.7 (upstream's default) |
| Seeds | Image `i` uses `seed + i` in both passes (upstream re-seeds before each image's second pass) |
| Upscaler | Latent bilinear only; model, Lanczos and nearest upscalers are not offered |
| Combinations | Image editing, ControlNet, VAE tiling and circular axes cannot be combined with it (`LlamaUnsupportedException`) |
| Partial results | None: a cancelled or failed second pass returns no images |
| Final metadata | `GeneratedImage.width`/`height` report the final size; the engine fails a result of any other size |
| Progress | `ImageGenerationProgressEvent.pass` 0 then 1 (`passCount` 2); the second pass reports its own step total |

Validation errors (`LlamaImageGenerationException`) and recipe refusals
(`LlamaUnsupportedException`) are thrown before the task starts.

## Admission and runtime path

- Load: `hiresFixRecipeVerified` needs macOS, a CPU or Metal backend, the
  pinned runtime commit (`be48649`), and the header proof the image-editing
  recipe uses: one checkpoint with four latent channels and
  `first_stage_model.decoder.conv_in.weight`, no tiny autoencoder and no
  other component. `ImageGenerationCapabilities.supportsHiresFix` also needs
  the runtime to detect `SD 1.x` or `SD 2.x` and the session to report
  `ImageHiresFixSession.supportsHiresFix`; a session without the interface
  is refused.
- Mapping: Dart resolves the final size, so `sd_img_gen_params_t.hires` gets
  `enabled`, `SD_HIRES_UPSCALER_LATENT`, `target_width`/`target_height`,
  `steps`, `denoising_strength`, `scale = 0`, no model path and no custom
  sigmas. Upstream `GenerationRequest::resolve_hires` would otherwise align
  the target up to a multiple of 64, or disable the pass with only a warning.
  Ordinary requests start from freshly initialized parameters, which leave
  the pass disabled.
- Native call: both passes run inside the guarded `sd_dart_generate_image`
  on the loaded context. Upstream `src/pipeline/image.cpp` checks the cancel
  flag before the second pass, before each image's latent upscale and before
  each sampling step, and frees the first-pass latents when the call
  returns. No new `sd_ctx_t` call, native object or callback is added; see
  `doc/llama_cpp_exit_teardown.md`, "Image models".
- Output check: the engine fails a task whose images do not have the final
  size, since upstream disables a hires pass it cannot apply with only a log
  warning and would return first-pass images as success.

## Reproduce

Prepare the clean checkout with the pinned SDK. Supply a local SD 1.x
checkpoint with its full VAE (SD 1.5 `v1-5-pruned-emaonly`) or an SD 2.x one
(SD-Turbo). Extract the checksum-verified pinned runtime bundle into
`$bundle`, then:

```bash
mkdir -p build/image-hires-fix-native-reference
clang++ -std=c++17 -O2 \
  example/basic_app/test/fixtures/image_hires_fix_native_reference.cpp \
  -I"$bundle/include" -L"$bundle/lib" -lstable-diffusion \
  -Wl,-rpath,"$bundle/lib" \
  -o build/image-hires-fix-native-reference/reference
for mode in base final hires; do
  /usr/bin/time -l build/image-hires-fix-native-reference/reference \
    "$checkpoint" cpu sd15 "$mode" \
    "$PWD/build/image-hires-fix-native-reference/sd15-cpu-$mode.ppm"
done
dart run tool/testing/run_local_e2e.dart --list
LLAMADART_HIRES_RECIPE=sd15 LLAMADART_HIRES_DEVICE=cpu \
  dart run tool/testing/run_local_e2e.dart \
  --scenario image-hires-fix --model-path "$checkpoint" --dry-run
LLAMADART_HIRES_RECIPE=sd15 LLAMADART_HIRES_DEVICE=cpu \
  LLAMADART_HIRES_NATIVE_REFERENCES="$PWD/build/image-hires-fix-native-reference" \
  TMPDIR="$(mktemp -d)" dart run tool/testing/run_local_e2e.dart \
  --scenario image-hires-fix --model-path "$checkpoint"
```

Use `gpu` for Metal and `turbo` for SD-Turbo in both the reference and the
environment. Both fixtures use the prompt "a red fox sitting in a snowy
forest, photograph", negative prompt "blurry", seed 42, Euler/discrete,
`flashAttention: false` and `vaeDirectConvolution: false` (`off` modes in C),
a 512x512 first pass and a 768x768 final size:

| Recipe | Steps | CFG | Hires steps | Strength |
| --- | --- | --- | --- | --- |
| `sd15` | 12 | 7 | 8 | 0.55 |
| `turbo` | 2 | 1 | 2 | 0.5 |

`base` is an ordinary 512x512 request, `final` an ordinary 768x768 request
and `hires` the two-pass request.

Fixed acceptance gates, recorded before any hires output was observed:

| Check | Required |
| --- | --- |
| Public Dart vs independent C, `base`, `final`, `hires` | Exact RGB |
| `ImageHiresFix.size(768, 768)` vs `ImageHiresFix.scale(1.5)` | Exact RGB |
| Ordinary request after hires requests | Exact `base` RGB |
| Hires vs bilinear-enlarged `base` | MAE > 1 (the second pass refines) |
| Downscaled hires vs `base`, against downscaled one-pass `final` vs `base` | Smaller (the first-pass composition is kept) |
| Second-pass progress | Pass 0 totals equal the steps; pass 1 events follow |
| Cancel in the second pass | Cancelled completion, then exact hires reuse |
| Dispose/reload | Capability cleared then restored; exact hires RGB |

RESULTS_PLACEHOLDER
