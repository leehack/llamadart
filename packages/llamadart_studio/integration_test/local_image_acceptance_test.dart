@Tags(<String>['local-only'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final path = Platform.environment['STUDIO_ACCEPTANCE_IMAGE_MODEL'];
  test(
    'real SDXS generates a PNG through the Studio image port',
    () async {
      final port = DirectLlamaImagePort();
      addTearDown(port.dispose);
      final runtime = await port.checkRuntime();
      expect(runtime.isSupported, isTrue, reason: runtime.unsupportedReason);
      await port.loadModel(
        assets: ResolvedModelAssets(
          descriptor: CuratedModelCatalog.byId('sdxs-512-q8_0')!,
          primarySource: ModelSource.parse(path!),
        ),
      );
      final image = await port.generateImage(
        prompt: 'A red apple on a white table.',
        width: 512,
        height: 512,
        steps: 1,
        guidanceScale: 1,
        seed: 42,
      );
      expect(image.width, 512);
      expect(image.height, 512);
      expect(image.pngBytes.take(8), <int>[137, 80, 78, 71, 13, 10, 26, 10]);
      final output = Platform.environment['STUDIO_ACCEPTANCE_IMAGE_OUTPUT'];
      if (output != null) await File(output).writeAsBytes(image.pngBytes);
      // Structured local acceptance receipt for the operator.
      // ignore: avoid_print
      print(
        'REAL_STUDIO_IMAGE width=${image.width} height=${image.height} '
        'elapsedMs=${image.elapsedMs} bytes=${image.pngBytes.length}',
      );
    },
    skip: path == null,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
