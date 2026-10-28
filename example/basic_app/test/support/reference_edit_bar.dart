import 'dart:typed_data';

const referenceEditSize = 512;

const _firstColumn = 96;
const _endColumn = 416;
const _coreRows = 16;
const _darkBelow = 132;

/// The fixture's bar is 32 rows by 384 columns; Kontext redraws it a few
/// rows taller and shifted (33 rows by 388 columns in the qualified run).
const _heightRange = (min: 24, max: 40);
const _widthRange = (min: 320, max: 448);

typedef DarkBar = ({int top, double mean, int height, int width});

/// The darkest [_coreRows]-row band over the bar's columns in the lower part
/// of the 512x512 RGB [pixels], grown over the adjacent dark rows, with the
/// longest dark run across its middle row.
DarkBar findDarkBar(Uint8List pixels) {
  final rowMeans = <double>[
    for (var y = 0; y < referenceEditSize; y++) _rowMean(pixels, y),
  ];
  const lowest = referenceEditSize * 6 ~/ 10;
  var top = lowest;
  var bestMean = double.infinity;
  for (var y = lowest; y + _coreRows <= referenceEditSize; y++) {
    var sum = 0.0;
    for (var row = y; row < y + _coreRows; row++) {
      sum += rowMeans[row];
    }
    final mean = sum / _coreRows;
    if (mean < bestMean) {
      bestMean = mean;
      top = y;
    }
  }
  var first = top;
  var last = top + _coreRows - 1;
  while (first > 0 && rowMeans[first - 1] < _darkBelow) {
    first--;
  }
  while (last < referenceEditSize - 1 && rowMeans[last + 1] < _darkBelow) {
    last++;
  }
  return (
    top: top,
    mean: bestMean,
    height: last - first + 1,
    width: _darkRun(pixels, (first + last) ~/ 2),
  );
}

/// Whether [bar] has the fixture bar's shape, not only a dark place.
bool hasFixtureBarShape(DarkBar bar) =>
    bar.height >= _heightRange.min &&
    bar.height <= _heightRange.max &&
    bar.width >= _widthRange.min &&
    bar.width <= _widthRange.max;

double _rowMean(Uint8List pixels, int y) {
  var sum = 0;
  for (var x = _firstColumn; x < _endColumn; x++) {
    final offset = (y * referenceEditSize + x) * 3;
    sum += pixels[offset] + pixels[offset + 1] + pixels[offset + 2];
  }
  return sum / ((_endColumn - _firstColumn) * 3);
}

int _darkRun(Uint8List pixels, int y) {
  var longest = 0;
  var run = 0;
  for (var x = 0; x < referenceEditSize; x++) {
    final offset = (y * referenceEditSize + x) * 3;
    final mean = (pixels[offset] + pixels[offset + 1] + pixels[offset + 2]) / 3;
    run = mean < _darkBelow ? run + 1 : 0;
    if (run > longest) longest = run;
  }
  return longest;
}
