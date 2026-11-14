import 'dart:convert';
import 'dart:typed_data';

import 'package:llamadart/llamadart.dart';
import 'package:meta/meta.dart';

/// Explicit author/turn role in a Studio conversation.
enum StudioRole {
  /// System instruction turn.
  system,

  /// Human user turn.
  user,

  /// Model assistant reply turn.
  assistant,

  /// Tool execution result turn.
  tool,
}

/// Kind of media attached to a [StudioMessage].
enum StudioAttachmentKind {
  /// Raster image attachment (PNG, JPEG, WebP).
  image,

  /// Audio clip attachment (WAV, MP3, PCM).
  audio,
}

/// Media attachment carried on a user or assistant message.
@immutable
class StudioAttachment {
  /// Creates a [StudioAttachment].
  const StudioAttachment({
    required this.id,
    required this.kind,
    required this.name,
    this.mimeType,
    this.localPath,
    this.bytes,
    this.sizeBytes,
  });

  /// Unique identifier within the conversation.
  final String id;

  /// Modality kind (image or audio).
  final StudioAttachmentKind kind;

  /// Display filename or label.
  final String name;

  /// Optional MIME type such as `image/png` or `audio/wav`.
  final String? mimeType;

  /// Optional filesystem path when stored off-heap on native platforms.
  final String? localPath;

  /// Optional encoded bytes (used on Web or before off-heap flush).
  final Uint8List? bytes;

  /// Known byte size even when bytes are stored on disk.
  final int? sizeBytes;

  /// Effective byte count of this attachment.
  int get effectiveSizeBytes => sizeBytes ?? bytes?.length ?? 0;

  /// Converts this attachment into a `llamadart` [LlamaContentPart].
  LlamaContentPart toLlamaContentPart() {
    switch (kind) {
      case StudioAttachmentKind.image:
        return LlamaImageContent(path: localPath, bytes: bytes);
      case StudioAttachmentKind.audio:
        return LlamaAudioContent(path: localPath, bytes: bytes);
    }
  }

  /// Serializes metadata (and compact inline bytes when no path exists).
  Map<String, Object?> toJson({bool includeInlineBytes = true}) {
    return <String, Object?>{
      'id': id,
      'kind': kind.name,
      'name': name,
      if (mimeType != null) 'mimeType': mimeType,
      if (localPath != null) 'localPath': localPath,
      if (sizeBytes != null || bytes != null) 'sizeBytes': effectiveSizeBytes,
      if (includeInlineBytes && localPath == null && bytes != null)
        'bytesBase64': base64Encode(bytes!),
    };
  }

  /// Restores a [StudioAttachment] from JSON.
  factory StudioAttachment.fromJson(Map<String, Object?> json) {
    final rawKind = json['kind'] as String?;
    final kind = StudioAttachmentKind.values.firstWhere(
      (value) => value.name == rawKind,
      orElse: () => StudioAttachmentKind.image,
    );
    final rawBase64 = json['bytesBase64'] as String?;
    final decodedBytes = rawBase64 != null && rawBase64.isNotEmpty
        ? Uint8List.fromList(base64Decode(rawBase64))
        : null;
    return StudioAttachment(
      id: (json['id'] as String?) ?? 'att',
      kind: kind,
      name: (json['name'] as String?) ?? 'attachment',
      mimeType: json['mimeType'] as String?,
      localPath: json['localPath'] as String?,
      bytes: decodedBytes,
      sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? decodedBytes?.length,
    );
  }
}

/// Recorded tool call and its result inside an assistant turn.
@immutable
class StudioToolInvocation {
  /// Creates a [StudioToolInvocation].
  const StudioToolInvocation({
    required this.id,
    required this.name,
    required this.argumentsJson,
    this.resultJson,
    this.durationMs,
    this.isRunning = false,
    this.isError = false,
  });

  /// Tool call identifier.
  final String id;

  /// Function/tool name invoked by the model.
  final String name;

  /// Raw or pretty JSON arguments passed to the tool.
  final String argumentsJson;

  /// JSON-encoded output returned by the tool handler.
  final String? resultJson;

  /// Wall-clock execution time of the tool handler in milliseconds.
  final int? durationMs;

  /// Whether the handler is still executing.
  final bool isRunning;

  /// Whether the handler returned an error payload.
  final bool isError;

  /// Returns a copy with updated tool execution state.
  StudioToolInvocation copyWith({
    String? id,
    String? name,
    String? argumentsJson,
    String? resultJson,
    int? durationMs,
    bool? isRunning,
    bool? isError,
  }) {
    return StudioToolInvocation(
      id: id ?? this.id,
      name: name ?? this.name,
      argumentsJson: argumentsJson ?? this.argumentsJson,
      resultJson: resultJson ?? this.resultJson,
      durationMs: durationMs ?? this.durationMs,
      isRunning: isRunning ?? this.isRunning,
      isError: isError ?? this.isError,
    );
  }

