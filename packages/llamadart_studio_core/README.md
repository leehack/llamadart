# llamadart_studio_core

Pure-Dart headless foundation for **llamadart Studio**, designed for reuse across Flutter, Jaspr web apps, and Dart CLI hosts without UI framework coupling.

## Architecture

- **Reactive Stores (`StateStore<S>`)**: Framework-agnostic synchronous state snapshots paired with broadcast streams and selector subscriptions.
- **Hexagonal Ports**:
  - `StudioInferencePort`: Stateless streaming chat/tool/structured-output port (`DirectLlamaInferencePort` out of the box; an integration boundary for a future `genkit_llamadart` adapter).
  - `StudioPlaygroundPort`: Embeddings, cosine similarity, reranking, token inspection, and benchmarks.
  - `StudioSpeechPort` & `StudioImagePort`: Local speech-to-text, text-to-speech, and image generation ports.
  - `KeyValueStore` & `StudioConversationStore`: Durable settings, crash-safe boot sentinels, and conversation-tree persistence.
- **Focused Controllers**: Separate single-responsibility controllers for the shell, Model Hub, Chat (with non-destructive message branching and incremental stream updates), Speech Studio, Image Studio, and Playground.

## Coding host policy

Hosts without local subprocess support pass
`localProcessExecutionAvailable: false` to `CodingWorkspaceController`.
Re-enabling the shell toggle then leaves `bash` unregistered while file and
connected network MCP tools remain available. Studio sets this policy on mobile
and Web; the IO boundaries also reject shell and stdio MCP process creation on
iOS/Android with `LlamaUnsupportedException`.

File tools operate only on application-accessible filesystem paths. They do not
provide document-provider permissions or security-scoped access. Revert retains
post-edit content up to 1 Mi characters and checks it before restoring or
deleting a file. It rejects mismatches and missing snapshots; this optimistic
check does not coordinate simultaneous external writers between check and write.
