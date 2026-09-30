import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';

import 'package:llamadart_chat_example/models/image_model_profile.dart';
import 'package:llamadart_chat_example/providers/image_generation_provider.dart';
import 'package:llamadart_chat_example/screens/image_generation_screen.dart';
import 'package:llamadart_chat_example/services/image_generation_service.dart';
import 'package:llamadart_chat_example/services/image_model_service.dart';

void main() {
  late FakeImageGenerationService generation;
  late FakeImageModelService models;
  late bool chatModelLoaded;
  late int chatUnloads;

  setUp(() {
    generation = FakeImageGenerationService();
    models = FakeImageModelService();
    chatModelLoaded = false;
    chatUnloads = 0;
  });

  ImageGenerationProvider createProvider() {
    final provider = ImageGenerationProvider(
      generationService: generation,
      modelService: models,
      isChatModelLoaded: () => chatModelLoaded,
      unloadChatModel: () async {
        chatUnloads += 1;
        chatModelLoaded = false;
      },
      encodePng: (image) async => image.toPng(),
    );
    addTearDown(provider.dispose);
    return provider;
  }

  Future<ImageGenerationProvider> pumpScreen(WidgetTester tester) async {
    tester.view
      ..physicalSize = const Size(900, 2400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final provider = createProvider();
    await tester.pumpWidget(
      MaterialApp(home: ImageGenerationScreen(provider: provider)),
    );
    await tester.pumpAndSettle();
    return provider;
  }

  testWidgets('shows the runtime reason instead of generation controls', (
    tester,
  ) async {
    generation.capabilities = const ImageGenerationCapabilities(
      isSupported: false,
      unsupportedReason: 'The stable_diffusion runtime is not bundled.',
    );

    await pumpScreen(tester);

    expect(
      find.byKey(const ValueKey<String>('image_generation_unsupported')),
      findsOneWidget,
    );
    expect(
      find.text('The stable_diffusion runtime is not bundled.'),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('generate_image_button')),
      findsNothing,
    );
    expect(models.resolveCalls, 0);
  });

  testWidgets('lists catalog sizes, the SD-Turbo memory note and downloads', (
    tester,
  ) async {
    final provider = await pumpScreen(tester);

    expect(find.text('SDXS-512'), findsOneWidget);
    expect(find.text('683 MB · Recommended'), findsOneWidget);
    expect(find.text('SD-Turbo + TAESD'), findsOneWidget);
    expect(find.text('2.0 GB'), findsOneWidget);
    expect(find.text(ImageModelProfile.sdTurbo.memoryNote!), findsOneWidget);
    final generate = tester.widget<FilledButton>(
      find.byKey(const ValueKey<String>('generate_image_button')),
    );
    expect(generate.onPressed, isNull);

    await tester.tap(
      find.byKey(ValueKey<String>('install_${ImageModelProfile.sdxs.id}')),
    );
    await tester.pump();
    models.reportProgress(0.25);
    await tester.pump();
    expect(find.text('Downloading · 25%'), findsOneWidget);

    models.finishInstall();
    await tester.pumpAndSettle();
    expect(provider.isSelectedInstalled, isTrue);
    expect(find.text('683 MB · Recommended · Installed'), findsOneWidget);
  });

  testWidgets('renders phases, the generated image and the used seed', (
    tester,
  ) async {
    models.installed.add(ImageModelProfile.sdxs.id);
    final loadGate = Completer<void>();
    generation.loadGate = loadGate;
    await pumpScreen(tester);

    await tester.tap(
      find.byKey(const ValueKey<String>('generate_image_button')),
    );
    await tester.pump();
    expect(find.text('Loading SDXS-512…'), findsOneWidget);

    loadGate.complete();
    await tester.pump();
    final run = generation.generator!.runs.single;
    expect(run.request.seed, isNull);
    expect(run.request.steps, 1);
    expect(run.request.width, 512);

    run.progress(ImageGenerationPhase.encodingPrompt, 0, 1);
    await tester.pump();
    expect(find.text('Encoding prompt…'), findsOneWidget);
    run.progress(ImageGenerationPhase.sampling, 1, 1);
    await tester.pump();
    expect(find.text('Sampling step 1/1'), findsOneWidget);

    run.completeWith(seed: 1234);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('generated_image')),
      findsOneWidget,
    );
    expect(find.textContaining('Seed 1234 · 2×2'), findsOneWidget);
    expect(find.text('Loaded: SD 1.x on CPU'), findsOneWidget);

    await tester.tap(find.text('Reuse seed'));
    await tester.tap(find.text('256 px'));
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey<String>('generate_image_button')),
    );
    await tester.pump();
    final second = generation.generator!.runs.last;
    expect(second.request.seed, 1234);
    expect(second.request.width, 256);
    expect(generation.loadCount, 1, reason: 'the engine stays loaded');
    second.completeWith(seed: 1234);
    await tester.pumpAndSettle();
  });

  testWidgets('cancels a running generation', (tester) async {
    models.installed.add(ImageModelProfile.sdxs.id);
    await pumpScreen(tester);

    await tester.tap(
      find.byKey(const ValueKey<String>('generate_image_button')),
    );
    await tester.pump();
    await tester.pump();
    final run = generation.generator!.runs.single;
    run.progress(ImageGenerationPhase.sampling, 0, 1);
    await tester.pump();

    await tester.tap(
      find.byKey(const ValueKey<String>('cancel_image_generation_button')),
    );
    await tester.pumpAndSettle();

    expect(run.cancelled, isTrue);
    expect(find.text('Generation cancelled.'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('generate_image_button')),
      findsOneWidget,
    );
  });

  testWidgets('surfaces a memory refusal and offers to unload the chat model', (
    tester,
  ) async {
    models.installed.add(ImageModelProfile.sdTurbo.id);
    chatModelLoaded = true;
    const refusal =
        'The image model needs about 2.62 GiB (1.89 GiB of weights plus '
        'working memory), but only 1.50 GiB is available (MemAvailable).';
    generation.loadError = LlamaModelException(refusal);
    await pumpScreen(tester);

    await tester.tap(
      find.byKey(const ValueKey<String>('generate_image_button')),
    );
    await tester.pumpAndSettle();

    expect(find.text(refusal), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('unload_chat_model_button')),
    );
    await tester.pumpAndSettle();

    expect(chatUnloads, 1);
    expect(find.text(refusal), findsNothing);
    expect(
      find.text('Chat model unloaded. Generate again to retry.'),
      findsOneWidget,
    );
  });

  testWidgets('reports a busy runtime without the unload offer', (
    tester,
  ) async {
    models.installed.add(ImageModelProfile.sdxs.id);
    chatModelLoaded = true;
    generation.generateError = LlamaStateException(
      'Another image generation or image model load is running.',
    );
    await pumpScreen(tester);

    await tester.tap(
      find.byKey(const ValueKey<String>('generate_image_button')),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Another image generation or image model load is running.'),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('unload_chat_model_button')),
      findsNothing,
    );
  });

  test('frees the engine on model change and on dispose', () async {
    models.installed
      ..add(ImageModelProfile.sdxs.id)
      ..add(ImageModelProfile.sdTurbo.id);
    final provider = ImageGenerationProvider(
      generationService: generation,
      modelService: models,
      encodePng: (image) async => image.toPng(),
    );
    await provider.initialize();

    final first = provider.generate(prompt: 'fox');
    await pumpEventQueue();
    final sdxsEngine = generation.generator!;
    sdxsEngine.runs.single.completeWith(seed: 1);
    await first;

    await provider.selectModel(ImageModelProfile.sdTurbo);
    expect(sdxsEngine.disposed, isTrue);
    expect(provider.steps, 1);

    final second = provider.generate(prompt: 'fox');
    await pumpEventQueue();
    final turboEngine = generation.generator!;
    expect(
      generation.loadedModels.last.family,
      ImageGenerationModelFamily.sdTurbo,
    );
    expect(
      generation.loadedModels.last.files.taesd,
      '/models/taesd.safetensors',
    );
    provider.dispose();
    await second;
    await pumpEventQueue();
    expect(turboEngine.runs.single.cancelled, isTrue);
    expect(turboEngine.disposed, isTrue);
  });

  testWidgets('shows the unsupported state with the real services on the web', (
    tester,
  ) async {
    final provider = ImageGenerationProvider();
    addTearDown(provider.dispose);
    await tester.pumpWidget(
      MaterialApp(home: ImageGenerationScreen(provider: provider)),
    );
    await tester.pumpAndSettle();

    expect(provider.isSupported, isFalse);
    expect(ImageModelService().isSupported, isFalse);
    expect(
      find.byKey(const ValueKey<String>('image_generation_unsupported')),
      findsOneWidget,
    );
  }, skip: !kIsWeb);

  group('ImageModelProfile catalog', () {
    test('pins immutable sources with exact sizes and hashes', () {
      for (final profile in ImageModelProfile.defaultModels) {
        for (final source in profile.sources) {
          expect(source.url, contains('/resolve/'));
          expect(source.url, isNot(contains('/resolve/main/')));
          expect(source.sizeBytes, isPositive);
          expect(source.sha256, hasLength(64));
        }
      }
      expect(ImageModelProfile.sdxs.modelSource.sizeBytes, 682847200);
      expect(ImageModelProfile.sdxs.taesdSource, isNull);
      expect(ImageModelProfile.sdTurbo.modelSource.sizeBytes, 2023745376);
      expect(
        ImageModelProfile.sdTurbo.taesdSource!.filename,
        'taesd.safetensors',
      );
      expect(ImageModelProfile.sdxs.isRecommended, isTrue);
    });

    test('builds the library presets and their defaults', () {
      final sdxs = ImageModelProfile.sdxs.buildModel(modelPath: '/m.gguf');
      expect(sdxs.family, ImageGenerationModelFamily.sdxs);
      expect(sdxs.files.model, '/m.gguf');
      expect(ImageModelProfile.sdxs.defaults.steps, 1);

      final turbo = const InstalledImageModel(
        profile: ImageModelProfile.sdTurbo,
        modelPath: '/turbo.gguf',
        taesdPath: '/taesd.safetensors',
      ).toGenerationModel();
      expect(turbo.family, ImageGenerationModelFamily.sdTurbo);
      expect(turbo.files.taesd, '/taesd.safetensors');
      expect(turbo.defaults.guidanceScale, 1);
    });
  });
}

