# TUI Coding Agent Example (nocterm)

Path: `example/tui_coding_agent`

This is a deliberately small, Pi-style local coding agent built with
`llamadart` and `nocterm`. It keeps one model, one conversation, one screen,
four general tools, and a sequential model-to-tool loop that is easy to read
and adapt.

## Agent loop

For each user request, the example:

1. asks the model for the next response;
2. accepts either a normal final answer or exactly one standalone JSON tool
   call;
3. executes that tool and returns its JSON result to the model; and
4. repeats until the model answers normally or the round limit is reached.

The only executable text-protocol form is:

```text
<tool_call>{"name":"tool_name","arguments":{...}}</tool_call>
```

The block must be the complete assistant response. Calls run one at a time;
prose around a call, sibling calls, shorthand, XML variants, unknown tools,
and malformed or incomplete JSON are not executed.

## Tools

The model normally receives exactly four tools:

| Tool | Purpose |
| --- | --- |
| `read` | Read bounded UTF-8 text from a workspace file. |
| `write` | Create or overwrite a UTF-8 workspace file. |
| `edit` | Replace exactly one literal occurrence in a workspace file. |
| `bash` | Run a command with Bash on Unix or `cmd.exe` on Windows. |

The file tools resolve paths canonically and reject paths, including symlink
targets, outside the selected workspace. Applicable `AGENTS.md` files from the
workspace and its ancestors are loaded once when the session starts and added
to the system prompt. Start with `--read-only` to expose only `read` and omit
all mutation and shell tools.

## Default model and cache

The default model is Qwen3.6 35B-A3B:

```text
hf://unsloth/Qwen3.6-35B-A3B-GGUF/Qwen3.6-35B-A3B-UD-Q4_K_M.gguf
```

The native-desktop preset targets systems with at least 32 GB of RAM and uses:

- 16,384-token context
- up to 4,096 output tokens
- full GPU offload where supported
- logical batch size `2,048`, physical micro-batch size `512`
- temperature `0.7`, top-K `20`, top-P `0.8`, min-P `0`
- repeat penalty `1.0`, presence penalty `1.5`
- non-thinking generation
- at most 24 tool rounds per request

Pass `--thinking` to opt into the higher-quality reasoning profile:

- 32,768-token context
- up to 8,192 output tokens
- logical batch size `2,048`, physical micro-batch size `512`
- temperature `0.6`, top-K `20`, top-P `0.95`, min-P `0`
- repeat penalty `1.0`, presence penalty `0`
- thinking enabled

Thinking is opt-in because it is slower, uses substantially more context and
memory, and can spend much of the output budget reasoning before it reaches a
tool call or final answer. The default non-thinking profile keeps the local
demo responsive; use `--thinking` when solution quality matters more than
latency and your machine can accommodate the larger context. The 32K profile
keeps practical memory headroom for the quantized model on a 64 GB Apple Silicon
system; larger 48K and 64K contexts can exhaust Metal allocations.

Qwen3.6 exposes thinking as an on/off capability, not a trained
low/medium/high reasoning-effort scale. The example therefore keeps the control
honest: omit `--thinking` for off, or pass it for on. When enabled, prior
reasoning is preserved across the agent's tool rounds through Qwen's
`preserve_thinking` template option. Upstream llama.cpp also has a mechanical
reasoning-token budget, but llamadart's embedded inference API does not expose
that control yet; total output tokens are not used as a fake reasoning level.

The session passes this source directly to `LlamaEngine.loadModelSource`, so
downloads use `llamadart`'s shared per-user model cache and resume behavior.
Use `--cache-dir` only to override that cache root. An earlier flat
`UD-Q4_K_S` TUI file remains usable by passing its local path explicitly; it is
not substituted for the new `UD-Q4_K_M` default.

The model is selected only at startup. Pass a local GGUF path, HTTP(S) URL, or
exact `hf://owner/repo/path/to/model.gguf` reference with `--model` before
launching the TUI.

## Run

```bash
cd example/tui_coding_agent
dart pub get
dart run bin/tui_coding_agent.dart
```

Choose a workspace and model at startup when needed:

```bash
dart run bin/tui_coding_agent.dart --workspace /path/to/project
dart run bin/tui_coding_agent.dart --thinking
dart run bin/tui_coding_agent.dart --read-only
dart run bin/tui_coding_agent.dart --model /path/to/model.gguf
dart run bin/tui_coding_agent.dart \
  --model hf://owner/repo/path/to/model.gguf \
  --cache-dir /path/to/model-cache
```

Use `--help` for the complete startup options.

## TUI

The single-screen UI restores a compact TurboVision-inspired blue window,
gray status chrome, and framed transcript without restoring the old multi-window
desktop. It maintains one in-memory conversation for the loaded model.

Normal answers stream incrementally through a compact GitHub-flavored Markdown
renderer with headings, lists, links, inline code, and syntax-highlighted fenced
code. Code fences use their language label when available, cheaply recognize a
few common unlabelled formats, and fall back safely to plain code. Their
background fills every row, including empty lines. Markdown blocks and
transcript messages no longer add automatic blank spacer rows. With
`--thinking`, reasoning streams separately under a subdued `[think]` label and
the final answer remains under `[agent]`. The stream gate withholds text that
could be a split `<tool_call>` envelope, so raw executable JSON never flashes
in the transcript before validation. High-frequency deltas are coalesced to
terminal frame cadence and accumulated in buffers. Off-screen transcript rows
are built lazily, while the active Markdown row is reparsed only at presentation
cadence rather than for every burst of backend deltas. Syntax highlighting is
bounded for unusually large generated blocks so streaming stays responsive.

- `/help` shows the small command list.
- `/clear` resets the conversation without reloading the model.
- `/model` reports the startup-selected source and loaded model name.
- `/workspace` reports the workspace root.
- `/cancel` cancels current work.
- `/quit` exits.
- `Esc` cancels while busy; otherwise press it twice to quit.
- `Ctrl+C` cancels while busy and exits cleanly while idle.

## Limits and trust boundary

Model resolution and downloads, generation, and the active `bash` process tree
can be cancelled. File reads and edits, tool results, shell output, command
duration, context use, and tool rounds are bounded so the demo fails clearly
instead of growing without limit.

Native model allocation itself cannot be interrupted. If cancellation is
requested during that phase, the session unloads the model as soon as the
allocation call returns.

Cancellation does not roll back effects that already happened. The transcript
shows the command or file path, a bounded result summary, and a warning when an
interrupted tool may have changed state; the next turn retains that warning.

`bash` is intentionally a general shell tool and is **not sandboxed**. Its
commands run with the current user's normal permissions and can read or modify
files outside the selected workspace, access the environment and network, and
start arbitrary child processes. Workspace confinement applies only to
`read`, `write`, and `edit`. Use the demo only with trusted prompts and
repositories, or run the whole process inside an external sandbox or
container.

## Test

```bash
dart test
```
