@Tags(['local-only', 'e2e'])
@Timeout(Duration(minutes: 40))
/// Local-only device check of the image screen with the real
/// stable_diffusion runtime: downloads SDXS-512 (683 MB) through the screen
/// when it is not installed, generates a seeded 512x512 image, and writes the
/// PNG and a capture of the screen to the app's temporary directory.
///
/// ```bash
/// cd example/chat_app
/// flutter test --run-skipped -t local-only \
///   integration_test/image_generation_e2e_test.dart -d <device>
/// ```
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:llamadart_chat_example/models/image_model_profile.dart';
import 'package:llamadart_chat_example/providers/image_generation_provider.dart';
import 'package:llamadart_chat_example/screens/image_generation_screen.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('downloads SDXS and generates a seeded image', (tester) async {
    tester.view
      ..physicalSize = const Size(800, 1400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final provider = ImageGenerationProvider();
    addTearDown(provider.dispose);
    final captureKey = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: captureKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF9CB2FF),
              brightness: Brightness.dark,
            ),
          ),
          home: ImageGenerationScreen(provider: provider),
        ),
      ),
    );
    await _pumpUntil(tester, () => provider.isInitialized);
    expect(provider.isSupported, isTrue, reason: provider.unsupportedReason);
    debugPrint('E2E image runtime backend: ${provider.runtimeBackend}');

    const profile = ImageModelProfile.sdxs;
    if (!provider.isInstalled(profile)) {
      await tester.tap(find.byKey(ValueKey<String>('install_${profile.id}')));
      await _pumpUntil(
        tester,
        () => provider.isInstalled(profile) || provider.error != null,
        timeout: const Duration(minutes: 30),
      );
      expect(provider.error, isNull);
    }
    expect(provider.selectedProfile.id, profile.id);

    await tester.enterText(
      find.byKey(const ValueKey<String>('image_seed_field')),
      '42',
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('generate_image_button')),
    );
    await _pumpUntil(
      tester,
      () => provider.output != null || provider.error != null,
      timeout: const Duration(minutes: 5),
    );
    expect(provider.error, isNull);
    final output = provider.output!;
    expect(output.seed, 42);
    expect(output.width, 512);
    expect(output.height, 512);
    expect(
      find.byKey(const ValueKey<String>('generated_image')),
      findsOneWidget,
    );
    debugPrint(
      'E2E image generated: ${provider.loadedEngineLabel}, '
      '${output.elapsed.inMilliseconds} ms',
    );

    final directory = await (await getTemporaryDirectory()).create(
      recursive: true,
    );
    final imagePath = p.join(directory.path, 'image_generation_e2e.png');
    await File(imagePath).writeAsBytes(output.png);
    await tester.pump(const Duration(seconds: 1));
    final boundary =
        captureKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final capture = await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        return bytes!.buffer.asUint8List();
      } finally {
        image.dispose();
      }
    });
    final capturePath = p.join(directory.path, 'image_generation_screen.png');
    await File(capturePath).writeAsBytes(capture!);
    debugPrint('E2E image written: $imagePath');
    debugPrint('E2E screen capture written: $capturePath');
  });
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(minutes: 1),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out after $timeout.');
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 250)),
    );
    await tester.pump();
  }
}
