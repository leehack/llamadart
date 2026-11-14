import 'dart:math' as math;

import 'package:meta/meta.dart';

/// Origin modality of a note stored in Studio's Multimodal Notebook.
enum StudioNoteSourceKind {
  /// Plain Markdown or typed note.
  text('Note'),

  /// Live microphone recording or imported audio clip.
  audio('Audio'),

  /// Imported image/whiteboard/screenshot attachment.
  image('Image'),

  /// Imported text/Markdown/code source document.
  file('File');

  const StudioNoteSourceKind(this.label);

  /// Human-readable source kind badge label.
  final String label;
}

/// Persistent local knowledge note stored in Studio's Multimodal Notebook and
/// indexed with local embedding vectors (including EmbeddingGemma 2 multimodal
/// image/audio+text vectors) for fast private retrieval and RAG.
@immutable
class StudioNote {
  /// Creates a [StudioNote].
  const StudioNote({
    required this.id,
    required this.title,
    required this.content,
    required this.createdAt,
    required this.updatedAt,
    this.tags = const <String>[],
    this.pinned = false,
    this.sourceKind = StudioNoteSourceKind.text,
    this.sourceFileName,
    this.imageBase64,
    this.imageLocalPath,
    this.imageMimeType,
    this.audioBase64,
    this.audioLocalPath,
    this.audioDurationMs,
    this.transcript,
    this.embedding,
    this.embeddingModelId,
    this.isMultimodalIndexed = false,
  });

  /// Unique note identifier.
  final String id;

  /// Short note heading used as document title for asymmetric embedders.
  final String title;

  /// Full Markdown/plain note body.
  final String content;

  /// Creation timestamp.
  final DateTime createdAt;

  /// Last modification timestamp.
  final DateTime updatedAt;

  /// Optional topic or triage tags.
  final List<String> tags;

  /// Whether the note is pinned at the top of the notebook list.
  final bool pinned;

  /// Primary source modality (`text`, `audio`, `image`, or `file`).
  final StudioNoteSourceKind sourceKind;

  /// Original filename when imported from disk.
  final String? sourceFileName;

  /// Optional base64-encoded image attachment (used on Web or before off-heap flush).
  final String? imageBase64;

  /// Optional off-heap local filesystem path to the stored image attachment.
  final String? imageLocalPath;

  /// MIME type for the attached image (e.g. `image/png`).
  final String? imageMimeType;

  /// Optional base64-encoded 16 kHz mono WAV audio recording/clip (used on Web or before off-heap flush).
  final String? audioBase64;

  /// Optional off-heap local filesystem path to the stored WAV audio clip.
  final String? audioLocalPath;

  /// Optional audio duration in milliseconds.
  final int? audioDurationMs;

  /// Optional local ASR transcript generated from the attached audio.
  final String? transcript;

  /// Cached L2-normalized embedding vector from [embeddingModelId].
  final List<double>? embedding;

  /// Model identifier that produced [embedding].
  final String? embeddingModelId;

  /// Whether [embedding] incorporated raw image/audio content via multimodal
  /// `embedContent(...)` rather than text-only fallback.
  final bool isMultimodalIndexed;

  /// Whether this note currently holds a stored vector.
  bool get isIndexed => embedding != null && embedding!.isNotEmpty;

  /// Whether this note carries an attached image (inline or off-heap).
  bool get hasImage =>
      (imageBase64 != null && imageBase64!.isNotEmpty) ||
      (imageLocalPath != null && imageLocalPath!.isNotEmpty);

  /// Whether this note carries an attached audio recording/clip (inline or off-heap).
  bool get hasAudio =>
      (audioBase64 != null && audioBase64!.isNotEmpty) ||
      (audioLocalPath != null && audioLocalPath!.isNotEmpty);

  /// Combined text representation used for retrieval, prompt grounding, and
  /// text-only embedding fallback.
  String get searchableText {
    final parts = <String>[
      if (title.trim().isNotEmpty) title.trim(),
      if (transcript != null && transcript!.trim().isNotEmpty)
        'Transcript:\n${transcript!.trim()}',
      if (content.trim().isNotEmpty) content.trim(),
    ];
    return parts.join('\n\n');
  }