class FakeImageGenerationService implements ImageGenerationService {
  ImageGenerationCapabilities capabilities = const ImageGenerationCapabilities(
    isSupported: true,
    backendName: 'CPU',
    deviceNames: <String>['CPU'],
  );
  Object? loadError;
  Object? generateError;
  Completer<void>? loadGate;
  int loadCount = 0;
  final List<ImageGenerationModel> loadedModels = <ImageGenerationModel>[];
  FakeImageGenerator? generator;

  @override
  ImageGenerationCapabilities runtimeCapabilities() => capabilities;

  @override
  Future<ImageGenerator> load(ImageGenerationModel model) async {
    loadCount += 1;
    loadedModels.add(model);
    await loadGate?.future;
    if (loadError case final error?) {
      throw error;
    }
    return generator = FakeImageGenerator(generateError);
  }
}

class FakeImageGenerator implements ImageGenerator {
  final Object? generateError;
  final List<FakeImageGenerationRun> runs = <FakeImageGenerationRun>[];
  bool disposed = false;

  FakeImageGenerator(this.generateError);

  @override
  ImageGenerationCapabilities get capabilities =>
      const ImageGenerationCapabilities(
        isSupported: true,
        backendName: 'CPU',
        modelVersion: 'SD 1.x',
      );

  @override
  ImageGenerationRun generate(ImageGenerationRequest request) {
    if (generateError case final error?) {
      throw error;
    }
    final run = FakeImageGenerationRun(request);
    runs.add(run);
    return run;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    for (final run in runs) {
      run.cancel();
    }
  }
}

