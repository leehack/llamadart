import 'dart:async';

import '../llama_logger.dart';
import '../models/chat/chat_template_result.dart';
import '../models/chat/completion_chunk.dart';
import '../models/inference/generation_usage.dart';
import '../models/tools/tool_definition.dart';
import '../template/chat_format.dart';
import '../template/chat_template_engine.dart';
import '../template/handlers/hermes_handler.dart';

enum _ToolStreamingMode { undecided, raw, parsed }

class _ThinkingSplitEmission {
  const _ThinkingSplitEmission({
    required this.text,
    required this.isThinking,
    this.endsThinking = false,
  });

  final String text;
  final bool isThinking;
  final bool endsThinking;
}

class _ThinkingSplitResult {
  const _ThinkingSplitResult({
    required this.pendingBuffer,
    required this.isThinking,
    required this.emissions,
  });

  final String pendingBuffer;
  final bool isThinking;
  final List<_ThinkingSplitEmission> emissions;
}

/// Parses generated token streams into OpenAI-style chat completion chunks.
///
/// This keeps the streaming parser state machine separate from [LlamaEngine]:
/// routing raw text vs structured tool envelopes, splitting thinking deltas,
/// suppressing partial tool-call envelopes, and reconciling final parsed output.
class ChatCompletionStreamParser {
  const ChatCompletionStreamParser._();

