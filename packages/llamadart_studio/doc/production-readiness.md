# Studio production acceptance

Studio qualifies a specific app revision, platform, runtime and model profile.
A passing build does not qualify inference, and CPU fallback does not qualify a
GPU profile. Keep completed results and raw evidence in the PR, bound to the
source revision and model hashes. Retain failed runs when a candidate changes.

## Required workflows

| Area | Acceptance |
| --- | --- |
| Startup and navigation | Open every workspace, resize from 320px through desktop widths, use enlarged text and keyboard navigation, and retain drafts across navigation. Unsupported capabilities explain the reason and leave other workspaces usable. |
| Model Hub and cache | Find a curated, local and Hub model; identify format and companion assets; show download and activation progress outside Model Hub; cancel and retry; verify cached assets; report failure without a false ready state. Never delete an active model. |
| Chat | Stream, stop, recover, branch, rename, delete, save and reopen. Preserve typed tool rounds and reasoning through reload. Export/import attachments independently of the original store; missing media reports an actionable error. |
| Notes | Save and cold-reopen text and owned attachments; index, retrieve, optionally rerank and answer with traceable sources. Edits and deletion invalidate stale results. Failed writes preserve drafts and prior committed data. |
| Coding | Read before editing, reproduce a failing test, repair and independently rerun it, inspect the diff, use the default Dart MCP analysis tool, and revert exact original bytes. Exercise two-file changes, concurrent-edit Revert conflicts, rejected commands, cancellation and nonzero command results. Mobile layout checks use full-shell widgets at 360/390px, keyboard inset 300px, safe-area top 44/bottom 34 and text scales 1/1.8; native picker permissions, keyboard transitions, back gestures, focus restoration and relaunch access still require device qualification. Local command/default stdio MCP qualification applies to desktop; mobile uses file tools where accessible and network MCP. |
| Tools and MCP | Keep repository processes behind workspace trust. Validate every emitted call before side effects. Unsupported tool schemas produce visible notices; required unavailable tools fail before generation. Preserve supported tools and original invocation constraints. |
| Speech and media | Capture or import audio, transcribe, synthesize, play and export on supported platforms. Permission denial, picker cancellation, damaged media and device failure remain recoverable. Clean up owned temporary files and browser blob URLs. |
| Image and Playground | Run the advertised supported image, embedding, reranking, decision, token and benchmark paths with actual assets. Show explicit runtime limitations and preserve usable navigation when a runtime is unavailable. |
| Lifecycle | Repeat load, generation, cancellation, recovery, clear, unload and dispose. Quit during active generation and pending tools; reopen stored data; record process memory after warmup and check for new crash reports. |

The [Notes and Coding qualification](notes-coding-qualification.md) defines the
Qwen3.8 27B Metal scenarios, approved commands and grounding checks. A small
model's pipeline test cannot replace that profile's model-quality acceptance.
Valid source numbering alone does not prove a grounded answer.

## Platform evidence

| Platform | Required evidence |
| --- | --- |
| macOS | Release build, live keyboard/mouse navigation and file dialogs, real Metal inference, Notes/Coding qualification, media, cold persistence and clean quit. |
| Windows | Release build, input in an interactive desktop session, real CPU or recorded GPU inference, storage and supported media. A service-session test is insufficient for desktop interaction. |
| Linux | Release build and interactive input, actual inference and storage. Exercise a host without Vulkan: Image must report unsupported before a native probe can abort startup. Qualify image inference separately on a compatible driver. |
| Android | Release artifact with explicit qualification signing or production signing, actual device inference, storage across process recreation, permission handling and supported media. Emulator results and physical-device results are recorded separately. |
| iOS | Build/signing checks, simulator interaction and physical-device inference, persistence, permission handling and supported media. Simulator execution does not qualify device GPU behavior. |
| Web | Build through `tool/build_web.sh`, validate pinned bridge assets, serve required isolation headers, test actual WebGPU inference and browser persistence, capture/import/export and denied permissions. Record browser/backend capabilities and quota failures. |

A qualification-only Android debug signature is never a distributable production
signature. Do not publish unsigned or development-signed artifacts as releases.
An unavailable platform or physical device stays an explicit open gate.

For the maintained opt-in Android release instrumentation build and artifact
receipts, see [Android release acceptance](android-release-acceptance.md).

## Evidence and verification

Use the package-local Flutter pin for both Studio packages. Run their analysis,
formatting and model-free tests before model or device qualification. Browser
paths also run in Chrome. Root changes run the checks selected by repository CI
and the high-risk readiness procedure.

Each runtime result records source and harness hashes, SDK/runtime versions,
model hashes and sizes, actual backend, context size, GPU layers, thread counts,
case outputs and failures. Use isolated temporary storage and synthetic data;
never mutate the user's notes, conversations, model cache or coding projects.
Record the exact processes and cloud resources owned by the run and verify their
cleanup. Keep credentials and signed URLs out of artifacts and logs.

The opt-in `local_runtime_endurance_test.dart` records whole-process RSS across
repeated load/chat/cancel/recovery/teardown cycles. Its default gate is at most
256 MiB growth above the first post-warmup sample. Report the actual settings and
samples: this bounded check does not prove indefinite memory stability or GPU
allocation reclamation.

Before marking the PR ready, obtain an independent review of the final head,
resolve all review threads, complete the applicable structured-output and
high-risk evidence, and require green checks on that same head. App merge,
platform distribution and package/runtime release are separate decisions.
