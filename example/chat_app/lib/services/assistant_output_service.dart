import 'dart:convert';

import 'package:llamadart/llamadart.dart';

/// Handles assistant stream normalization and tool-call parsing.
class AssistantOutputService {
  const AssistantOutputService();

  ({String text, String thinking}) normalizeAssistantOutput({
    required String streamedContent,
    required String streamedThinking,
    required bool toolsEnabled,
    required ChatFormat? detectedChatFormat,
    required String Function(String response) cleanResponse,
  }) {
    var normalizedText = cleanResponse(streamedContent);
    var normalizedThinking = streamedThinking;

    final shouldParseForNormalization =
        toolsEnabled ||
        normalizedText.contains('<think>') ||
        normalizedText.contains('</think>') ||
        normalizedText.contains('<|think|>') ||
        normalizedText.contains('<|channel>') ||
        normalizedText.contains('<channel|>') ||
        normalizedText.trimLeft().startsWith('{');

    if (!shouldParseForNormalization) {
      return (text: normalizedText, thinking: normalizedThinking);
    }

    final parseFormat = _resolveParseFormat(detectedChatFormat);

    try {
      final parsed = ChatTemplateEngine.parse(
        parseFormat.index,
        streamedContent,
        parseToolCalls: true,
      );

      final parsedText = cleanResponse(parsed.content);
      if (parsed.hasToolCalls) {
        normalizedText = '';
      } else if (parsedText.isNotEmpty) {
        normalizedText = parsedText;
      }

      final parsedReasoning = parsed.reasoningContent?.trim();
      if (normalizedThinking.isEmpty &&
          parsedReasoning != null &&
          parsedReasoning.isNotEmpty) {
        normalizedThinking = parsedReasoning;
      }
    } catch (_) {
      // Keep streamed values when parsing fails.
    }

    if (normalizedThinking.isEmpty) {
      final extracted = _extractMinistralReasoningHeuristic(normalizedText);
      if (extracted != null) {
        normalizedThinking = extracted.reasoning;
        normalizedText = extracted.answer;
      }
    }

    return (text: normalizedText, thinking: normalizedThinking);
  }

  List<LlamaToolCallContent> parseToolCallsForDisplay({
    required String streamedContent,
    required ChatFormat? detectedChatFormat,
  }) {
    if (streamedContent.trim().isEmpty) {
      return const <LlamaToolCallContent>[];
    }

    final parseFormat = _resolveParseFormat(detectedChatFormat);

    try {
      final parsed = ChatTemplateEngine.parse(
        parseFormat.index,
        streamedContent,
        parseToolCalls: true,
      );

      if (!parsed.hasToolCalls) {
        return const <LlamaToolCallContent>[];
      }

      final calls = <LlamaToolCallContent>[];
      for (final toolCall in parsed.toolCalls) {
        final function = toolCall.function;
        final name = function?.name?.trim() ?? '';
        if (name.isEmpty) {
          continue;
        }

        final args = _decodeToolCallArguments(function?.arguments);
        calls.add(
          LlamaToolCallContent(
            id: toolCall.id,
            name: name,
            arguments: args,
            rawJson: jsonEncode(<String, dynamic>{
              'name': name,
              'arguments': args,
            }),
          ),
        );
      }

      return calls;
    } catch (_) {
      return const <LlamaToolCallContent>[];
    }
  }

  bool containsReasoningTag(String text) {
    return text.contains('<think>') ||
        text.contains('</think>') ||
        text.contains('<|think|>') ||
        text.contains('<|channel>') ||
        text.contains('<channel|>') ||
        text.contains('[THINK]') ||
        text.contains('[/THINK]');
  }

  List<String> buildAssistantDebugBadges({
    required ChatFormat? detectedChatFormat,
    required bool hadRawThinkingTags,
    required bool hadThinkingStream,
    required String finalThinking,
    required String finalText,
  }) {
    final badges = <String>[];
    final formatName = (detectedChatFormat ?? ChatFormat.generic).name;
    badges.add('fmt:$formatName');

    final hasFinalThinking = finalThinking.trim().isNotEmpty;
    final thinkingSource = hadThinkingStream
        ? 'stream'
        : hasFinalThinking && hadRawThinkingTags
        ? 'tag-parse'
        : hasFinalThinking
        ? 'parse'
        : 'none';
    badges.add('think:$thinkingSource');

    final trimmed = finalText.trimLeft();
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      badges.add('content:json');
    }

    return badges;
  }

  ChatFormat _resolveParseFormat(ChatFormat? detectedChatFormat) {
    return detectedChatFormat == ChatFormat.contentOnly
        ? ChatFormat.generic
        : (detectedChatFormat ?? ChatFormat.generic);
  }

  Map<String, dynamic> _decodeToolCallArguments(String? rawArguments) {
    if (rawArguments == null || rawArguments.trim().isEmpty) {
      return const <String, dynamic>{};
    }

    try {
      final decoded = jsonDecode(rawArguments);
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    } catch (_) {
      // Keep empty arguments on decode failure.
    }

    return const <String, dynamic>{};
  }

  ({String reasoning, String answer})? _extractMinistralReasoningHeuristic(
    String text,
  ) {
    final trimmed = text.trim();
    if (trimmed.length < 64) {
      return null;
    }

    final repeatedQuotedAnswer = RegExp(
      r'^(.*?)(?:\n+\s*(?:Response|Final answer|Answer)\s*:\s*)?"([^"\n]{4,})"\s*(?:\2)?\s*$',
      dotAll: true,
    ).firstMatch(trimmed);

    if (repeatedQuotedAnswer != null) {
      final reasoning = repeatedQuotedAnswer.group(1)?.trim() ?? '';
      final answer = repeatedQuotedAnswer.group(2)?.trim() ?? '';
      if (reasoning.length >= 24 && answer.isNotEmpty) {
        return (reasoning: reasoning, answer: answer);
      }
    }

    final plainTailAnswer = RegExp(
      r'^(.*?)(?:\n+\s*(?:Response|Final answer|Answer)\s*:\s*)([^\n]{4,})\s*$',
      dotAll: true,
    ).firstMatch(trimmed);

    if (plainTailAnswer != null) {
      final reasoning = plainTailAnswer.group(1)?.trim() ?? '';
      final answer = plainTailAnswer.group(2)?.trim() ?? '';
      if (reasoning.length >= 24 && answer.isNotEmpty) {
        return (reasoning: reasoning, answer: answer);
      }
    }

    return null;
  }
}