  /// Parses [tokenStream] into incremental content, thinking, and tool chunks.
  ///
  /// Without tool calls, the final chunk's finish reason is `length` when
  /// [stoppedAtLimit] returns true after [tokenStream] ends, and `stop`
  /// otherwise. The final chunk carries what [usage] returns after
  /// [tokenStream] ends.
  static Stream<LlamaCompletionChunk> parse({
    required Stream<String> tokenStream,
    required LlamaChatTemplateResult templateResult,
    required bool parseToolCallsEnabled,
    required bool enableThinking,
    required String modelName,
    required String completionId,
    List<ToolDefinition>? tools,
    bool Function()? stoppedAtLimit,
    LlamaGenerationUsage? Function()? usage,
  }) async* {
    final buffer = StringBuffer();
    var streamedContent = '';
    var streamedReasoning = '';
    const structuredPartialParseInterval = 8;
    const plainPartialParseProbeInterval = 4;
    const signalDrivenPartialParseMinTokens = 2;
    const partialParseMinIntervalMs = 24;
    var tokensSincePartialParse = 0;
    var sawStructuredOutputSignal = false;
    var didInitialPartialParse = false;
    var lastPartialParseAtMs = 0;
    final partialParseStopwatch = Stopwatch()..start();
    final hermesContent =
        parseToolCallsEnabled &&
            templateResult.format == ChatFormat.hermes.index
        ? _HermesContentGate()
        : null;
    final hermesReasoning = hermesContent != null
        ? _HermesReasoningGate(forcedOpen: templateResult.thinkingForcedOpen)
        : null;
    // A forced-open thought can transition straight into a tool envelope
    // without producing `</think>`. Start in parsed mode so that envelope is
    // never streamed as reasoning before the final structured parse. Hermes
    // parses such an envelope as reasoning.
    var streamingMode = hermesContent != null
        ? _ToolStreamingMode.raw
        : templateResult.thinkingForcedOpen ||
              _mayEmbedToolEnvelopeAfterContent(templateResult.format)
        ? _ToolStreamingMode.parsed
        : _ToolStreamingMode.undecided;
    var undecidedPrefix = '';
    final thinkingTags = ChatTemplateEngine.thinkingTagsFor(
      templateResult.format,
    );
    final startTag = thinkingTags.startTag;
    final endTag = thinkingTags.endTag;
    var isThinking = templateResult.thinkingForcedOpen;
    var pendingBuffer = '';
    final useStructuredStreaming =
        parseToolCallsEnabled ||
        templateResult.format == ChatFormat.gemma4.index;

    if (useStructuredStreaming) {
      await for (final token in tokenStream) {
        buffer.write(token);

        if (streamingMode == _ToolStreamingMode.undecided) {
          undecidedPrefix += token;
          final decisionPrefix = _stripLeadingThinkingForToolDecision(
            undecidedPrefix,
            startTag: startTag,
            endTag: endTag,
          );
          if (decisionPrefix == null) {
            continue;
          }
          final mode = _decideToolStreamingMode(decisionPrefix);
          if (mode == _ToolStreamingMode.undecided) {
            continue;
          }

          if (mode == _ToolStreamingMode.raw) {
            streamingMode = _ToolStreamingMode.raw;
          } else {
            streamingMode = _ToolStreamingMode.parsed;
            undecidedPrefix = '';
          }
        }

        if (streamingMode == _ToolStreamingMode.raw) {
          if (undecidedPrefix.isNotEmpty) {
            pendingBuffer += undecidedPrefix;
            undecidedPrefix = '';
          } else if (token.isNotEmpty) {
            pendingBuffer += token;
          }

          final split = _splitThinkingBuffer(
            pendingBuffer: pendingBuffer,
            isThinking: isThinking,
            startTag: startTag,
            endTag: endTag,
          );
          pendingBuffer = split.pendingBuffer;
          isThinking = split.isThinking;
          for (final emission in split.emissions) {
            var text = emission.text;
            if (emission.isThinking) {
              if (hermesReasoning != null) {
                text = hermesReasoning.add(text);
                if (emission.endsThinking) {
                  text += hermesReasoning.end();
                }
              }
              if (text.isEmpty) {
                continue;
              }
              streamedReasoning += text;
            } else {
              text = hermesContent?.add(text) ?? text;
              if (text.isEmpty) {
                continue;
              }
              streamedContent += text;
            }
            if (emission.isThinking && !enableThinking) {
              continue;
            }
            yield _chunk(
              completionId: completionId,
              modelName: modelName,
              delta: emission.isThinking
                  ? LlamaCompletionChunkDelta(thinking: text)
                  : LlamaCompletionChunkDelta(content: text),
            );
          }
          continue;
        }

        tokensSincePartialParse++;
        final tokenHasSignal = _mayNeedStructuredPartialParse(token);
        if (tokenHasSignal) {
          sawStructuredOutputSignal = true;
        }
        final elapsedMs = partialParseStopwatch.elapsedMilliseconds;
        final intervalElapsed =
            elapsedMs - lastPartialParseAtMs >= partialParseMinIntervalMs;
        final signalParseReady =
            tokenHasSignal &&
            intervalElapsed &&
            tokensSincePartialParse >= signalDrivenPartialParseMinTokens;
        final periodicParseReady =
            (sawStructuredOutputSignal &&
                tokensSincePartialParse >= structuredPartialParseInterval) ||
            (!sawStructuredOutputSignal &&
                tokensSincePartialParse >= plainPartialParseProbeInterval);
        final shouldRunPartialParse =
            !didInitialPartialParse || signalParseReady || periodicParseReady;
        if (!shouldRunPartialParse) {
          continue;
        }
        didInitialPartialParse = true;
        tokensSincePartialParse = 0;
        lastPartialParseAtMs = elapsedMs;

        try {
          final partialParsed = ChatTemplateEngine.parse(
            templateResult.format,
            buffer.toString(),
            isPartial: true,
            parseToolCalls: parseToolCallsEnabled,
            thinkingForcedOpen: templateResult.thinkingForcedOpen,
            parser: templateResult.parser,
            tools: tools,
          );

          final partialReasoning = partialParsed.reasoningContent ?? '';
          if (partialReasoning.length > streamedReasoning.length) {
            final delta = partialReasoning.substring(streamedReasoning.length);
            if (delta.isNotEmpty && enableThinking) {
              yield _chunk(
                completionId: completionId,
                modelName: modelName,
                delta: LlamaCompletionChunkDelta(thinking: delta),
              );
            }
          }

          final suppressToolEnvelopeContent =
              _isToolCallEnvelopeBuffer(
                buffer.toString(),
                startTag: startTag,
                endTag: endTag,
                thinkingForcedOpen: templateResult.thinkingForcedOpen,
              ) &&
              !partialParsed.hasToolCalls;
          if (!suppressToolEnvelopeContent &&
              partialParsed.content.length > streamedContent.length) {
            final delta = partialParsed.content.substring(
              streamedContent.length,
            );
            if (delta.isNotEmpty) {
              yield _chunk(
                completionId: completionId,
                modelName: modelName,
                delta: LlamaCompletionChunkDelta(content: delta),
              );
            }
          }

          if (partialReasoning.length >= streamedReasoning.length) {
            streamedReasoning = partialReasoning;
          }
          if (!suppressToolEnvelopeContent &&
              partialParsed.content.length >= streamedContent.length) {
            streamedContent = partialParsed.content;
          }
        } catch (_) {
          // Partial parser failures are expected during incremental generation.
          // Keep buffering and let the final parse determine structured output.
        }
      }

      // Whitespace-only output never provides enough signal to leave the
      // undecided state. Preserve it verbatim at EOF, while continuing to
      // withhold non-whitespace partial control-marker prefixes.
      if (streamingMode == _ToolStreamingMode.undecided &&
          undecidedPrefix.trim().isEmpty &&
          undecidedPrefix.isNotEmpty) {
        streamingMode = _ToolStreamingMode.raw;
        pendingBuffer += undecidedPrefix;
        undecidedPrefix = '';
      }

      if (hermesContent != null && hermesReasoning != null) {
        pendingBuffer = isThinking
            ? hermesReasoning.add(pendingBuffer) + hermesReasoning.end()
            : hermesContent.add(pendingBuffer);
      }
      if (streamingMode == _ToolStreamingMode.raw && pendingBuffer.isNotEmpty) {
        if (isThinking) {
          streamedReasoning += pendingBuffer;
        } else {
          streamedContent += pendingBuffer;
        }
        if (!isThinking || enableThinking) {
          yield _chunk(
            completionId: completionId,
            modelName: modelName,
            delta: isThinking
                ? LlamaCompletionChunkDelta(thinking: pendingBuffer)
                : LlamaCompletionChunkDelta(content: pendingBuffer),
          );
        }
      }
    } else {
      await for (final token in tokenStream) {
        buffer.write(token);
        pendingBuffer += token;
        final split = _splitThinkingBuffer(
          pendingBuffer: pendingBuffer,
          isThinking: isThinking,
          startTag: startTag,
          endTag: endTag,
        );
        pendingBuffer = split.pendingBuffer;
        isThinking = split.isThinking;
        for (final emission in split.emissions) {
          if (emission.text.isEmpty ||
              (emission.isThinking && !enableThinking)) {
            continue;
          }
          yield _chunk(
            completionId: completionId,
            modelName: modelName,
            delta: emission.isThinking
                ? LlamaCompletionChunkDelta(thinking: emission.text)
                : LlamaCompletionChunkDelta(content: emission.text),
          );
        }
      }

      if (pendingBuffer.isNotEmpty && (!isThinking || enableThinking)) {
        yield _chunk(
          completionId: completionId,
          modelName: modelName,
          delta: isThinking
              ? LlamaCompletionChunkDelta(thinking: pendingBuffer)
              : LlamaCompletionChunkDelta(content: pendingBuffer),
        );
      }
    }

    final fullOutput = buffer.toString();
    final parsed = ChatTemplateEngine.parse(
      templateResult.format,
      fullOutput,
      parseToolCalls: parseToolCallsEnabled,
      thinkingForcedOpen: templateResult.thinkingForcedOpen,
      parser: templateResult.parser,
      tools: tools,
    );

    if (useStructuredStreaming) {
      final finalReasoning = parsed.reasoningContent ?? '';
      final reasoningDelta = _computeFinalReconciliationDelta(
        streamedValue: streamedReasoning,
        finalValue: finalReasoning,
        channel: 'thinking',
      );
      if (reasoningDelta != null &&
          reasoningDelta.isNotEmpty &&
          enableThinking) {
        yield _chunk(
          completionId: completionId,
          modelName: modelName,
          delta: LlamaCompletionChunkDelta(thinking: reasoningDelta),
        );
      }

      final suppressFinalToolEnvelopeContent =
          hermesContent == null &&
          parsed.hasToolCalls &&
          _isToolCallEnvelopeBuffer(
            fullOutput,
            startTag: startTag,
            endTag: endTag,
            thinkingForcedOpen: templateResult.thinkingForcedOpen,
          );
      final contentDelta = suppressFinalToolEnvelopeContent
          ? null
          : _computeFinalReconciliationDelta(
              streamedValue: streamedContent,
              finalValue: parsed.content,
              channel: 'content',
            );
      if (contentDelta != null && contentDelta.isNotEmpty) {
        yield _chunk(
          completionId: completionId,
          modelName: modelName,
          delta: LlamaCompletionChunkDelta(content: contentDelta),
        );
      }
    }

    LlamaLogger.instance.debug(
      'Parsed completion: contentChars=${parsed.content.length}, '
      'reasoningChars=${parsed.reasoningContent?.length ?? 0}, '
      'toolCallCount=${parsed.toolCalls.length}',
    );

    if (parsed.hasToolCalls) {
      final toolCallsWithIds = parsed.toolCalls
          .map(
            (toolCall) => LlamaCompletionChunkToolCall(
              index: toolCall.index,
              id: (toolCall.id == null || toolCall.id!.isEmpty)
                  ? 'call_${toolCall.index}'
                  : toolCall.id,
              type: toolCall.type,
              function: toolCall.function,
            ),
          )
          .toList(growable: false);
      yield _chunk(
        completionId: completionId,
        modelName: modelName,
        delta: LlamaCompletionChunkDelta(toolCalls: toolCallsWithIds),
        finishReason: 'tool_calls',
        usage: usage?.call(),
      );
    } else {
      yield _chunk(
        completionId: completionId,
        modelName: modelName,
        delta: LlamaCompletionChunkDelta(),
        finishReason: stoppedAtLimit?.call() == true ? 'length' : 'stop',
        usage: usage?.call(),
      );
    }
  }

