/// Primary top-level destinations in `llamadart Studio`.
enum StudioWorkspace {
  /// Multi-turn multimodal chat, reasoning, structured JSON, and tool calling.
  chat(
    routeSegment: 'chat',
    label: 'Chat',
    shortcutDigit: 1,
    subtitle: 'Multimodal chat, tools, thinking & JSON schemas',
  ),

  /// Local repository coding agent with MCP servers and Agent Skills.
  coding(
    routeSegment: 'coding',
    label: 'Coding',
    shortcutDigit: 2,
    subtitle: 'Local codebase agent, file tools, MCP & Agent Skills',
  ),

  /// Multimodal NotebookLM-style workspace with live mic recording, ASR,
  /// EmbeddingGemma 2 multimodal indexing, and local grounded Q&A.
  notes(
    routeSegment: 'notes',
    label: 'Notes',
    shortcutDigit: 3,
    subtitle: 'Multimodal notebook, voice memos, EmbeddingGemma 2 & RAG Q&A',
  ),

  /// Dedicated text-to-speech synthesis and speech-to-text transcription.
  speech(
    routeSegment: 'speech',
    label: 'Speech',
    shortcutDigit: 4,
    subtitle: 'Local TTS synthesis, voice cloning & ASR transcription',
  ),

  /// Local Stable Diffusion / FLUX / Qwen-Image generation and editing.
  image(
    routeSegment: 'image',
    label: 'Image',
    shortcutDigit: 5,
    subtitle: 'Text-to-image & image editing with live step progress',
  ),

  /// Embeddings, reranking, System-1 decision engine & benchmarks.
  playground(
    routeSegment: 'playground',
    label: 'Playground',
    shortcutDigit: 6,
    subtitle: 'Embeddings, reranker, System-1 decision speed & benchmark',
  ),

  /// Curated model catalog, Hugging Face search, local files & cache manager.
  models(
    routeSegment: 'models',
    label: 'Model Hub',
    shortcutDigit: 7,
    subtitle: 'Curated GGUF & LiteRT-LM models, Hugging Face & memory fit',
  );

  const StudioWorkspace({
    required this.routeSegment,
    required this.label,
    required this.shortcutDigit,
    required this.subtitle,
  });

  /// URL path segment (for example `/chat` or `/models`).
  final String routeSegment;

  /// Human-readable workspace label.
  final String label;

  /// `Cmd/Ctrl + <digit>` shortcut index.
  final int shortcutDigit;

  /// Concise description shown in command palette and headers.
  final String subtitle;

  /// Resolves a [StudioWorkspace] from a URL path or segment, defaulting to
  /// [StudioWorkspace.chat].
  static StudioWorkspace fromRoute(String route) {
    final normalized = route.trim().replaceAll(RegExp(r'^/+|/+$'), '');
    if (normalized.isEmpty) {
      return StudioWorkspace.chat;
    }
    final head = normalized.split('/').first.toLowerCase();
    for (final workspace in StudioWorkspace.values) {
      if (workspace.routeSegment == head) {
        return workspace;
      }
    }
    return StudioWorkspace.chat;
  }
}
