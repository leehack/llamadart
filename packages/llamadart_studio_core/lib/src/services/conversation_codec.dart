import 'dart:convert';

import '../domain/studio_conversation.dart';
import '../domain/studio_message.dart';

/// Exports and imports [StudioConversation] sessions as portable JSON or
/// readable Markdown transcripts.
class StudioConversationCodec {
  /// Creates a [StudioConversationCodec].
  const StudioConversationCodec();

  /// Encodes [conversation] as formatted, portable JSON (including all branches).
  String encodeJson(StudioConversation conversation) {
    const encoder = JsonEncoder.withIndent('  ');
    final portableNodes = <StudioMessage>[
      for (final node in conversation.nodes)
        node.copyWith(
          attachments: <StudioAttachment>[
            for (final attachment in node.attachments)
              _portableAttachment(attachment),
          ],
        ),
    ];
    return encoder.convert(
      conversation.copyWith(nodes: portableNodes).toJson(),
    );
  }

  static StudioAttachment _portableAttachment(StudioAttachment attachment) {
    if (attachment.bytes == null) {
      throw const FormatException(
        'Attachment media is unavailable. Restore or remove the attachment before exporting.',
      );
    }
    return StudioAttachment(
      id: attachment.id,
      kind: attachment.kind,
      name: attachment.name,
      mimeType: attachment.mimeType,
      bytes: attachment.bytes,
      sizeBytes: attachment.bytes!.length,
    );
  }

  /// Decodes a [StudioConversation] from a JSON string.
  StudioConversation decodeJson(String rawJson) {
    final decoded = jsonDecode(rawJson);
    if (decoded is! Map) {
      throw const FormatException('Conversation file must be a JSON object.');
    }
    final parsed = StudioConversation.fromJson(
      Map<String, Object?>.from(decoded),
    );
    return parsed.copyWith(
      nodes: <StudioMessage>[
        for (final node in parsed.nodes)
          node.copyWith(
            attachments: <StudioAttachment>[
              for (final attachment in node.attachments)
                _portableAttachment(attachment),
            ],
          ),
      ],
    );
  }

  /// Renders the active branch of [conversation] as GitHub-flavored Markdown.
  String encodeMarkdown(StudioConversation conversation) {
    final buffer = StringBuffer()
      ..writeln('# ${conversation.title}')
      ..writeln()
      ..writeln('- **Session ID**: `${conversation.id}`')
      ..writeln(
        '- **Updated**: `${conversation.updatedAt.toUtc().toIso8601String()}`',
      );
    if (conversation.systemPrompt.trim().isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('> **System Prompt**: ${conversation.systemPrompt.trim()}');
    }
    for (final message in conversation.activeBranch) {
      final heading = switch (message.role) {
        StudioRole.user => '## User',
        StudioRole.assistant => '## Assistant',
        StudioRole.system => '## System',
        StudioRole.tool => '## Tool',
      };
      buffer
        ..writeln()
        ..writeln(heading)
        ..writeln();
      if (message.hasThinking) {
        buffer
          ..writeln('<details>')
          ..writeln('<summary>Thought process</summary>')
          ..writeln()
          ..writeln(message.thinkingText!.trim())
          ..writeln()
          ..writeln('</details>')
          ..writeln();
      }
      for (final call in message.toolCalls) {
        buffer
          ..writeln('- **Tool `${call.name}`**: `${call.argumentsJson}`')
          ..writeln(
            call.resultJson != null ? '  - Result: `${call.resultJson}`' : '',
          );
      }
      if (message.toolCalls.isNotEmpty) {
        buffer.writeln();
      }
      buffer.writeln(message.text.trim());
      if (message.metrics != null) {
        final metrics = message.metrics!;
        final speed = metrics.tokensPerSecond.toStringAsFixed(1);
        final ttft = metrics.firstTokenLatencyMs != null
            ? ' · TTFT ${metrics.firstTokenLatencyMs} ms'
            : '';
        buffer
          ..writeln()
          ..writeln('_$speed tok/s$ttft · ${metrics.generatedTokens} tokens_');
      }
    }
    return buffer.toString();
  }
}