  static LlamaCompletionChunk _chunk({
    required String completionId,
    required String modelName,
    required LlamaCompletionChunkDelta delta,
    String? finishReason,
    LlamaGenerationUsage? usage,
  }) {
    return LlamaCompletionChunk(
      id: 'chatcmpl-$completionId',
      object: 'chat.completion.chunk',
      created: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      model: modelName,
      choices: [
        LlamaCompletionChunkChoice(
          index: 0,
          delta: delta,
          finishReason: finishReason,
        ),
      ],
      usage: usage,
    );
  }

  static bool _mayNeedStructuredPartialParse(String token) {
    for (var i = 0; i < token.length; i++) {
      switch (token.codeUnitAt(i)) {
        case 0x22: // "
        case 0x2C: // ,
        case 0x3A: // :
        case 0x3C: // <
        case 0x3E: // >
        case 0x5B: // [
        case 0x5C: // \
        case 0x5D: // ]
        case 0x7B: // {
        case 0x7D: // }
          return true;
      }
    }
    return false;
  }

  static bool _mayEmbedToolEnvelopeAfterContent(int formatIndex) =>
      formatIndex == ChatFormat.kimiK3.index ||
      formatIndex == ChatFormat.minimaxM1.index ||
      formatIndex == ChatFormat.minimaxM3.index ||
      formatIndex == ChatFormat.deepseekV32.index ||
      formatIndex == ChatFormat.deepseekV4.index ||
      formatIndex == ChatFormat.museGlimmer.index ||
      formatIndex == ChatFormat.glm45.index ||
      formatIndex == ChatFormat.laguna.index ||
      formatIndex == ChatFormat.gemma4.index;

