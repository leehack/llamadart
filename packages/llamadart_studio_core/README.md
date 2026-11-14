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
