import 'dart:async';

import 'package:llamadart/llamadart.dart';

import '../models/chat_settings.dart';

class GenerationStreamUpdate {
  final String cleanText;
  final String fullThinking;
  final bool shouldNotify;
  final int generatedTokenDelta;

  const GenerationStreamUpdate({
    required this.cleanText,
    required this.fullThinking,
    required this.shouldNotify,
    this.generatedTokenDelta = 0,
  });
}

class GenerationStreamResult {
  final String fullResponse;
  final String fullThinking;
  final int generatedTokens;
  final int? firstTokenLatencyMs;
  final int elapsedMs;
  final int decodeElapsedMs;

  const GenerationStreamResult({
    required this.fullResponse,
    required this.fullThinking,
    required this.generatedTokens,
    required this.firstTokenLatencyMs,
    required this.elapsedMs,
    required this.decodeElapsedMs,
  });
}

class ChatGenerationService {
  const ChatGenerationService();

  static const int _streamTickIntervalMs = 8;
  static const int _streamRevealDelayMinMs = 8;
  static const int _streamRevealDelayMaxMs = 24;
  static const int _streamFlushBudgetMs = 220;
  static const int _tokenDeltaFlushBatchSize = 8;

  GenerationParams buildParams(ChatSettings settings) {
    // The LiteRT-LM backend only supports a subset of generation options
    // (maxTokens, temp, topK, topP, seed, stopSequences) and throws an
    // UnsupportedError for llama.cpp-specific fields like minP/penalty when
    // they differ from their defaults. For .litertlm models, leave those
    // fields at their defaults so generation does not fail.
    const defaults = GenerationParams();
    final isLiteRtLm = _isLiteRtLmModel(settings.modelPath);
    return GenerationParams(
      maxTokens: settings.maxTokens,
      temp: settings.temperature,
      topK: settings.topK,
      topP: settings.topP,
      minP: isLiteRtLm ? defaults.minP : settings.minP,
      penalty: isLiteRtLm ? defaults.penalty : settings.penalty,
      stopSequences: const <String>[],
    );
  }

  bool _isLiteRtLmModel(String? modelPath) {
    final normalized = (modelPath ?? '')
        .split('?')
        .first
        .split('#')
        .first
        .toLowerCase();
    return normalized.endsWith('.litertlm');
  }

  List<LlamaContentPart> buildChatParts({
    required String text,
    List<LlamaContentPart>? stagedParts,
  }) {
    return <LlamaContentPart>[
      ...?stagedParts,
      if (text.isNotEmpty) LlamaTextContent(text),
    ];
  }