  static int? _firstNonWhitespaceIndex(String value) {
    for (var i = 0; i < value.length; i++) {
      if (!_isWhitespaceCodeUnit(value.codeUnitAt(i))) {
        return i;
      }
    }
    return null;
  }

  static _ToolStreamingMode _decideToolStreamingMode(String value) {
    const maxProbeChars = 256;
    final start = _firstNonWhitespaceIndex(value);
    if (start == null) {
      return _ToolStreamingMode.undecided;
    }

    final trimmed = value.substring(start);
    if (trimmed.isEmpty) {
      return _ToolStreamingMode.undecided;
    }

    final first = trimmed.codeUnitAt(0);
    _ToolStreamingMode mode;
    if (first == 0x7B) {
      mode = _decideJsonEnvelopeMode(trimmed);
    } else if (first == 0x3C) {
      mode = _decideXmlEnvelopeMode(trimmed);
    } else if (first == 0x5B) {
      mode = _decideBracketEnvelopeMode(trimmed);
    } else {
      mode = _ToolStreamingMode.raw;
    }

    if (mode == _ToolStreamingMode.undecided &&
        trimmed.length >= maxProbeChars) {
      return _ToolStreamingMode.raw;
    }

    return mode;
  }

  static String? _stripLeadingThinkingForToolDecision(
    String value, {
    required String startTag,
    required String endTag,
  }) {
    var remaining = value;
    while (true) {
      final start = _firstNonWhitespaceIndex(remaining);
      if (start == null) {
        return remaining;
      }

      final leading = remaining.substring(0, start);
      final trimmed = remaining.substring(start);
      if (startTag.startsWith(trimmed) || endTag.startsWith(trimmed)) {
        return null;
      }

      if (trimmed.startsWith(endTag)) {
        remaining = leading + trimmed.substring(endTag.length);
        continue;
      }

      if (trimmed.startsWith(startTag)) {
        final afterStart = trimmed.substring(startTag.length);
        final endIndex = afterStart.indexOf(endTag);
        if (endIndex < 0) {
          return null;
        }
        remaining = leading + afterStart.substring(endIndex + endTag.length);
        continue;
      }

      return remaining;
    }
  }

