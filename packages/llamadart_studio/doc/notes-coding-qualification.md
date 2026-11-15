# macOS Notes and Coding qualification

This procedure evaluates a bounded release candidate. It does not qualify every
model or platform. Completed runs, exact revisions, asset hashes, and observed
outputs belong in the PR evidence; the commands below define the gates.

## Profiles

Use Studio's pinned Flutter SDK, with its `bin` directory first on `PATH`.
Models are explicit existing local files; these suites never download weights.

- Chat: Qwen3.8 27B UD-Q4_K_XL on macOS Metal, with positive GPU offload and two
  decode/batch CPU threads. Coding requests 16384 context and 2048 output tokens;
  Notes requests 8192 context and 512 output tokens. Both use temperature zero
  and disable thinking for this reproducible profile.
- Notes: Nomic Embed Text v1.5 Q8_0, optionally BGE Reranker v2 M3 Q8_0. The
  reranker-enabled profile must be identified separately in the evidence.
- Coding: initialize the enabled built-in Dart/Flutter skill and connect the
  actual default `dart mcp-server`. Keep default tool filters. Shell starts
  disabled with confirmation enabled; test scenarios explicitly enable it and
  approve only commands operating on the owned temporary project.

The model runtime must report Metal and positive resolved GPU layers. A CPU
fallback cannot qualify the Metal profile.

## Notes gates

From the repository root:

```bash
cd packages/llamadart_studio_core
# Set STUDIO_ACCEPTANCE_CHAT_MODEL and STUDIO_ACCEPTANCE_EMBED_MODEL to local files.
# Optionally set STUDIO_ACCEPTANCE_RERANK_MODEL to the local BGE model.
TMPDIR="$(mktemp -d)" dart test test/local_notebook_qualification_test.dart -j 1 --reporter expanded
```

The suite exercises distractor retrieval, two-source synthesis, contradictory
sources, missing information, edits/reindexing, fresh-controller reload, and
source deletion. Check the printed synthetic answers against source content.
Citation numbers must identify supplied sources; valid numbering alone does not
prove factual grounding. Record missing or unsupported claims as failures.

Run model-free recovery checks separately:

```bash
TMPDIR="$(mktemp -d)" dart test test/notebook_recovery_test.dart test/notebook_draft_test.dart test/note_store_process_recovery_test.dart -j 1
```

Recovery covers failed saves/deletes/indexing, edits and deletes while embeddings
are pending, retained drafts, and media ownership. The process suite cold-loads
committed data and kills only its owned child. Its mid-save test uses an injected
POSIX FIFO stall at metadata writing, then a real `SIGKILL`, to verify that prior
committed metadata still references the prior attachment bytes. That is a
controlled process-crash test; power-loss durability and concurrent independent
writers remain unqualified. The file store commits notes individually; batch
operations do not provide a collection-wide transaction.

## Coding gates

```bash
cd packages/llamadart_studio_core
# Set STUDIO_CODING_QUALIFICATION_MODEL to the local Qwen3.8 27B file.
TMPDIR="$(mktemp -d)" dart test test/local_coding_qualification_test.dart -j 1 --reporter expanded
```

Required outcomes:

1. Reproduce a genuine failing test, inspect files, make the minimal source fix,
   execute the approved test command, review the actual diff, use default MCP
   analysis, and revert to byte-for-byte original sources.
2. Implement and test a policy shared by two modules, inspect both changes, and
   restore both sources. Protected test files must remain unchanged.
3. Reject a command and prove its marker file was never created.
4. Cancel at the approval boundary, prove execution did not occur, and complete
   a subsequent real read successfully.
5. Execute an approved failing command and preserve its actual nonzero status
   and diagnostic output.

Tool calls, process results, independent test reruns, diffs, and file bytes must
support the outcome. A fluent final answer alone is insufficient. Invalid paths,
missing answers, exhausted tool rounds, and runtime failures must remain visible;
do not relax workspace restrictions or fabricate results to obtain a pass.

## Release evidence

Record the source revision, SDK/runtime versions, hardware without unique device
identifiers, model SHA-256 values, actual backend/context/layers, active skills,
connected MCP server/tools, case results, and observed failures. Repeat after
behavior changes and retain failed-run evidence. Successful completion establishes
the profiles and scenarios above; longer-session memory pressure, other models,
other platforms, and end-user app distribution require separate qualification.