  Future<GenerationStreamResult> consumeStream({
    required Stream<LlamaCompletionChunk> stream,
    required bool thinkingEnabled,
    required int uiNotifyIntervalMs,
    required String Function(String) cleanResponse,
    required bool Function() shouldContinue,
    required void Function(GenerationStreamUpdate update) onUpdate,
    Duration? stallTimeout,
  }) async {
    final stopwatch = Stopwatch()..start();

    var fullResponse = '';
    var fullThinking = '';
    var visibleCleanText = '';
    var cleanTarget = '';
    var generatedTokens = 0;
    var sawFirstToken = false;
    int? firstTokenLatencyMs;

    final effectiveNotifyIntervalMs = uiNotifyIntervalMs <= 0
        ? 0
        : uiNotifyIntervalMs;
    var lastUpdateAt = DateTime.fromMillisecondsSinceEpoch(0);
    var lastNotifiedCleanText = '';
    var lastNotifiedThinking = '';
    var streamCompleted = false;
    var streamCancelled = false;
    var pendingTokenDelta = 0;
    var streamElapsedMs = 0;
    var revealDelayMs = _streamRevealDelayMaxMs;
    var lastRevealAt = DateTime.fromMillisecondsSinceEpoch(0);
    var punctuationPauseMs = 0;

    void emitUpdate({bool forceNotify = false, bool flushTokenDelta = false}) {
      final now = DateTime.now();
      final hasVisibleDelta =
          visibleCleanText != lastNotifiedCleanText ||
          fullThinking != lastNotifiedThinking;

      final shouldNotify =
          forceNotify ||
          (hasVisibleDelta &&
              (effectiveNotifyIntervalMs == 0 ||
                  now.difference(lastUpdateAt).inMilliseconds >=
                      effectiveNotifyIntervalMs));

      final shouldFlushTokenDelta =
          pendingTokenDelta > 0 &&
          (forceNotify ||
              flushTokenDelta ||
              shouldNotify ||
              pendingTokenDelta >= _tokenDeltaFlushBatchSize);

      if (!shouldNotify && !shouldFlushTokenDelta) {
        return;
      }

      if (shouldNotify) {
        lastUpdateAt = now;
        lastNotifiedCleanText = visibleCleanText;
        lastNotifiedThinking = fullThinking;
      }

      final generatedTokenDelta = shouldFlushTokenDelta ? pendingTokenDelta : 0;
      if (shouldFlushTokenDelta) {
        pendingTokenDelta = 0;
      }

      onUpdate(
        GenerationStreamUpdate(
          cleanText: visibleCleanText,
          fullThinking: fullThinking,
          shouldNotify: shouldNotify,
          generatedTokenDelta: generatedTokenDelta,
        ),
      );
    }

    void advanceVisibleTextAndEmit() {
      if (!shouldContinue()) {
        streamCancelled = true;
        return;
      }

      final previousVisibleText = visibleCleanText;
      final nextVisible = _advanceVisibleText(
        currentText: previousVisibleText,
        targetText: cleanTarget,
      );
      if (nextVisible == previousVisibleText) {
        return;
      }

      visibleCleanText = nextVisible;
      punctuationPauseMs = _punctuationPauseMsForTail(
        visibleText: visibleCleanText,
        targetText: cleanTarget,
      );
      emitUpdate();
    }

    final revealTicker =
        Stream<void>.periodic(
          const Duration(milliseconds: _streamTickIntervalMs),
          (_) {},
        ).listen((_) {
          if (streamCompleted || streamCancelled) {
            return;
          }

          final backlog = cleanTarget.length - visibleCleanText.length;
          if (backlog <= 0) {
            return;
          }

          revealDelayMs = _smoothRevealDelayMs(
            currentMs: revealDelayMs,
            targetMs: _targetRevealDelayMsForBacklog(backlog),
          );

          final now = DateTime.now();
          final elapsedSinceLastReveal = now
              .difference(lastRevealAt)
              .inMilliseconds;
          final effectiveRevealDelay = revealDelayMs + punctuationPauseMs;
          if (elapsedSinceLastReveal < effectiveRevealDelay) {
            return;
          }

          lastRevealAt = now;
          advanceVisibleTextAndEmit();
        });

    try {
      final effectiveStream = stallTimeout == null
          ? stream
          : stream.timeout(
              stallTimeout,
              onTimeout: (sink) {
                sink.addError(
                  TimeoutException(
                    'Generation stalled waiting for output.',
                    stallTimeout,
                  ),
                );
              },
            );

      await for (final chunk in effectiveStream) {
        if (!shouldContinue()) {
          streamCancelled = true;
          break;
        }

        final delta = chunk.choices.first.delta;
        final content = delta.content ?? '';
        final thinking = thinkingEnabled ? (delta.thinking ?? '') : '';

        if (!sawFirstToken &&
            (content.isNotEmpty ||
                thinking.isNotEmpty ||
                (delta.toolCalls?.isNotEmpty ?? false))) {
          firstTokenLatencyMs = stopwatch.elapsedMilliseconds;
          sawFirstToken = true;
        }

        fullResponse += content;
        fullThinking += thinking
            .replaceAll(r'\n', '\n')
            .replaceAll(r'\r', '\r');
        generatedTokens++;
        pendingTokenDelta += 1;

        cleanTarget = cleanResponse(fullResponse);
        if (visibleCleanText.isEmpty && cleanTarget.isNotEmpty) {
          visibleCleanText = _advanceVisibleText(
            currentText: visibleCleanText,
            targetText: cleanTarget,
          );
          punctuationPauseMs = _punctuationPauseMsForTail(
            visibleText: visibleCleanText,
            targetText: cleanTarget,
          );
          lastRevealAt = DateTime.now();
        }

        emitUpdate();
      }

      streamCompleted = true;
      streamElapsedMs = stopwatch.elapsedMilliseconds;

      if (!streamCancelled && visibleCleanText != cleanTarget) {
        final flushDeadline = DateTime.now().add(
          const Duration(milliseconds: _streamFlushBudgetMs),
        );
        while (visibleCleanText != cleanTarget &&
            DateTime.now().isBefore(flushDeadline)) {
          advanceVisibleTextAndEmit();
          if (visibleCleanText == cleanTarget) {
            break;
          }
          await Future<void>.delayed(
            const Duration(milliseconds: _streamTickIntervalMs),
          );
        }
      }

      if (!streamCancelled) {
        if (visibleCleanText != cleanTarget) {
          visibleCleanText = cleanTarget;
          emitUpdate(forceNotify: true, flushTokenDelta: true);
        } else if (visibleCleanText != lastNotifiedCleanText ||
            fullThinking != lastNotifiedThinking) {
          emitUpdate(forceNotify: true, flushTokenDelta: true);
        } else if (pendingTokenDelta > 0) {
          emitUpdate(flushTokenDelta: true);
        }
      }
    } finally {
      await revealTicker.cancel();
    }

    stopwatch.stop();
    if (streamElapsedMs <= 0) {
      streamElapsedMs = stopwatch.elapsedMilliseconds;
    }
    final safeFirstTokenLatencyMs = firstTokenLatencyMs ?? 0;
    final decodeElapsedMs = streamElapsedMs > safeFirstTokenLatencyMs
        ? streamElapsedMs - safeFirstTokenLatencyMs
        : 0;

    return GenerationStreamResult(
      fullResponse: fullResponse,
      fullThinking: fullThinking,
      generatedTokens: generatedTokens,
      firstTokenLatencyMs: firstTokenLatencyMs,
      elapsedMs: streamElapsedMs,
      decodeElapsedMs: decodeElapsedMs,
    );
  }