  static _ToolStreamingMode _decideJsonEnvelopeMode(String text) {
    var i = 1;
    while (i < text.length && _isWhitespaceCodeUnit(text.codeUnitAt(i))) {
      i++;
    }

    if (i >= text.length) {
      return _ToolStreamingMode.undecided;
    }

    if (text.codeUnitAt(i) != 0x22) {
      return _ToolStreamingMode.raw;
    }

    i++;
    final keyStart = i;
    while (i < text.length) {
      final ch = text.codeUnitAt(i);
      if (ch == 0x22) {
        final key = text.substring(keyStart, i);
        return _isGenericEnvelopeKey(key)
            ? _ToolStreamingMode.parsed
            : _ToolStreamingMode.raw;
      }
      if (ch == 0x5C) {
        if (i + 1 >= text.length) {
          return _ToolStreamingMode.undecided;
        }
        i += 2;
        continue;
      }
      i++;
    }

    return _ToolStreamingMode.undecided;
  }

  static bool _isGenericEnvelopeKey(String key) {
    return key == 'tool_call' ||
        key == 'tool_calls' ||
        key == 'response' ||
        key == 'name';
  }

  static bool _isToolCallEnvelopeBuffer(
    String text, {
    required String startTag,
    required String endTag,
    required bool thinkingForcedOpen,
  }) {
    if (thinkingForcedOpen &&
        _containsForcedOpenXmlToolEnvelope(text, endTag: endTag)) {
      return true;
    }

    final decisionText = _stripLeadingThinkingForToolDecision(
      text,
      startTag: startTag,
      endTag: endTag,
    );
    if (decisionText == null) {
      return true;
    }

    final start = _firstNonWhitespaceIndex(decisionText);
    if (start == null) {
      return false;
    }

    final trimmed = decisionText.substring(start);
    if (trimmed.isEmpty) {
      return false;
    }

    if (RegExp(r'^\{\s*"tool_calls?"\s*:').hasMatch(trimmed)) {
      return true;
    }

    final first = trimmed.codeUnitAt(0);
    if (first == 0x5B) {
      return _decideBracketEnvelopeMode(trimmed) != _ToolStreamingMode.raw;
    }
    if (first == 0x3C) {
      final lower = trimmed.toLowerCase();
      return lower.startsWith('<tool_call') ||
          lower.startsWith('<tool_calls') ||
          lower.startsWith('<|tool_call') ||
          lower.startsWith('<|start_action|>') ||
          lower.startsWith('<function') ||
          lower.startsWith('<function_call') ||
          lower.startsWith('<start_function_call') ||
          lower.startsWith('<|python_tag|>');
    }

    return false;
  }