  /// Serializes this invocation to JSON.
  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'name': name,
      'argumentsJson': argumentsJson,
      if (resultJson != null) 'resultJson': resultJson,
      if (durationMs != null) 'durationMs': durationMs,
      'isRunning': isRunning,
      'isError': isError,
    };
  }

  /// Restores a [StudioToolInvocation] from JSON.
  factory StudioToolInvocation.fromJson(Map<String, Object?> json) {
    return StudioToolInvocation(
      id: (json['id'] as String?) ?? 'call',
      name: (json['name'] as String?) ?? 'tool',
      argumentsJson: (json['argumentsJson'] as String?) ?? '{}',
      resultJson: json['resultJson'] as String?,
      durationMs: (json['durationMs'] as num?)?.toInt(),
      isRunning: (json['isRunning'] as bool?) ?? false,
      isError: (json['isError'] as bool?) ?? false,
    );
  }
}

/// Telemetry recorded for a completed assistant generation turn.
@immutable
class StudioTurnMetrics {
  /// Creates [StudioTurnMetrics].
  const StudioTurnMetrics({
    required this.generatedTokens,
    required this.elapsedMs,
    required this.decodeElapsedMs,
    this.promptTokens,
    this.firstTokenLatencyMs,
    this.reachedTokenLimit = false,
    this.modelName,
    this.backendLabel,
  });

  /// Number of completion tokens generated.
  final int generatedTokens;

  /// Total wall-clock turn duration in milliseconds.
  final int elapsedMs;

  /// Decode-phase duration in milliseconds after first token.
  final int decodeElapsedMs;

  /// Optional prompt token count evaluated for this turn.
  final int? promptTokens;

  /// Time-to-first-token (TTFT) in milliseconds.
  final int? firstTokenLatencyMs;

  /// Whether generation stopped because `maxTokens` was reached.
  final bool reachedTokenLimit;

  /// Model label active when this turn was generated.
  final String? modelName;

  /// Hardware backend label active when this turn was generated.
  final String? backendLabel;

  /// Decode throughput in tokens per second.
  double get tokensPerSecond {
    final effectiveMs = decodeElapsedMs > 0 ? decodeElapsedMs : elapsedMs;
    if (generatedTokens <= 0 || effectiveMs <= 0) {
      return 0;
    }
    return (generatedTokens * 1000.0) / effectiveMs;
  }

  /// Serializes turn metrics to JSON.
  Map<String, Object?> toJson() {
    return <String, Object?>{
      'generatedTokens': generatedTokens,
      'elapsedMs': elapsedMs,
      'decodeElapsedMs': decodeElapsedMs,
      if (promptTokens != null) 'promptTokens': promptTokens,
      if (firstTokenLatencyMs != null)
        'firstTokenLatencyMs': firstTokenLatencyMs,
      'reachedTokenLimit': reachedTokenLimit,
      if (modelName != null) 'modelName': modelName,
      if (backendLabel != null) 'backendLabel': backendLabel,
    };
  }

  /// Restores [StudioTurnMetrics] from JSON.
  factory StudioTurnMetrics.fromJson(Map<String, Object?> json) {
    return StudioTurnMetrics(
      generatedTokens: (json['generatedTokens'] as num?)?.toInt() ?? 0,
      elapsedMs: (json['elapsedMs'] as num?)?.toInt() ?? 0,
      decodeElapsedMs: (json['decodeElapsedMs'] as num?)?.toInt() ?? 0,
      promptTokens: (json['promptTokens'] as num?)?.toInt(),
      firstTokenLatencyMs: (json['firstTokenLatencyMs'] as num?)?.toInt(),
      reachedTokenLimit: (json['reachedTokenLimit'] as bool?) ?? false,
      modelName: json['modelName'] as String?,
      backendLabel: json['backendLabel'] as String?,
    );
  }
}

/// Immutable node in a Studio conversation tree.
///
/// Unlike flat chat histories, [parentId] allows non-destructive editing and
/// regeneration branches without losing previous model responses.
@immutable
class StudioMessage {
  /// Creates a [StudioMessage] node.
  const StudioMessage({
    required this.id,
    required this.role,
    required this.text,
    required this.createdAt,
    this.parentId,
    this.thinkingText,
    this.thinkingDurationMs,
    this.attachments = const <StudioAttachment>[],
    this.toolCalls = const <StudioToolInvocation>[],
    this.metrics,
    this.isStreaming = false,
    this.isError = false,
  });

  /// Unique message node identifier.
  final String id;

  /// Parent message identifier (`null` for the first message of a branch).
  final String? parentId;

  /// Author/turn role. Never inferred heuristically from `{...}` JSON text.
  final StudioRole role;

  /// Visible markdown or structured JSON body.
  final String text;

  /// Optional reasoning / chain-of-thought content.
  final String? thinkingText;

  /// Duration spent generating [thinkingText] in milliseconds.
  final int? thinkingDurationMs;

  /// Multimodal attachments sent with or produced by this message.
  final List<StudioAttachment> attachments;

  /// Explicit tool calls invoked during this assistant turn.
  final List<StudioToolInvocation> toolCalls;

  /// Performance telemetry for completed assistant turns.
  final StudioTurnMetrics? metrics;

  /// Creation timestamp (UTC).
  final DateTime createdAt;

  /// Whether tokens are actively streaming into this message.
  final bool isStreaming;