  String _advanceVisibleText({
    required String currentText,
    required String targetText,
  }) {
    if (currentText == targetText) {
      return targetText;
    }

    final canPrefixAdvance =
        targetText.length > currentText.length &&
        targetText.startsWith(currentText);
    if (!canPrefixAdvance) {
      return targetText;
    }

    var nextLength = currentText.length + 1;
    if (nextLength >= targetText.length) {
      return targetText;
    }

    nextLength = _alignToUtf16Boundary(targetText, nextLength);
    if (nextLength >= targetText.length) {
      return targetText;
    }

    return targetText.substring(0, nextLength);
  }

  int _alignToUtf16Boundary(String text, int end) {
    if (end <= 0 || end >= text.length) {
      return end;
    }

    final previousCodeUnit = text.codeUnitAt(end - 1);
    final nextCodeUnit = text.codeUnitAt(end);
    if (_isLeadingSurrogate(previousCodeUnit) &&
        _isTrailingSurrogate(nextCodeUnit)) {
      return end + 1;
    }

    return end;
  }

  bool _isLeadingSurrogate(int codeUnit) {
    return codeUnit >= 0xD800 && codeUnit <= 0xDBFF;
  }

  bool _isTrailingSurrogate(int codeUnit) {
    return codeUnit >= 0xDC00 && codeUnit <= 0xDFFF;
  }

  int _targetRevealDelayMsForBacklog(int backlog) {
    if (backlog >= 320) {
      return _streamRevealDelayMinMs;
    }
    if (backlog >= 200) {
      return 10;
    }
    if (backlog >= 120) {
      return 12;
    }
    if (backlog >= 64) {
      return 14;
    }
    if (backlog >= 28) {
      return 16;
    }
    if (backlog >= 12) {
      return 20;
    }
    return _streamRevealDelayMaxMs;
  }

  int _smoothRevealDelayMs({required int currentMs, required int targetMs}) {
    if (currentMs == targetMs) {
      return currentMs;
    }

    if (currentMs < targetMs) {
      return (currentMs + 2).clamp(_streamRevealDelayMinMs, targetMs);
    }

    return (currentMs - 2).clamp(targetMs, _streamRevealDelayMaxMs);
  }

  int _punctuationPauseMsForTail({
    required String visibleText,
    required String targetText,
  }) {
    if (visibleText.isEmpty || visibleText.length >= targetText.length) {
      return 0;
    }

    final lastCodeUnit = visibleText.codeUnitAt(visibleText.length - 1);
    if (lastCodeUnit == 10 || lastCodeUnit == 13) {
      return 20;
    }

    if (lastCodeUnit == 46 || lastCodeUnit == 33 || lastCodeUnit == 63) {
      return 18;
    }

    if (lastCodeUnit == 44 || lastCodeUnit == 59 || lastCodeUnit == 58) {
      return 10;
    }

    return 0;
  }
}