  static bool _containsXmlToolEnvelope(String text) {
    final lower = text.toLowerCase();
    return lower.contains('<tool_call') ||
        lower.contains('<tool_calls') ||
        lower.contains('<function=') ||
        lower.contains('<function_call');
  }

  static bool _containsForcedOpenXmlToolEnvelope(
    String text, {
    required String endTag,
  }) {
    final thoughtEnd = text.indexOf(endTag);
    if (thoughtEnd < 0) {
      return _containsXmlToolEnvelope(text);
    }

    final afterThought = text.substring(thoughtEnd + endTag.length);
    final first = _firstNonWhitespaceIndex(afterThought);
    if (first == null) {
      return false;
    }
    final lower = afterThought.substring(first).toLowerCase();
    return lower.startsWith('<tool_call') ||
        lower.startsWith('<tool_calls') ||
        lower.startsWith('<function=') ||
        lower.startsWith('<function_call');
  }

  static _ToolStreamingMode _decideBracketEnvelopeMode(String text) {
    const marker = '[TOOL_CALLS]';
    final upper = text.toUpperCase();
    if (upper.startsWith(marker)) {
      return _ToolStreamingMode.parsed;
    }
    if (marker.startsWith(upper)) {
      return _ToolStreamingMode.undecided;
    }
    return _decideBareActionArrayEnvelopeMode(text);
  }

  static _ToolStreamingMode _decideBareActionArrayEnvelopeMode(String text) {
    var i = 1;
    while (i < text.length && _isWhitespaceCodeUnit(text.codeUnitAt(i))) {
      i++;
    }
    if (i >= text.length) {
      return _ToolStreamingMode.undecided;
    }
    if (text.codeUnitAt(i) != 0x7B) {
      return _ToolStreamingMode.raw;
    }

    i++;
    while (i < text.length && _isWhitespaceCodeUnit(text.codeUnitAt(i))) {
      i++;
    }
    if (i >= text.length) {
      return _ToolStreamingMode.undecided;
    }
    if (text.codeUnitAt(i) != 0x22) {
      return _ToolStreamingMode.raw;
    }

    final key = _readLeadingJsonObjectKey(text, i);
    if (!key.complete) {
      return _ToolStreamingMode.undecided;
    }
    if (key.value == null) {
      return _ToolStreamingMode.raw;
    }

    i = key.nextIndex;
    while (i < text.length && _isWhitespaceCodeUnit(text.codeUnitAt(i))) {
      i++;
    }
    if (i >= text.length) {
      return _ToolStreamingMode.undecided;
    }
    if (text.codeUnitAt(i) != 0x3A) {
      return _ToolStreamingMode.raw;
    }

    return _isCommandBareActionKey(key.value!)
        ? _ToolStreamingMode.parsed
        : _ToolStreamingMode.raw;
  }

  static ({bool complete, String? value, int nextIndex})
  _readLeadingJsonObjectKey(String text, int quoteIndex) {
    final buffer = StringBuffer();
    var i = quoteIndex + 1;
    while (i < text.length) {
      final ch = text.codeUnitAt(i);
      if (ch == 0x22) {
        return (complete: true, value: buffer.toString(), nextIndex: i + 1);
      }
      if (ch == 0x5C) {
        if (i + 1 >= text.length) {
          return (complete: false, value: null, nextIndex: i);
        }
        buffer.writeCharCode(text.codeUnitAt(i + 1));
        i += 2;
        continue;
      }
      buffer.writeCharCode(ch);
      i++;
    }

    return (complete: false, value: null, nextIndex: text.length);
  }

  static bool _isCommandBareActionKey(String key) {
    return key == 'tool_name' || key == 'tool_call_id';
  }

