import 'package:test/test.dart';

import 'package:llamadart/src/core/exceptions.dart';
import 'package:llamadart/src/core/image/image_generation_request.dart';

void main() {
  test('defaults to one 512x512 image with the model defaults', () {
    const request = ImageGenerationRequest(prompt: 'a fox');

    expect(request.width, 512);
    expect(request.height, 512);
    expect(request.count, 1);
    expect(request.negativePrompt, '');
    expect(request.steps, isNull);
    expect(request.guidanceScale, isNull);
    expect(request.seed, isNull);
    expect(request.sampler, isNull);
    expect(request.scheduler, isNull);
    expect(request.flowShift, isNull);
    validateImageGenerationRequest(request);
  });

  test('accepts the bounds', () {
    for (final request in const [
      ImageGenerationRequest(
        prompt: 'a',
        width: 64,
        height: 2048,
        steps: 1,
        guidanceScale: 0,
        seed: 0,
        count: 1,
        flowShift: 0.01,
      ),
      ImageGenerationRequest(
        prompt: 'a',
        width: 2048,
        height: 64,
        steps: 150,
        guidanceScale: 30,
        seed: 0x7FFFFFFF,
        count: 16,
        flowShift: 100,
      ),
    ]) {
      validateImageGenerationRequest(request);
    }
  });

  test('names the first invalid field', () {
    for (final (request, field, value) in const [
      (ImageGenerationRequest(prompt: ''), 'prompt', null),
      (ImageGenerationRequest(prompt: 'a', width: 524), 'width', 524),
      (ImageGenerationRequest(prompt: 'a', width: 56), 'width', 56),
      (ImageGenerationRequest(prompt: 'a', height: 2056), 'height', 2056),
      (ImageGenerationRequest(prompt: 'a', steps: 0), 'steps', 0),
      (ImageGenerationRequest(prompt: 'a', steps: 151), 'steps', 151),
      (
        ImageGenerationRequest(prompt: 'a', guidanceScale: 30.5),
        'guidanceScale',
        30.5,
      ),
      (
        ImageGenerationRequest(prompt: 'a', guidanceScale: double.infinity),
        'guidanceScale',
        double.infinity,
      ),
      (ImageGenerationRequest(prompt: 'a', seed: -1), 'seed', -1),
      (ImageGenerationRequest(prompt: 'a', count: 17), 'count', 17),
      (ImageGenerationRequest(prompt: 'a', flowShift: 0), 'flowShift', 0.0),
      (
        ImageGenerationRequest(prompt: 'a', flowShift: 100.5),
        'flowShift',
        100.5,
      ),
      (
        ImageGenerationRequest(prompt: 'a', flowShift: double.nan),
        'flowShift',
        isNaN,
      ),
    ]) {
      expect(
        () => validateImageGenerationRequest(request),
        throwsA(
          isA<LlamaImageGenerationException>()
              .having((error) => error.message, 'message', contains(field))
              .having((error) => error.details, 'details', value),
        ),
        reason: field,
      );
    }
  });
}