  /// Returns an updated copy of this note.
  StudioNote copyWith({
    String? title,
    String? content,
    DateTime? updatedAt,
    List<String>? tags,
    bool? pinned,
    StudioNoteSourceKind? sourceKind,
    String? sourceFileName,
    String? imageBase64,
    bool clearImageBase64 = false,
    String? imageLocalPath,
    bool clearImageLocalPath = false,
    String? imageMimeType,
    bool clearImage = false,
    String? audioBase64,
    bool clearAudioBase64 = false,
    String? audioLocalPath,
    bool clearAudioLocalPath = false,
    int? audioDurationMs,
    bool clearAudio = false,
    String? transcript,
    bool clearTranscript = false,
    List<double>? embedding,
    String? embeddingModelId,
    bool? isMultimodalIndexed,
    bool clearEmbedding = false,
  }) {
    return StudioNote(
      id: id,
      title: title ?? this.title,
      content: content ?? this.content,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      tags: tags ?? this.tags,
      pinned: pinned ?? this.pinned,
      sourceKind: sourceKind ?? this.sourceKind,
      sourceFileName: sourceFileName ?? this.sourceFileName,
      imageBase64: (clearImage || clearImageBase64)
          ? null
          : (imageBase64 ?? this.imageBase64),
      imageLocalPath: (clearImage || clearImageLocalPath)
          ? null
          : (imageLocalPath ?? this.imageLocalPath),
      imageMimeType: clearImage ? null : (imageMimeType ?? this.imageMimeType),
      audioBase64: (clearAudio || clearAudioBase64)
          ? null
          : (audioBase64 ?? this.audioBase64),
      audioLocalPath: (clearAudio || clearAudioLocalPath)
          ? null
          : (audioLocalPath ?? this.audioLocalPath),
      audioDurationMs: clearAudio
          ? null
          : (audioDurationMs ?? this.audioDurationMs),
      transcript: clearTranscript ? null : (transcript ?? this.transcript),
      embedding: clearEmbedding ? null : (embedding ?? this.embedding),
      embeddingModelId: clearEmbedding
          ? null
          : (embeddingModelId ?? this.embeddingModelId),
      isMultimodalIndexed: clearEmbedding
          ? false
          : (isMultimodalIndexed ?? this.isMultimodalIndexed),
    );
  }

  /// Serializes this note to JSON for persistence.
  Map<String, Object?> toJson({bool includeInlineMedia = true}) {
    return <String, Object?>{
      'id': id,
      'title': title,
      'content': content,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'tags': tags,
      'pinned': pinned,
      'sourceKind': sourceKind.name,
      if (sourceFileName != null) 'sourceFileName': sourceFileName,
      if (includeInlineMedia && imageBase64 != null) 'imageBase64': imageBase64,
      if (imageLocalPath != null) 'imageLocalPath': imageLocalPath,
      if (imageMimeType != null) 'imageMimeType': imageMimeType,
      if (includeInlineMedia && audioBase64 != null) 'audioBase64': audioBase64,
      if (audioLocalPath != null) 'audioLocalPath': audioLocalPath,
      if (audioDurationMs != null) 'audioDurationMs': audioDurationMs,
      if (transcript != null) 'transcript': transcript,
      if (embedding != null) 'embedding': embedding,
      if (embeddingModelId != null) 'embeddingModelId': embeddingModelId,
      if (isMultimodalIndexed) 'isMultimodalIndexed': true,
    };
  }

  /// Restores a [StudioNote] from JSON.
  factory StudioNote.fromJson(Map<String, Object?> json) {
    final rawTags = json['tags'];
    final rawVec = json['embedding'];
    final kindName = json['sourceKind'] as String?;
    final kind = StudioNoteSourceKind.values.firstWhere(
      (StudioNoteSourceKind k) => k.name == kindName,
      orElse: () => StudioNoteSourceKind.text,
    );
    return StudioNote(
      id:
          (json['id'] as String?) ??
          'note_${DateTime.now().microsecondsSinceEpoch}',
      title: (json['title'] as String?) ?? 'Untitled Note',
      content: (json['content'] as String?) ?? '',
      createdAt:
          DateTime.tryParse((json['createdAt'] as String?) ?? '') ??
          DateTime.now(),
      updatedAt:
          DateTime.tryParse((json['updatedAt'] as String?) ?? '') ??
          DateTime.now(),
      tags: rawTags is List
          ? rawTags.whereType<String>().toList(growable: false)
          : const <String>[],
      pinned: (json['pinned'] as bool?) ?? false,
      sourceKind: kind,
      sourceFileName: json['sourceFileName'] as String?,
      imageBase64: json['imageBase64'] as String?,
      imageLocalPath: json['imageLocalPath'] as String?,
      imageMimeType: json['imageMimeType'] as String?,
      audioBase64: json['audioBase64'] as String?,
      audioLocalPath: json['audioLocalPath'] as String?,
      audioDurationMs: (json['audioDurationMs'] as num?)?.toInt(),
      transcript: json['transcript'] as String?,
      embedding: rawVec is List
          ? rawVec
                .whereType<num>()
                .map((num n) => n.toDouble())
                .toList(growable: false)
          : null,
      embeddingModelId: json['embeddingModelId'] as String?,
      isMultimodalIndexed: (json['isMultimodalIndexed'] as bool?) ?? false,
    );
  }