  static _ToolStreamingMode _decideXmlEnvelopeMode(String text) {
    final lower = text.toLowerCase();
    const parsedPrefixes = <String>[
      '<tool_call',
      '<tool_calls',
      '<|tool_call',
      '<|start_action|>',
      '<|start_text|>',
      '<function',
      '<function_call',
      '<start_function_call',
      '<|python_tag|>',
      '<tool_response',
    ];

    for (final prefix in parsedPrefixes) {
      if (lower.startsWith(prefix)) {
        return _ToolStreamingMode.parsed;
      }
      if (prefix.startsWith(lower)) {
        return _ToolStreamingMode.undecided;
      }
    }

    final tagNameMatch = RegExp(
      r'^<\s*/?\s*([a-zA-Z_][a-zA-Z0-9_:-]*)',
    ).firstMatch(lower);
    if (tagNameMatch != null) {
      final tagName = tagNameMatch.group(1);
      if (tagName == 'tool_call' ||
          tagName == 'tool_calls' ||
          tagName == 'function' ||
          tagName == 'function_call' ||
          tagName == 'start_function_call' ||
          tagName == 'tool_response') {
        return _ToolStreamingMode.parsed;
      }
      return _ToolStreamingMode.raw;
    }

    if (RegExp(r'^<\s*/?\s*[a-zA-Z_][a-zA-Z0-9_:-]*$').hasMatch(lower)) {
      return _ToolStreamingMode.undecided;
    }

    return _ToolStreamingMode.raw;
  }

  static _ThinkingSplitResult _splitThinkingBuffer({
    required String pendingBuffer,
    required bool isThinking,
    required String startTag,
    required String endTag,
  }) {
    final emissions = <_ThinkingSplitEmission>[];
    var localPendingBuffer = pendingBuffer;
    var localIsThinking = isThinking;

    while (localPendingBuffer.isNotEmpty) {
      if (!localIsThinking) {
        final startIdx = localPendingBuffer.indexOf(startTag);
        final endIdx = localPendingBuffer.indexOf(endTag);

        if (startIdx != -1 && (endIdx == -1 || startIdx < endIdx)) {
          final before = localPendingBuffer.substring(0, startIdx);
          if (before.isNotEmpty) {
            emissions.add(
              _ThinkingSplitEmission(text: before, isThinking: false),
            );
          }
          localIsThinking = true;
          localPendingBuffer = localPendingBuffer.substring(
            startIdx + startTag.length,
          );
          continue;
        } else if (endIdx != -1) {
          emissions.add(
            _ThinkingSplitEmission(
              text: localPendingBuffer.substring(0, endIdx),
              isThinking: true,
              endsThinking: true,
            ),
          );
          localIsThinking = false;
          localPendingBuffer = localPendingBuffer.substring(
            endIdx + endTag.length,
          );
          continue;
        }

        var potentialMatch = false;
        for (var i = startTag.length - 1; i >= 1; i--) {
          if (localPendingBuffer.endsWith(startTag.substring(0, i))) {
            final emitIdx = localPendingBuffer.length - i;
            if (emitIdx > 0) {
              emissions.add(
                _ThinkingSplitEmission(
                  text: localPendingBuffer.substring(0, emitIdx),
                  isThinking: false,
                ),
              );
              localPendingBuffer = localPendingBuffer.substring(emitIdx);
            }
            potentialMatch = true;
            break;
          }
        }
        if (!potentialMatch) {
          emissions.add(
            _ThinkingSplitEmission(text: localPendingBuffer, isThinking: false),
          );
          localPendingBuffer = '';
        }
        break;
      }

      final endIdx = localPendingBuffer.indexOf(endTag);
      if (endIdx != -1) {
        emissions.add(
          _ThinkingSplitEmission(
            text: localPendingBuffer.substring(0, endIdx),
            isThinking: true,
            endsThinking: true,
          ),
        );
        localIsThinking = false;
        localPendingBuffer = localPendingBuffer.substring(
          endIdx + endTag.length,
        );
        continue;
      }

      var potentialMatch = false;
      for (var i = endTag.length - 1; i >= 1; i--) {
        if (localPendingBuffer.endsWith(endTag.substring(0, i))) {
          final emitIdx = localPendingBuffer.length - i;
          if (emitIdx > 0) {
            emissions.add(
              _ThinkingSplitEmission(
                text: localPendingBuffer.substring(0, emitIdx),
                isThinking: true,
              ),
            );
            localPendingBuffer = localPendingBuffer.substring(emitIdx);
          }
          potentialMatch = true;
          break;
        }
      }
      if (!potentialMatch) {
        emissions.add(
          _ThinkingSplitEmission(text: localPendingBuffer, isThinking: true),
        );
        localPendingBuffer = '';
      }
      break;
    }

    return _ThinkingSplitResult(
      pendingBuffer: localPendingBuffer,
      isThinking: localIsThinking,
      emissions: emissions,
    );
  }