class FakeImageGenerationRun implements ImageGenerationRun {
  final ImageGenerationRequest request;
  final StreamController<ImageGenerationEvent> _events =
      StreamController<ImageGenerationEvent>();
  final Completer<ImageGenerationCompletion> _done =
      Completer<ImageGenerationCompletion>();
  bool cancelled = false;

  FakeImageGenerationRun(this.request);

  @override
  Stream<ImageGenerationEvent> get events => _events.stream;

  @override
  Future<ImageGenerationCompletion> get done => _done.future;

  void progress(ImageGenerationPhase phase, int step, int steps) {
    _events.add(
      ImageGenerationProgressEvent(
        phase: phase,
        step: step,
        steps: steps,
        imageIndex: 0,
        imageCount: 1,
      ),
    );
  }

  void completeWith({required int seed}) {
    final result = ImageGenerationResult(
      images: <GeneratedImage>[
        GeneratedImage(width: 2, height: 2, channels: 3, pixels: Uint8List(12)),
      ],
      seed: seed,
      elapsed: const Duration(milliseconds: 1500),
    );
    _events.add(ImageGenerationFinalEvent(result));
    _finish(ImageGenerationCompletion.completed(result));
  }

  @override
  void cancel() {
    cancelled = true;
    _finish(const ImageGenerationCompletion.cancelled());
  }

  void _finish(ImageGenerationCompletion completion) {
    if (_done.isCompleted) {
      return;
    }
    unawaited(_events.close());
    _done.complete(completion);
  }
}

class FakeImageModelService implements ImageModelService {
  final Set<String> installed = <String>{};
  int resolveCalls = 0;
  void Function(double progress)? _onProgress;
  Completer<void>? _install;

  void reportProgress(double progress) => _onProgress!(progress);

  void finishInstall() => _install!.complete();

  @override
  bool get isSupported => true;

  @override
  Future<InstalledImageModel?> resolve(ImageModelProfile profile) async {
    resolveCalls += 1;
    return installed.contains(profile.id) ? _installed(profile) : null;
  }

  @override
  Future<InstalledImageModel> install(
    ImageModelProfile profile, {
    required CancelToken cancelToken,
    required void Function(double progress) onProgress,
    required void Function() onVerifying,
  }) async {
    _onProgress = onProgress;
    final install = _install = Completer<void>();
    await install.future;
    installed.add(profile.id);
    return _installed(profile);
  }

  @override
  Future<void> delete(ImageModelProfile profile) async {
    installed.remove(profile.id);
  }

  InstalledImageModel _installed(ImageModelProfile profile) =>
      InstalledImageModel(
        profile: profile,
        modelPath: '/models/${profile.modelSource.filename}',
        taesdPath: profile.taesdSource == null
            ? null
            : '/models/${profile.taesdSource!.filename}',
      );
}
