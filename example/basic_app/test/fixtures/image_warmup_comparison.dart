import 'package:llamadart/llamadart.dart';

typedef ImageWarmUpMeasurements = ({
  Duration warmUp,
  Duration first,
  Duration second,
});

// Short CLIP prompts use the same padded encoder shape, while their distinct
// text prevents stable-diffusion.cpp's conditioning cache from serving only
// the second measured request. Neither prompt matches warmUp's 'warm-up'.
const imageWarmUpRequests = <ImageGenerationRequest>[
  ImageGenerationRequest(
    prompt: 'a red fox in autumn leaves',
    width: 256,
    height: 256,
    steps: 1,
    guidanceScale: 1,
    seed: 42,
  ),
  ImageGenerationRequest(
    prompt: 'a red cat in autumn leaves',
    width: 256,
    height: 256,
    steps: 1,
    guidanceScale: 1,
    seed: 42,
  ),
];

Future<ImageWarmUpMeasurements?> measureImageWarmUp({
  required String backendName,
  required Future<void> Function() warmUp,
  required Future<Duration> Function(ImageGenerationRequest request) generate,
}) async {
  final backend = backendName.toLowerCase();
  final gpu = const [
    'mtl',
    'metal',
    'vulkan',
    'cuda',
    'rocm',
    'gpuopencl',
    'opencl',
    'sycl',
  ].any(backend.startsWith);
  if (!gpu && backend != 'cpu' && backend != 'blas') {
    throw StateError('Unknown warm-up timing backend: $backendName');
  }
  final watch = Stopwatch()..start();
  await warmUp();
  watch.stop();
  // CPU warmUp validates state but performs no generation/pipeline compile.
  // The GPU first-image latency contract does not apply to that backend.
  if (!gpu) return null;
  final first = await generate(imageWarmUpRequests[0]);
  final second = await generate(imageWarmUpRequests[1]);
  return (warmUp: watch.elapsed, first: first, second: second);
}
