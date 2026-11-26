import 'package:llamadart/backend.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/core/engine/token_logprobs.dart';
import 'package:test/test.dart';

LlamaGeneratedTokenLogprobs _entry(int token, List<int> bytes) =>
    LlamaGeneratedTokenLogprobs(
      sampled: LlamaTokenLogprob(token: token, bytes: bytes, logprob: -1),
      top: const [],
    );

List<int> _tokens(Iterable<LlamaGeneratedTokenLogprobs> entries) => [
  for (final entry in entries) entry.sampled.token,
];

class _Reporter implements BackendTokenLogprobsReporting {
  final List<LlamaGeneratedTokenLogprobs> pending = [];

  @override
  List<LlamaGeneratedTokenLogprobs> takeTokenLogprobs(
    Stream<List<int>> generation,
  ) {
    final taken = List.of(pending);
    pending.clear();
    return taken;
  }
}

void main() {
  group('TokenLogprobQueue', () {
    test('releases an entry with the first byte it shows', () {
      final queue = TokenLogprobQueue()
        ..add(_entry(1, [0x61]))
        ..add(_entry(2, [0x62, 0x63]))
        ..add(_entry(3, [0x64]));

      expect(_tokens(queue.release(0)), isEmpty);
      expect(_tokens(queue.release(1)), [1]);
      expect(_tokens(queue.release(1)), [2]);
      expect(_tokens(queue.release(1)), isEmpty);
      expect(_tokens(queue.release(1)), [3]);
    });

    test('never releases tokens a stop sequence removed entirely', () {
      final queue = TokenLogprobQueue()
        ..add(_entry(1, [0x61]))
        ..add(_entry(2, [0x62]))
        ..add(_entry(3, [0x63]));

      expect(_tokens(queue.release(1)), [1]);
      expect(_tokens(queue.release(0)), isEmpty);
    });

    test('releases a token a stop sequence cuts into', () {
      final queue = TokenLogprobQueue()..add(_entry(1, [0x61, 0x62]));

      expect(_tokens(queue.release(1)), [1]);
    });

    test('releases empty tokens in order once the bytes before them show', () {
      final queue = TokenLogprobQueue()
        ..add(_entry(1, []))
        ..add(_entry(2, [0x61]))
        ..add(_entry(3, []))
        ..add(_entry(4, [0x62]));

      expect(_tokens(queue.release(0)), [1]);
      expect(_tokens(queue.release(1)), [2, 3]);
      expect(_tokens(queue.release(1)), [4]);
    });
  });

  group('TokenLogprobCollector', () {
    late _Reporter reporter;
    late TokenLogprobCollector collector;

    TokenLogprobCollector bound({bool retain = false}) =>
        TokenLogprobCollector(retain: retain)
          ..bind(reporter, const Stream<List<int>>.empty());

    setUp(() {
      reporter = _Reporter();
      collector = bound();
    });

    test('places entries by byte offset, not by when they were taken', () {
      reporter.pending
        ..add(_entry(1, [0x61]))
        ..add(_entry(2, [0x62]))
        ..add(_entry(3, [0x63]));

      collector.onBytes([0x61]);
      expect(_tokens(collector.drain()), [1]);
      collector.onBytes([0x62, 0x63]);
      expect(_tokens(collector.drain()), [2, 3]);
      expect(collector.drain(), isEmpty);
    });

    test('holds entries until their bytes arrive', () {
      reporter.pending.add(_entry(1, [0xC3]));
      collector.onBytes(const []);
      expect(collector.drain(), isEmpty);

      reporter.pending.add(_entry(2, [0xA9]));
      collector.onBytes([0xC3]);
      expect(_tokens(collector.drain()), [1]);
      collector.onBytes([0xA9]);
      expect(_tokens(collector.drain()), [2]);
    });

    test('takes entries that follow the bytes at the end of the stream', () {
      collector.onBytes([0x61]);
      reporter.pending.add(_entry(1, [0x61]));

      collector.finish();

      expect(_tokens(collector.drain()), [1]);
    });

    test('keeps released entries only when asked to retain them', () {
      reporter.pending.add(_entry(1, [0x61]));
      collector.onBytes([0x61]);
      collector.drain();
      expect(collector.released, isEmpty);

      collector = bound(retain: true);
      reporter.pending.add(_entry(2, [0x62]));
      collector.onBytes([0x62]);
      collector.drain();
      expect(_tokens(collector.released), [2]);
      expect(
        () => collector.released.add(_entry(3, [])),
        throwsUnsupportedError,
      );
    });

    test('returns the bytes it was given', () {
      final bytes = [1, 2, 3];
      expect(collector.onBytes(bytes), same(bytes));
    });

    test('an unbound collector releases nothing', () {
      final unbound = TokenLogprobCollector()
        ..onBytes([1])
        ..finish();
      expect(unbound.drain(), isEmpty);
    });
  });
}
