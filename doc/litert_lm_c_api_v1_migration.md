# LiteRT-LM C API 1.0 consumer preparation

Issue #1677 owns adoption. The public `LiteRtLmRuntimeClient` continues to
reject C API 1.0. Pins, companion assets and published support stay on 0.18.
`LiteRtLmV1Runtime` is internal preparation code, unexported from package entry
points and unselected by production backend dispatch.

The first adapter targets exact owner candidate `94db8c5` with upstream
`771b06e1` (`v0.19.0`). It binds only explicit status-return/output-parameter
signatures from that candidate's `c/engine.h`, checks version 1.0.x and required
exports before operations, and reads thread-local errors synchronously before
cleanup. It preserves typed diagnostics and path redaction. C API 1.0 must
never pass through the legacy typedefs or callback proxy.

| Family | Preparation status | Adoption gate |
| --- | --- | --- |
| Version/status errors | Explicit 1.0.x probe; older/future/missing exports refuse | Both directions of artifact skew |
| Settings/engine | CPU, bounded context/threads, explicit isolated cache, owned engine | More settings/backends and platform evidence |
| Session/raw text | Fresh greedy synchronous session, explicitly no template application; UTF-8 copy, response and partial-failure cleanup | Production worker dispatch and cancellation transport |
| Conversations/history/tools | Public compatibility refusal remains | Status/out migration, lifetime ownership, delete/recreate after cancel |
| Callback streaming/termination | No callback registered by this adapter | Actual selected finish cause and wait/delete ordering |
| ASR | Public compatibility refusal remains | ABI-v1 bridge routing, model-family and lifecycle controls |
| Embeddings/schema | Public compatibility refusal remains | Regenerated/audited signatures, capabilities and model regressions |
| Hook/SPM/inventory | No changes | Qualified owner publication, TopK removal, bidirectional companion checks |

Raw text generation blocks its owning isolate. It exposes no cancellation or
cross-isolate handles. Every request owns and deletes its own session; engine
reload retains the previous engine if candidate creation fails. Disposal is
final and idempotent. This bounded preparation API cannot establish an app
feature, tool-loop safety, exact usage, async cancellation or broad GPU support.

Tests compile a versioned fixture with live-object counters and inject failures
at each creation/status/output stage. The existing public ABI guard and its
legacy tests remain separate. Any real-model receipt must identify the exact
candidate/model hashes and actual backend; fixture success is not inference
qualification. Source stays draft until remaining families are migrated.

## Initial macOS arm64 evidence

Candidate owner `94db8c5`, library SHA-256
`6ae8a0038f4fa71a9403ccdb91bf4bf71cd792beb44191f2bcc187e6ef70d31d`,
with Qwen3-0.6B SHA-256
`555579ff2f4fd13379abe69c1c3ab5200f7338bc92471557f1d6614a6e5ab0b4`:
CPU engine creation and two fresh raw-text sessions execute through this
adapter. A direct native C API reference emits identical text (`2`) for the
recorded arithmetic prompt; this is ABI/lifetime parity, not arithmetic
correctness or public backend qualification. The candidate rejects the declared
Greedy sampler enum with UNIMPLEMENTED; use TopP with top-k 1 and temperature 0,
as the owner qualification tools do. The original unsuccessful probes are
retained separately from passing parity receipts.
