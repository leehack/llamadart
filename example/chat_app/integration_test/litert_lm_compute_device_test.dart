@Tags(['local-only'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/backends/litert_lm/litert_lm_runtime.dart';
import 'package:llamadart/src/backends/litert_lm/litert_lm_service.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Android forwards the NPU backend name to LiteRT-LM', (_) async {
    expect(Platform.isAndroid, isTrue, reason: 'Run this test on Android.');
    final directory = await Directory.systemTemp.createTemp();
    addTearDown(() => directory.delete(recursive: true));
    final model = await File(
      '${directory.path}/model.litertlm',
    ).writeAsString('fake model');
    final client = _RecordingRuntimeClient();
    final service = LiteRtLmService(
      clientFactory: () => client,
      useTempCacheDir: false,
      readBundleCapabilities: (_) => null,
    );
    addTearDown(service.dispose);

    const params = ModelParams(device: ComputeDevice.npu);
    final handle = await service.loadModel(model.path, params);
    service.createContext(handle, params);
    await service.tokenize(handle, 'probe', true);

    expect(client.backends, ['npu']);
  });
}

class _RecordingRuntimeClient extends LiteRtLmRuntimeClient {
  final backends = <String>[];

  @override
  Future<void> initialize({
    required String modelPath,
    String backend = 'gpu',
    String? visionBackend,
    String? audioBackend,
    int maxTokens = 4096,
    int outputTokens = 256,
    int? prefillTokens,
    int? maxNumImages,
    String? cacheDir,
    bool speculativeDecoding = true,
    int minLogLevel = 3,
    LiteRtLmActivationDataType? activationDataType,
    int? prefillChunkSize,
    bool? parallelFileSectionLoading,
    String? dispatchLibDir,
    int? numberOfThreads,
  }) async {
    backends.add(backend);
  }

  @override
  List<int> tokenize(String text, {bool addSpecial = true}) => const [7];
}
