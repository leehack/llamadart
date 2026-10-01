import 'package:test/test.dart';

import 'package:llamadart/src/core/image/image_generation_events.dart';
import 'package:llamadart/src/core/image/image_generation_progress.dart';

String _label(ImageGenerationProgressEvent event) =>
    '${event.phase.name} ${event.step}/${event.steps} '
    '#${event.imageIndex}/${event.imageCount}';

List<String> _feed(
  ImageGenerationProgressTracker tracker,
  List<(int, int)> callbacks,
) => [
  for (final (step, total) in callbacks)
    ...tracker.onNativeProgress(step, total).map(_label),
];

void main() {
  test('starts in encodingPrompt', () {
    final tracker = ImageGenerationProgressTracker(steps: 4, imageCount: 1);

    expect(_label(tracker.start()), 'encodingPrompt 0/4 #0/1');
  });

  test('labels an eagerly loaded single image as sampling, then decoding', () {
    final tracker = ImageGenerationProgressTracker(steps: 1, imageCount: 1);

    expect(_feed(tracker, [(0, 1), (1, 1)]), [
      'sampling 0/1 #0/1',
      'sampling 1/1 #0/1',
      'decoding 0/1 #0/1',
    ]);
  });

  test('advances the image index per sampling pass', () {
    final tracker = ImageGenerationProgressTracker(steps: 2, imageCount: 2);

    expect(_feed(tracker, [(0, 2), (1, 2), (2, 2), (0, 2), (1, 2), (2, 2)]), [
      'sampling 0/2 #0/2',
      'sampling 1/2 #0/2',
      'sampling 2/2 #0/2',
      'sampling 0/2 #1/2',
      'sampling 1/2 #1/2',
      'sampling 2/2 #1/2',
      'decoding 0/2 #1/2',
    ]);
  });

  test('labels lazy tensor loads as loading and tiled decodes as decoding '
      '(first SDXS run with lazy loading)', () {
    final tracker = ImageGenerationProgressTracker(steps: 1, imageCount: 1);

    expect(
      _feed(tracker, [
        (4, 196),
        (196, 196),
        (0, 1),
        (0, 280),
        (280, 280),
        (1, 1),
        (0, 67),
        (67, 67),
      ]),
      [
        'loading 4/196 #0/1',
        'loading 196/196 #0/1',
        'sampling 0/1 #0/1',
        'loading 0/280 #0/1',
        'loading 280/280 #0/1',
        'sampling 1/1 #0/1',
        'decoding 0/1 #0/1',
        'decoding 0/67 #0/1',
        'decoding 67/67 #0/1',
      ],
    );
  });

  test('a callback after every image is sampled is decoding, even with the '
      'step total', () {
    final tracker = ImageGenerationProgressTracker(steps: 4, imageCount: 1);
    _feed(tracker, [(0, 4), (1, 4), (2, 4), (3, 4), (4, 4)]);

    expect(_feed(tracker, [(2, 4)]), ['decoding 2/4 #0/1']);
  });
}
