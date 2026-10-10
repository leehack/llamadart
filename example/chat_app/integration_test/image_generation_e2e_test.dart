@Tags(['local-only', 'e2e'])
@Timeout(Duration(minutes: 40))
/// Local-only device check of the image screen with the real
/// stable_diffusion runtime: checks that the runtime probe leaves the UI
/// isolate responsive, downloads SDXS-512 (683 MB) through the screen when it
/// is not installed, generates a seeded 512x512 image, and writes the PNG and
/// a capture of the screen plus a verified receipt. Android uses app external
/// files so device runners can pull the evidence; other platforms use cache.
///
/// ```bash
/// cd example/chat_app
/// flutter test --run-skipped -t local-only \
///   integration_test/image_generation_e2e_test.dart -d <device>
/// ```
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:llamadart/src/hook/native_release_pins.dart';

import 'package:llamadart_chat_example/models/image_model_profile.dart';
import 'package:llamadart_chat_example/providers/image_generation_provider.dart';
import 'package:llamadart_chat_example/screens/image_generation_screen.dart';

import 'support/image_evidence.dart';

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
    var longestGap = Duration.zero;
    final sinceTick = Stopwatch()..start();
    void tick() {
      if (sinceTick.elapsed > longestGap) {
        longestGap = sinceTick.elapsed;
      }
      sinceTick.reset();
    }

    final ticker = Timer.periodic(
      const Duration(milliseconds: 10),
      (_) => tick(),
    );
    addTearDown(ticker.cancel);
    final checking = Stopwatch()..start();
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
    tick();
    checking.stop();
    ticker.cancel();
    expect(provider.isSupported, isTrue, reason: provider.unsupportedReason);
    debugPrint(
      'E2E image runtime backend: ${provider.runtimeBackend}; check '
      '${checking.elapsedMilliseconds} ms, longest UI isolate gap '
      '${longestGap.inMilliseconds} ms',
    );
    // The first runtime probe can take about 16 s with an empty Metal shader
    // cache (MTL_SHADER_CACHE_SIZE=0 on macOS); it must not stall the UI.
    expect(longestGap, lessThan(const Duration(seconds: 2)));

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

    // enterText is dropped in profile and release integration tests
    // (physical iOS XCTest runs Release): the binding registers no test text
    // input, and Flutter's TextInput accepts its client id only inside a
    // debug assert.
    tester
            .widget<TextField>(
              find.byKey(const ValueKey<String>('image_seed_field')),
            )
            .controller!
            .text =
        '42';
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    final generateButton = find.byKey(
      const ValueKey<String>('generate_image_button'),
    );
    await tester.ensureVisible(generateButton);
    await tester.tap(generateButton);
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
    final base = Platform.isAndroid
        ? await getExternalStorageDirectory()
        : await getTemporaryDirectory();
    if (base == null) throw StateError('No pullable image evidence directory');
    final directory = Directory(
      p.join(
        base.path,
        imageEvidenceDirectoryName,
        'run-${DateTime.now().toUtc().microsecondsSinceEpoch}',
      ),
    );
    final modelUri = Uri.parse(profile.modelSource.url);
    final revisionIndex = modelUri.pathSegments.indexOf('resolve') + 1;
    final manifest = await writeImageEvidence(
      directory: directory,
      generatedPng: output.png,
      screenPng: capture!,
      metadata: {
        'source_commit': const String.fromEnvironment(
          'VALIDATION_COMMIT',
          defaultValue: 'unknown',
        ),
        'source_dirty': const bool.fromEnvironment(
          'VALIDATION_SOURCE_DIRTY',
          defaultValue: true,
        ),
        'backend': provider.runtimeBackend,
        'runtime_tag': stableDiffusionReleaseTag,
        'model_lock': {
          'id': profile.id,
          'filename': profile.modelSource.filename,
          'sha256': profile.modelSource.sha256,
          'bytes': profile.modelSource.sizeBytes,
          'revision': modelUri.pathSegments[revisionIndex],
        },
        'seed': output.seed,
        'width': output.width,
        'height': output.height,
        'steps': profile.steps,
        'guidance_scale': profile.guidanceScale,
        'runtime_probe_ms': checking.elapsedMilliseconds,
        'longest_ui_gap_ms': longestGap.inMilliseconds,
      },
    );
    expect(manifest['artifacts'], hasLength(2));
    debugPrint(
      'E2E image written: ${p.join(directory.path, 'image_generation_e2e.png')}',
    );
    debugPrint(
      'E2E screen capture written: ${p.join(directory.path, 'image_generation_screen.png')}',
    );
    debugPrint('E2E image evidence written and verified: ${directory.path}');
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
