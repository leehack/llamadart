# TUI Coding Agent Example (nocterm)

Path: `example/tui_coding_agent`

This example shows a terminal UI coding agent built with:

- `llamadart` for local model inference and tool calling
- `nocterm` for the interactive TUI layer

By default it starts with GLM 4.7 Flash (`unsloth/GLM-4.7-Flash-GGUF:UD-Q4_K_XL`).
You can switch to any local path, URL, or Hugging Face shorthand at startup or
inside the app.

Tool mode defaults to a **stable text-protocol tool loop** (recommended for
GLM). Native template grammar tool-calling is optional and can be enabled with
`--native-tool-calling`.

## Features

- Streaming assistant output in a TUI chat layout
- TurboVision-inspired desktop with overlapping windows
- Turbo C-style menu bar with popup menus (`Alt` + mnemonic)
- Compact centered exit confirmation dialog
- Built-in coding tools: `list_files`, `read_file`, `search_files`,
  `write_file`, `run_command`
- Workspace path guard (blocks tool access outside the selected workspace)
- Model switching command at runtime (`/model <source>`)
- Multi-session chat workflow (create/switch/close local sessions)
- One desktop window per session (MDI-style overlapping chat windows)
- Mouse window controls (focus, drag title bar, resize from lower-right handle)
- Slash command autocomplete (`Tab`, `Shift+Tab`, `Up`, `Down`)
- Tool-policy guardrails:
  - direct conceptual prompts default to no-tool answers
  - workspace/repo prompts enforce inspection before answering
  - duplicate and over-limit tool calls are skipped safely
- Default coding-oriented sampling values

## Run

```bash
cd example/tui_coding_agent
dart pub get
dart run bin/tui_coding_agent.dart
```

### Run with a specific workspace

```bash
dart run bin/tui_coding_agent.dart --workspace /path/to/project
```

### Run with a specific model

```bash
dart run bin/tui_coding_agent.dart --model /path/to/model.gguf
```

or

```bash
dart run bin/tui_coding_agent.dart --model owner/repo:Q4_K_M
```

### Enable native template tool-calling (experimental)

```bash
dart run bin/tui_coding_agent.dart --native-tool-calling
```

## Interactive Commands

- `/help` - Show available commands
- `/clear` - Clear active session log
- `/model` - Show current model source and loaded path
- `/model <path|url|owner/repo[:hint]>` - Switch model and reset session history
- `/workspace` - Show workspace root
- `/new` - Create a new session
- `/next` - Switch to next session
- `/prev` - Switch to previous session
- `/close` - Close current session
- `/zoom-window` - Zoom/unzoom active desktop window
- `/next-window` - Focus next desktop window
- `/prev-window` - Focus previous desktop window
- `/tile-windows` - Arrange all windows in a tiled grid
- `/stack-windows` - Arrange all windows in stacked cascade
- `/cancel` - Cancel active generation
- `/exit` - Open exit confirmation dialog
- `/quit` - Open exit confirmation dialog

## Keyboard Shortcuts

- `F1` - Show help
- `F2` - Seed `/model ` command
- `F3` - Clear conversation
- `F4` - Previous session
- `F5` - Zoom/unzoom active window
- `F6` - Focus next desktop window
- `F7` - Create new session
- `F8` - Next session
- `F9` - Focus previous desktop window
- `F10` - Open/close top menu bar
- `F12` - Close active session
- `Alt+W` - Close active session
- `Alt+X` - Open exit confirmation
- `Alt` + Arrow keys - Move active window
- `Alt` + `Shift` + Arrow keys - Resize active window
- `Esc` - Cancel generation when busy, otherwise open exit confirmation
- `Alt+<menu letter>` - Open top menu (`File/Edit/Search/...`)

In the exit confirmation dialog:

- `Left`/`Right`/`Tab` (`h`/`l` also supported) toggles YES/NO
- `Enter` confirms the currently selected option
- `Esc` or `N` selects NO and dismisses the dialog

## Notes

- The first run may take time due to model download and initialization.
- Downloaded models use the per-user shared `llamadart` model cache by default;
  pass `--cache-dir` to use a workspace-local or app-specific cache instead.
- `run_command` uses a safety filter and executes from the workspace root
  (or a workspace-relative subdirectory).
- `run_command` accepts `command` and also tolerates alias keys (`cmd`,
  `input`, `shell_command`) for model-compatibility.
- If you hit grammar-related crashes in native mode, run without
  `--native-tool-calling` (default stable mode).

## Test

```bash
dart test
```
