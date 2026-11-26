import 'dart:ffi';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../../core/engine/token_logprobs.dart';
import '../../core/exceptions.dart';
import '../../core/models/inference/next_token_scores.dart';
import 'bindings.dart';
import 'exit_teardown_api.dart';

/// Ids of the [k] largest [logits], largest first; ties keep the lower id.
List<int> topLogitTokens(Float32List logits, int k) {
  if (k == 0) return const [];
  final heap = <int>[];
  bool before(int a, int b) =>
      logits[a] < logits[b] || (logits[a] == logits[b] && a > b);
  void siftDown(int i) {
    while (true) {
      final left = 2 * i + 1, right = left + 1;
      var smallest = i;
      if (left < heap.length && before(heap[left], heap[smallest])) {
        smallest = left;
      }
      if (right < heap.length && before(heap[right], heap[smallest])) {
        smallest = right;
      }
      if (smallest == i) return;
      final t = heap[i];
      heap[i] = heap[smallest];
      heap[smallest] = t;
      i = smallest;
    }
  }

  for (var token = 0; token < logits.length; token++) {
    if (heap.length < k) {
      heap.add(token);
      var i = heap.length - 1;
      while (i > 0) {
        final parent = (i - 1) ~/ 2;
        if (!before(heap[i], heap[parent])) break;
        final t = heap[i];
        heap[i] = heap[parent];
        heap[parent] = t;
        i = parent;
      }
    } else if (before(heap[0], token)) {
      heap[0] = token;
      siftDown(0);
    }
  }
  return heap..sort((a, b) => before(a, b) ? 1 : (before(b, a) ? -1 : 0));
}

/// `log(sum(exp(logits)))`, the normalizer of a softmax over [logits].
double logSumExp(Float32List logits) {
  var maxLogit = double.negativeInfinity;
  for (var i = 0; i < logits.length; i++) {
    if (logits[i] > maxLogit) maxLogit = logits[i];
  }
  var sum = 0.0;
  for (var i = 0; i < logits.length; i++) {
    sum += math.exp(logits[i] - maxLogit);
  }
  return maxLogit + math.log(sum);
}

/// Reads the raw-logit log-probabilities of a native generation.
///
/// Call [read] right after the sampler chooses a token and before the next
/// decode replaces the logits.
final class TokenLogprobRecorder {
  /// Creates a recorder that reports the [topK] most probable alternatives.
  TokenLogprobRecorder({
    required LlamaCppObjectCalls calls,
    required Pointer<llama_vocab> vocab,
    required int vocabSize,
    required int topK,
  }) : _calls = calls,
       _vocab = vocab,
       _vocabSize = vocabSize,
       _topK = math.min(topK, vocabSize);

  static const int _initialPieceCapacity = 256;

  final LlamaCppObjectCalls _calls;
  final Pointer<llama_vocab> _vocab;
  final int _vocabSize;
  final int _topK;
  final Pointer<Uint8> _pieces = malloc<Uint8>(_initialPieceCapacity);

  /// The queue that holds entries until their bytes are visible.
  final TokenLogprobQueue queue = TokenLogprobQueue();

  /// Reads the logits of the last decoded position of [context].
  ///
  /// [sampledBytes] are the bytes the sampled [token] added to the stream.
  /// The read follows the guarded sample and `tokenToPiece` calls and only
  /// copies values out of the context's output buffer, which the 250 ms exit
  /// teardown settle window after those calls covers.
  LlamaGeneratedTokenLogprobs read(
    Pointer<llama_context> context,
    int token,
    List<int> sampledBytes,
  ) {
    final logitsPtr = llama_get_logits_ith(context, -1);
    if (logitsPtr == nullptr) {
      throw LlamaInferenceException(
        'llama.cpp returned no logits for the sampled position.',
      );
    }
    final logits = logitsPtr.asTypedList(_vocabSize);
    final logSum = logSumExp(logits);
    return LlamaGeneratedTokenLogprobs(
      sampled: LlamaTokenLogprob(
        token: token,
        bytes: sampledBytes,
        logprob: logits[token] - logSum,
      ),
      top: [
        for (final id in topLogitTokens(logits, _topK))
          LlamaTokenLogprob(
            token: id,
            bytes: _pieceBytes(id),
            logprob: logits[id] - logSum,
          ),
      ],
    );
  }

  List<int> _pieceBytes(int token) {
    var count = _calls.tokenToPiece(
      _vocab,
      token,
      _pieces.cast(),
      _initialPieceCapacity,
      0,
      true,
    );
    if (count >= 0) return List<int>.of(_pieces.asTypedList(count));
    final larger = malloc<Uint8>(-count);
    try {
      count = _calls.tokenToPiece(
        _vocab,
        token,
        larger.cast(),
        -count,
        0,
        true,
      );
      return count > 0 ? List<int>.of(larger.asTypedList(count)) : const [];
    } finally {
      malloc.free(larger);
    }
  }

  /// Frees the piece buffer.
  void dispose() => malloc.free(_pieces);
}
