import 'dart:typed_data';

import 'package:test/test.dart';

import 'support/reference_edit_bar.dart';

Uint8List _image({
  required int top,
  required int rows,
  required int left,
  required int columns,
  int bar = 40,
}) {
  const size = referenceEditSize;
  final pixels = Uint8List(size * size * 3)..fillRange(0, size * size * 3, 224);
  for (var y = top; y < top + rows; y++) {
    for (var x = left; x < left + columns; x++) {
      pixels.fillRange((y * size + x) * 3, (y * size + x) * 3 + 3, bar);
    }
  }
  return pixels;
}

void main() {
  test('the fixture bar and the bar Kontext redrew pass the shape gate', () {
    for (final (top, rows, left, columns) in [
      (432, 32, 64, 384),
      (412, 33, 62, 388),
    ]) {
      final bar = findDarkBar(
        _image(top: top, rows: rows, left: left, columns: columns),
      );

      expect((bar.height, bar.width), (rows, columns));
      expect(hasFixtureBarShape(bar), isTrue);
    }
  });

  test('a bar a third as tall, a short stub and a full-width band fail the '
      'shape gate', () {
    for (final (name, rows, left, columns) in [
      ('a third as tall', 12, 64, 384),
      ('a short stub', 32, 200, 120),
      ('full width', 32, 0, 512),
    ]) {
      final bar = findDarkBar(
        _image(top: 432, rows: rows, left: left, columns: columns),
      );

      expect(hasFixtureBarShape(bar), isFalse, reason: name);
    }
  });

  test(
    'a bar a third as tall passes the darkness gate the shape gate adds to',
    () {
      final bar = findDarkBar(
        _image(top: 432, rows: 12, left: 64, columns: 384),
      );

      expect(bar.mean, lessThan(90));
      expect(bar.top, closeTo(432, 48));
    },
  );

  test('a bar twice as tall fails the shape gate', () {
    expect(
      hasFixtureBarShape(
        findDarkBar(_image(top: 420, rows: 64, left: 64, columns: 384)),
      ),
      isFalse,
    );
  });
}