  /// Starter notes seeded on first boot to showcase genuine developer workflows.
  static List<StudioNote> starterNotes({DateTime? now}) {
    final ts = now ?? DateTime.now();
    return <StudioNote>[
      StudioNote(
        id: 'note_starter_kv_cache',
        title: 'KV Cache & FlashAttention Memory Math',
        content:
            'Quantizing K/V cache from F16 to Q8_0 cuts context memory nearly in half '
            'with minimal perplexity loss, while Q4_0 reduces it further for long-context '
            'sessions. llama.cpp requires FlashAttention enabled when K or V is quantized.',
        tags: const <String>['memory', 'tuning', 'metal'],
        pinned: true,
        createdAt: ts.subtract(const Duration(minutes: 40)),
        updatedAt: ts.subtract(const Duration(minutes: 40)),
      ),
      StudioNote(
        id: 'note_starter_rag_pipeline',
        title: 'Two-Stage Retrieval: Bi-Encoder + Cross-Encoder Rerank',
        content:
            'Bi-encoder embeddings (EmbeddingGemma, Nomic) map notes to vectors once so '
            'cosine similarity scans thousands of notes in milliseconds. Passing the top-K '
            'hits through a cross-encoder reranker (BGE Reranker v2 M3) yields sharp ranking.',
        tags: const <String>['embeddings', 'rag', 'reranker'],
        createdAt: ts.subtract(const Duration(minutes: 30)),
        updatedAt: ts.subtract(const Duration(minutes: 30)),
      ),
      StudioNote(
        id: 'note_starter_decision_engine',
        title: 'System-1 Decision Engine Single-Pass Routing',
        content:
            'DecisionEngine evaluates ChoiceKey, ScoreKey, and NoulKey heads in a single '
            'encoder forward pass without autoregressive token decoding—ideal for model '
            'routing, prompt preflight safety checks, and batch note triage.',
        tags: const <String>['decision', 'system-1', 'routing'],
        createdAt: ts.subtract(const Duration(minutes: 20)),
        updatedAt: ts.subtract(const Duration(minutes: 20)),
      ),
      StudioNote(
        id: 'note_starter_coding_mcp',
        title: 'Coding Agent + MCP + SKILL.md Conventions',
        content:
            'Point Studio Coding at any repository to inspect files, search code, and '
            'apply targeted patches inside a path-sandboxed root. Attach mcp_dart stdio '
            'or HTTP servers for external tools and load SKILL.md workflows automatically.',
        tags: const <String>['coding', 'mcp', 'skills'],
        createdAt: ts.subtract(const Duration(minutes: 10)),
        updatedAt: ts.subtract(const Duration(minutes: 10)),
      ),
    ];
  }

  /// Computes cosine similarity between two equal-length vectors.
  static double cosineSimilarity(List<double> a, List<double> b) {
    final len = math.min(a.length, b.length);
    if (len == 0) {
      return 0.0;
    }
    var dot = 0.0;
    var normA = 0.0;
    var normB = 0.0;
    for (var i = 0; i < len; i++) {
      final va = a[i];
      final vb = b[i];
      dot += va * vb;
      normA += va * va;
      normB += vb * vb;
    }
    final denom = math.sqrt(normA) * math.sqrt(normB);
    if (denom <= 0) {
      return 0.0;
    }
    return (dot / denom).clamp(-1.0, 1.0);
  }
}

/// Ranked result returned by Semantic Note Vault search.
@immutable
class NoteSearchHit {
  /// Creates a [NoteSearchHit].
  const NoteSearchHit({
    required this.note,
    required this.cosineScore,
    this.rerankScore,
  });

  /// Matched note.
  final StudioNote note;

  /// Bi-encoder cosine similarity score (`-1.0 .. 1.0`).
  final double cosineScore;

  /// Optional cross-encoder reranker logit/score when two-stage reranking ran.
  final double? rerankScore;

  /// Primary score used to order hits (`rerankScore` when present, otherwise
  /// `cosineScore`).
  double get sortScore => rerankScore ?? cosineScore;
}