  /// Whether this message represents a runtime/inference error notice.
  final bool isError;

  /// Whether non-empty chain-of-thought text is attached.
  bool get hasThinking =>
      thinkingText != null && thinkingText!.trim().isNotEmpty;

  /// Whether explicit tool invocations occurred in this turn.
  bool get hasToolCalls => toolCalls.isNotEmpty;

  /// Converts this message into a `llamadart` [LlamaChatMessage] for replay.
  LlamaChatMessage toLlamaChatMessage() {
    final llamaRole = switch (role) {
      StudioRole.system => LlamaChatRole.system,
      StudioRole.user => LlamaChatRole.user,
      StudioRole.assistant => LlamaChatRole.assistant,
      StudioRole.tool => LlamaChatRole.tool,
    };
    if (attachments.isEmpty && !hasThinking) {
      return LlamaChatMessage.fromText(role: llamaRole, text: text);
    }
    final parts = <LlamaContentPart>[
      if (hasThinking) LlamaThinkingContent(thinkingText!),
      for (final attachment in attachments) attachment.toLlamaContentPart(),
      if (text.isNotEmpty) LlamaTextContent(text),
    ];
    return LlamaChatMessage.withContent(role: llamaRole, content: parts);
  }

  /// Returns a copy of this message with updated fields.
  StudioMessage copyWith({
    String? id,
    String? parentId,
    StudioRole? role,
    String? text,
    String? thinkingText,
    bool clearThinking = false,
    int? thinkingDurationMs,
    List<StudioAttachment>? attachments,
    List<StudioToolInvocation>? toolCalls,
    StudioTurnMetrics? metrics,
    DateTime? createdAt,
    bool? isStreaming,
    bool? isError,
  }) {
    return StudioMessage(
      id: id ?? this.id,
      parentId: parentId ?? this.parentId,
      role: role ?? this.role,
      text: text ?? this.text,
      thinkingText: clearThinking ? null : (thinkingText ?? this.thinkingText),
      thinkingDurationMs: thinkingDurationMs ?? this.thinkingDurationMs,
      attachments: attachments ?? this.attachments,
      toolCalls: toolCalls ?? this.toolCalls,
      metrics: metrics ?? this.metrics,
      createdAt: createdAt ?? this.createdAt,
      isStreaming: isStreaming ?? this.isStreaming,
      isError: isError ?? this.isError,
    );
  }

  /// Serializes this message node to JSON.
  Map<String, Object?> toJson({bool includeInlineAttachmentBytes = true}) {
    return <String, Object?>{
      'id': id,
      if (parentId != null) 'parentId': parentId,
      'role': role.name,
      'text': text,
      if (thinkingText != null) 'thinkingText': thinkingText,
      if (thinkingDurationMs != null) 'thinkingDurationMs': thinkingDurationMs,
      if (attachments.isNotEmpty)
        'attachments': attachments
            .map(
              (item) =>
                  item.toJson(includeInlineBytes: includeInlineAttachmentBytes),
            )
            .toList(growable: false),
      if (toolCalls.isNotEmpty)
        'toolCalls': toolCalls.map((call) => call.toJson()).toList(),
      if (metrics != null) 'metrics': metrics!.toJson(),
      'createdAt': createdAt.toUtc().toIso8601String(),
      if (isError) 'isError': true,
    };
  }

  /// Restores a [StudioMessage] node from JSON.
  factory StudioMessage.fromJson(Map<String, Object?> json) {
    final rawRole = json['role'] as String?;
    final role = StudioRole.values.firstWhere(
      (value) => value.name == rawRole,
      orElse: () => StudioRole.assistant,
    );
    final rawAttachments = json['attachments'];
    final attachments = rawAttachments is List
        ? rawAttachments
              .whereType<Map<Object?, Object?>>()
              .map(
                (entry) =>
                    StudioAttachment.fromJson(Map<String, Object?>.from(entry)),
              )
              .toList(growable: false)
        : const <StudioAttachment>[];
    final rawTools = json['toolCalls'];
    final toolCalls = rawTools is List
        ? rawTools
              .whereType<Map<Object?, Object?>>()
              .map(
                (entry) => StudioToolInvocation.fromJson(
                  Map<String, Object?>.from(entry),
                ),
              )
              .toList(growable: false)
        : const <StudioToolInvocation>[];
    final rawMetrics = json['metrics'];
    final createdAtRaw = json['createdAt'] as String?;

    return StudioMessage(
      id: (json['id'] as String?) ?? 'msg',
      parentId: json['parentId'] as String?,
      role: role,
      text: (json['text'] as String?) ?? '',
      thinkingText: json['thinkingText'] as String?,
      thinkingDurationMs: (json['thinkingDurationMs'] as num?)?.toInt(),
      attachments: attachments,
      toolCalls: toolCalls,
      metrics: rawMetrics is Map
          ? StudioTurnMetrics.fromJson(Map<String, Object?>.from(rawMetrics))
          : null,
      createdAt:
          DateTime.tryParse(createdAtRaw ?? '')?.toUtc() ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      isError: (json['isError'] as bool?) ?? false,
    );
  }
}
