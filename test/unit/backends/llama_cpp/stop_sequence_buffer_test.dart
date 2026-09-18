import 'dart:convert';

import 'package:llamadart/src/backends/llama_cpp/stop_sequence_buffer.dart';
import 'package:test/test.dart';

void main() {
  List<int> collect(List<List<int>> pieces, List<String> stops) {
    final buffer = StopSequenceBuffer(stops);
    return [
      for (final piece in pieces) ...buffer.add(piece),
      ...buffer.finish(),
    ];
  }

  test('withholds only a possible marker prefix and releases mismatches', () {
    final buffer = StopSequenceBuffer(['cedar17']);
    expect(buffer.add(utf8.encode('alpha ce')), utf8.encode('alpha '));
    expect(buffer.add(utf8.encode('d')), isEmpty);
    expect(buffer.add(utf8.encode('X')), utf8.encode('cedX'));
    expect(buffer.finish(), isEmpty);
    expect(buffer.isStopped, isFalse);
  });

  test(
    'suppresses complete marker and token tail and ignores later pieces',
    () {
      final buffer = StopSequenceBuffer(['cedar17']);
      expect(
        buffer.add(utf8.encode('alpha cedar17 omega')),
        utf8.encode('alpha '),
      );
      expect(buffer.isStopped, isTrue);
      expect(buffer.add(utf8.encode('extra')), isEmpty);
      expect(buffer.finish(), isEmpty);
    },
  );

  test('long irrelevant stops do not delay ordinary streaming', () {
    final buffer = StopSequenceBuffer(['x' * 10000, 'cedar17']);
    for (var i = 0; i < 100; i++) {
      expect(buffer.add(utf8.encode('hello ')), utf8.encode('hello '));
    }
    expect(buffer.finish(), isEmpty);
  });

  test('releases incomplete marker once at normal completion', () {
    final buffer = StopSequenceBuffer(['cedar17']);
    expect(buffer.add(utf8.encode('cedar1')), isEmpty);
    expect(buffer.finish(), utf8.encode('cedar1'));
    expect(buffer.finish(), isEmpty);
    expect(buffer.isStopped, isFalse);
  });

  test('empty and duplicate stops do not terminate generation', () {
    final bytes = utf8.encode('alpha 🦊 café');
    expect(collect([bytes], ['', '']), bytes);
    expect(collect([bytes], ['', 'absent', 'absent']), bytes);
  });

  test('earliest complete overlapping marker wins in either list order', () {
    for (final stops in [
      ['ab', 'abc', 'bc'],
      ['bc', 'abc', 'ab'],
      ['abc', 'ab', 'bc'],
    ]) {
      expect(collect([utf8.encode('xabc tail')], stops), utf8.encode('x'));
    }
    expect(
      collect([utf8.encode('xaab tail')], ['aab', 'ab']),
      utf8.encode('x'),
    );
    expect(collect([utf8.encode('abc')], ['abcd', 'bc']), utf8.encode('a'));
  });

  test('preserves arbitrary non-marker bytes without lossy UTF-8 decoding', () {
    const bytes = [0xff, 0xc3, 0, 0xa9];
    expect(collect([bytes], ['🦊']), bytes);
  });

  for (final fixture in [
    (text: 'alpha cedar17 omega', stop: 'cedar17', expected: 'alpha '),
    (text: 'café 🦊終わり omega', stop: '🦊終わり', expected: 'café '),
    (text: 'aaaaab tail', stop: 'aaab', expected: 'aa'),
    (text: 'no marker ced', stop: 'cedar17', expected: 'no marker ced'),
    (text: 'prefix ${'x' * 130} tail', stop: 'x' * 130, expected: 'prefix '),
  ]) {
    test('all two-way byte splits: ${fixture.stop}', () {
      final bytes = utf8.encode(fixture.text);
      for (var split = 0; split <= bytes.length; split++) {
        expect(
          collect(
            [bytes.sublist(0, split), bytes.sublist(split)],
            [fixture.stop],
          ),
          utf8.encode(fixture.expected),
          reason: 'split=$split',
        );
      }
      expect(
        collect(
          [
            for (final byte in bytes) [byte],
          ],
          [fixture.stop],
        ),
        utf8.encode(fixture.expected),
      );
    });
  }
}