  static String? _computeFinalReconciliationDelta({
    required String streamedValue,
    required String finalValue,
    required String channel,
  }) {
    if (finalValue.length <= streamedValue.length) {
      return null;
    }

    if (!finalValue.startsWith(streamedValue)) {
      LlamaLogger.instance.warning(
        'Skipping final $channel delta due to prefix mismatch '
        '(streamed=${streamedValue.length}, final=${finalValue.length})',
      );
      return null;
    }

    return finalValue.substring(streamedValue.length);
  }

  static bool _isWhitespaceCodeUnit(int codeUnit) {
    return codeUnit == 0x20 || // space
        codeUnit == 0x09 || // \t
        codeUnit == 0x0A || // \n
        codeUnit == 0x0D; // \r
  }
}

/// Releases raw Hermes content that the final parse keeps.
///
/// [HermesHandler.parse] drops tool-call envelopes from content and trims it.
/// Text from a possible envelope opening on, and trailing whitespace, wait
/// for more output. After a whole opening, nothing more is released, and the
/// final parse supplies the rest of the content.
class _HermesContentGate {
  var _pending = '';
  var _scanFrom = 0;
  var _releasedAny = false;

  /// Adds [content] and returns the newly released text.
  String add(String content) {
    _pending += content;
    _scanFrom = HermesHandler.toolCallOpening(_pending, _scanFrom);
    var end = _scanFrom;
    while (end > 0 && _isTrimmed(_pending.codeUnitAt(end - 1))) {
      end--;
    }
    var start = 0;
    if (!_releasedAny) {
      while (start < end && _isTrimmed(_pending.codeUnitAt(start))) {
        start++;
      }
    }
    if (start == end) {
      return '';
    }
    final released = _pending.substring(start, end);
    _pending = _pending.substring(end);
    _scanFrom -= end;
    _releasedAny = true;
    return released;
  }

  static bool _isTrimmed(int codeUnit) =>
      String.fromCharCode(codeUnit).trim().isEmpty;
}

/// Releases raw Hermes reasoning that the final parse keeps.
///
/// [HermesHandler.parse] replaces escaped `\n` and `\r`, trims each thought,
/// and joins non-empty thoughts with a newline. Whitespace that may end a
/// thought waits for more reasoning. Trailing whitespace of a forced-open
/// thought that never ends, which the final parse keeps, arrives with the
/// final reconciliation.
class _HermesReasoningGate {
  _HermesReasoningGate({required bool forcedOpen})
    : _inForcedThought = forcedOpen;

  var _pending = '';
  var _started = false;
  var _separate = false;
  bool _inForcedThought;

  /// Adds [reasoning] of the current thought and returns the released text.
  String add(String reasoning) {
    _pending += reasoning;
    final hold = _pending.endsWith(r'\') ? 1 : 0;
    final text = _unescape(_pending.substring(0, _pending.length - hold));
    var end = text.length;
    while (end > 0 && _isTrimmed(text.codeUnitAt(end - 1))) {
      end--;
    }
    _pending = text.substring(end) + _pending.substring(_pending.length - hold);
    return _release(text.substring(0, end));
  }

  /// Ends the current thought and returns the released text.
  String end() {
    final released = _release(_unescape(_pending).trimRight());
    _pending = '';
    _separate = _separate || _started || _inForcedThought;
    _started = false;
    _inForcedThought = false;
    return released;
  }

  String _release(String text) {
    if (!_started) {
      text = text.trimLeft();
      if (text.isEmpty) {
        return '';
      }
      _started = true;
      if (_separate) {
        _separate = false;
        return '\n$text';
      }
    }
    return text;
  }

  static String _unescape(String text) =>
      text.replaceAll(r'\n', '\n').replaceAll(r'\r', '\r');

  static bool _isTrimmed(int codeUnit) =>
      String.fromCharCode(codeUnit).trim().isEmpty;
}
