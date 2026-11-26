import 'dart:collection';

import '../../backends/backend.dart';
import '../models/inference/next_token_scores.dart';

/// Holds the log-probabilities of generated tokens until the stream shows
/// their text.
///
/// A stop sequence withholds the bytes of a token until it is clear that
/// they are not part of the marker, and drops them when they are. An entry
/// is released with the bytes that make its first byte visible, so tokens
/// removed entirely by a stop sequence are never reported.
final class TokenLogprobQueue {
  final ListQueue<(LlamaGeneratedTokenLogprobs, int)> _pending = ListQueue();
  var _added = 0;
  var _visible = 0;

  /// Queues the entry of the next sampled token.
  void add(LlamaGeneratedTokenLogprobs entry) {
    _pending.add((entry, _added));
    _added += entry.sampled.bytes.length;
  }

  /// Records that [visibleBytes] more bytes reached the stream and returns
  /// the entries whose first byte is among the bytes released so far.
  List<LlamaGeneratedTokenLogprobs> release(int visibleBytes) {
    _visible += visibleBytes;
    final released = <LlamaGeneratedTokenLogprobs>[];
    while (_pending.isNotEmpty) {
      final (entry, start) = _pending.first;
      final empty = entry.sampled.bytes.isEmpty;
      if (start >= _visible && !(empty && start == _visible)) break;
      released.add(entry);
      _pending.removeFirst();
    }
    return released;
  }
}

/// Releases the token log-probabilities of one generation as the bytes of
/// its stream arrive.
///
/// A backend can report an entry before the stream event that carries its
/// bytes, and an event can reach the engine long after the backend queued it,
/// so entries are placed by byte offset, not by arrival time.
final class TokenLogprobCollector {
  /// Creates a collector that keeps every released entry in [released] when
  /// [retain] is true, and otherwise hands them out once through [drain].
  TokenLogprobCollector({this.retain = false});

  /// Whether [released] keeps entries after [drain].
  final bool retain;

  final TokenLogprobQueue _queue = TokenLogprobQueue();
  final List<LlamaGeneratedTokenLogprobs> _released = [];
  BackendTokenLogprobsReporting? _reporter;
  Stream<List<int>>? _generation;

  /// The entries released so far, in order. It grows as bytes arrive.
  List<LlamaGeneratedTokenLogprobs> get released =>
      UnmodifiableListView(_released);

  /// Reads the entries of [generation] from [reporter] from now on.
  void bind(
    BackendTokenLogprobsReporting reporter,
    Stream<List<int>> generation,
  ) {
    _reporter = reporter;
    _generation = generation;
  }

  /// Notes that [bytes] reached the stream and releases the entries they
  /// show. Returns [bytes] unchanged.
  List<int> onBytes(List<int> bytes) {
    _take();
    _released.addAll(_queue.release(bytes.length));
    return bytes;
  }

  /// Releases every entry the backend reported, once the stream has ended.
  void finish() {
    _take();
    _released.addAll(_queue.release(0));
  }

  /// The entries released since the previous call.
  ///
  /// Keeps them in [released] when [retain] is true.
  List<LlamaGeneratedTokenLogprobs> drain() {
    final entries = List<LlamaGeneratedTokenLogprobs>.of(_released);
    if (!retain) _released.clear();
    return entries;
  }

  void _take() {
    final reporter = _reporter;
    final generation = _generation;
    if (reporter == null || generation == null) return;
    for (final entry in reporter.takeTokenLogprobs(generation)) {
      _queue.add(entry);
    }
  }
}
