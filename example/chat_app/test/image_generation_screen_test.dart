import 'dart:async';
import 'dart:ui';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';

import 'package:llamadart_chat_example/models/image_model_profile.dart';
import 'package:llamadart_chat_example/providers/image_generation_provider.dart';
import 'package:llamadart_chat_example/screens/image_generation_screen.dart';
import 'package:llamadart_chat_example/services/app_exit_coordinator.dart';
import 'package:llamadart_chat_example/services/image_generation_service.dart';
import 'package:llamadart_chat_example/services/image_model_service.dart';

void main() {
  late FakeImageGenerationService generation;
  late FakeImageModelService models;
  late bool chatModelLoaded;
  late int chatUnloads;
  late Object? chatUnloadError;

  setUp(() {
    generation = FakeImageGenerationService();
    models = FakeImageModelService();
    chatModelLoaded = false;
    chatUnloads = 0;
    chatUnloadError = null;
  });

  ImageGenerationProvider createUnownedProvider({
    AppExitCoordinator? exitCoordinator,
  }) => ImageGenerationProvider(
    generationService: generation,
    modelService: models,
    isChatModelLoaded: () => chatModelLoaded,
    unloadChatModel: () async {
      chatUnloads += 1;
      if (chatUnloadError case final error?) {
        throw error;
      }
      chatModelLoaded = false;
    },
    encodePng: (image) async => image.toPng(),
    exitCoordinator: exitCoordinator,
  );

  ImageGenerationProvider createProvider({
    AppExitCoordinator? exitCoordinator,
  }) {
    final provider = createUnownedProvider(exitCoordinator: exitCoordinator);
    addTearDown(provider.dispose);
    return provider;
  }

  Future<ImageGenerationProvider> initializedProvider() async {
    final provider = createProvider();
    await provider.initialize();
    return provider;
  }

  Future<ImageGenerationProvider> pumpScreen(
    WidgetTester tester, {
    AppExitCoordinator? exitCoordinator,
  }) async {
    tester.view
      ..physicalSize = const Size(900, 2400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final provider = createProvider(exitCoordinator: exitCoordinator);
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

  testWidgets('shows a checking state while the runtime probe runs', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(900, 2400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final checkGate = generation.checkGate = Completer<void>();
    final provider = createProvider();

    await tester.pumpWidget(
      MaterialApp(home: ImageGenerationScreen(provider: provider)),
    );
    await tester.pump();

    expect(generation.checkCalls, 1);
    expect(provider.isInitialized, isFalse);
    expect(
      find.byKey(const ValueKey<String>('image_generation_checking_runtime')),
      findsOneWidget,
    );
    expect(find.text('Checking the image runtime…'), findsOneWidget);
    expect(models.resolveCalls, 0);

    checkGate.complete();
    await tester.pumpAndSettle();

    expect(provider.isInitialized, isTrue);
    expect(
      find.byKey(const ValueKey<String>('image_generation_checking_runtime')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('generate_image_button')),
      findsOneWidget,
    );
  });

  testWidgets('shows a failed runtime check as unsupported', (tester) async {
    generation.checkError = StateError('probe isolate failed');

    await pumpScreen(tester);

    expect(
      find.byKey(const ValueKey<String>('image_generation_unsupported')),
      findsOneWidget,
    );
    expect(find.text('Bad state: probe isolate failed'), findsOneWidget);
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
    expect(run.request.guidanceScale, 1);
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
        'working memory), but only 1.50 GiB is available (MemAvailable). Use '
        'a smaller or more quantized model, free memory, or set '
        'ImageModelParams.checkMemory to false to try anyway.';
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

  testWidgets('offers no chat unload for a load failure that is not memory', (
    tester,
  ) async {
    models.installed.add(ImageModelProfile.sdxs.id);
    chatModelLoaded = true;
    const missing =
        'Image-generation model file not found: '
        '"/models/sdxs-512-tinySDdistilled_Q8_0.gguf".';
    generation.loadError = LlamaModelException(missing);
    await pumpScreen(tester);

    await tester.tap(
      find.byKey(const ValueKey<String>('generate_image_button')),
    );
    await tester.pumpAndSettle();

    expect(find.text(missing), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('unload_chat_model_button')),
      findsNothing,
    );
  });

  testWidgets('shows a chat model unload failure', (tester) async {
    models.installed.add(ImageModelProfile.sdTurbo.id);
    chatModelLoaded = true;
    chatUnloadError = StateError('chat engine is busy');
    generation.loadError = LlamaModelException(
      'The image model needs about 2.62 GiB (1.89 GiB of weights plus '
      'working memory), but only 1.50 GiB is available (MemAvailable).',
    );
    await pumpScreen(tester);
    await tester.tap(
      find.byKey(const ValueKey<String>('generate_image_button')),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('unload_chat_model_button')),
    );
    await tester.pumpAndSettle();

    expect(chatUnloads, 1);
    expect(
      find.text(
        'Could not unload the chat model: Bad state: chat engine is busy',
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('unload_chat_model_button')),
      findsNothing,
    );
  });

  testWidgets('cancels a running generation when the app is paused', (
    tester,
  ) async {
    models.installed.add(ImageModelProfile.sdxs.id);
    await pumpScreen(tester);
    await tester.tap(
      find.byKey(const ValueKey<String>('generate_image_button')),
    );
    await tester.pump();
    await tester.pump();
    final run = generation.generator!.runs.single;

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    addTearDown(
      () => tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );
    await tester.pumpAndSettle();

    expect(run.cancelled, isTrue);
    expect(find.text('Generation cancelled.'), findsOneWidget);
  });

  AppExitCoordinator listenForAppExit() {
    final exitCoordinator = AppExitCoordinator();
    final listener = AppLifecycleListener(
      onExitRequested: exitCoordinator.handleExitRequest,
    );
    addTearDown(listener.dispose);
    return exitCoordinator;
  }

  testWidgets('frees the image model before the app exits', (tester) async {
    models.installed.add(ImageModelProfile.sdxs.id);
    await pumpScreen(tester, exitCoordinator: listenForAppExit());
    await tester.tap(
      find.byKey(const ValueKey<String>('generate_image_button')),
    );
    await tester.pump();
    await tester.pump();
    final engine = generation.generator!;
    final run = engine.runs.single;

    final response = await tester.binding.handleRequestAppExit();

    expect(response, AppExitResponse.exit);
    expect(engine.disposed, isTrue);
    expect(run.cancelled, isTrue);
  });

  testWidgets('frees a model still loading when the app exits', (tester) async {
    models.installed.add(ImageModelProfile.sdxs.id);
    final loadGate = generation.loadGate = Completer<void>();
    await pumpScreen(tester, exitCoordinator: listenForAppExit());
    await tester.tap(
      find.byKey(const ValueKey<String>('generate_image_button')),
    );
    await tester.pump();

    var exited = false;
    final exit = tester.binding.handleRequestAppExit().whenComplete(
      () => exited = true,
    );
    await tester.pump();
    expect(exited, isFalse);

    loadGate.complete();
    expect(await exit, AppExitResponse.exit);
    final engine = generation.generator!;
    expect(engine.disposed, isTrue);
    expect(engine.runs, isEmpty);
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
      generation.loadedModels.last.components.single.source.path,
      '/models/taesd.safetensors',
    );
    provider.dispose();
    await second;
    await pumpEventQueue();
    expect(turboEngine.runs.single.cancelled, isTrue);
    expect(turboEngine.disposed, isTrue);
  });

  group('ImageGenerationProvider', () {
    test('deleting the loaded model frees its engine', () async {
      models.installed.add(ImageModelProfile.sdxs.id);
      final provider = await initializedProvider();
      final first = provider.generate(prompt: 'fox');
      await pumpEventQueue();
      final engine = generation.generator!;
      engine.runs.single.completeWith(seed: 1);
      await first;

      await provider.deleteModel(ImageModelProfile.sdxs);

      expect(engine.disposed, isTrue);
      expect(provider.loadedEngineLabel, isNull);
      expect(provider.isSelectedInstalled, isFalse);
    });

    test('ignores generate and model changes while a delete runs', () async {
      models.installed
        ..add(ImageModelProfile.sdxs.id)
        ..add(ImageModelProfile.sdTurbo.id);
      final provider = await initializedProvider();
      final deleteGate = models.deleteGate = Completer<void>();

      final deletion = provider.deleteModel(ImageModelProfile.sdxs);
      await pumpEventQueue();
      expect(provider.canGenerate, isFalse);
      expect(provider.canChangeModel, isFalse);
      await provider.generate(prompt: 'fox');
      await provider.selectModel(ImageModelProfile.sdTurbo);

      expect(generation.loadCount, 0);
      expect(provider.selectedProfile.id, ImageModelProfile.sdxs.id);
      deleteGate.complete();
      await deletion;
      expect(provider.canChangeModel, isTrue);
      expect(provider.isSelectedInstalled, isFalse);
    });

    test('frees an engine whose load finishes after dispose', () async {
      models.installed.add(ImageModelProfile.sdxs.id);
      final loadGate = generation.loadGate = Completer<void>();
      final provider = createUnownedProvider();
      await provider.initialize();

      final generating = provider.generate(prompt: 'fox');
      await pumpEventQueue();
      provider.dispose();
      loadGate.complete();
      await generating;

      expect(generation.generator!.disposed, isTrue);
      expect(generation.generator!.runs, isEmpty);
    });

    test('honors a cancel requested while the model loads', () async {
      models.installed.add(ImageModelProfile.sdxs.id);
      final loadGate = generation.loadGate = Completer<void>();
      final provider = await initializedProvider();

      final generating = provider.generate(prompt: 'fox');
      await pumpEventQueue();
      expect(provider.stage, ImageGenerationStage.loadingModel);
      provider.cancelGeneration();
      loadGate.complete();
      await pumpEventQueue();
      expect(generation.generator!.runs, isEmpty);
      await generating;

      expect(provider.stage, ImageGenerationStage.idle);
      expect(provider.status, 'Generation cancelled.');
    });

    test('honors a cancel requested while the generation starts', () async {
      models.installed.add(ImageModelProfile.sdxs.id);
      final generateGate = generation.generateGate = Completer<void>();
      final provider = await initializedProvider();

      final generating = provider.generate(prompt: 'fox');
      await pumpEventQueue();
      expect(provider.stage, ImageGenerationStage.generating);
      final run = generation.generator!.runs.single;
      provider.cancelGeneration();
      expect(run.cancelled, isFalse);
      generateGate.complete();
      await pumpEventQueue();

      expect(run.cancelled, isTrue);
      await generating;
      expect(provider.stage, ImageGenerationStage.idle);
      expect(provider.status, 'Generation cancelled.');
    });

    test('ignores a second generate or a model change while busy', () async {
      models.installed
        ..add(ImageModelProfile.sdxs.id)
        ..add(ImageModelProfile.sdTurbo.id);
      final loadGate = generation.loadGate = Completer<void>();
      final provider = await initializedProvider();

      final generating = provider.generate(prompt: 'fox');
      await pumpEventQueue();
      final second = provider.generate(prompt: 'owl');
      await pumpEventQueue();
      expect(generation.loadCount, 1);
      await second;
      await provider.selectModel(ImageModelProfile.sdTurbo);
      expect(provider.selectedProfile.id, ImageModelProfile.sdxs.id);

      loadGate.complete();
      await pumpEventQueue();
      generation.generator!.runs.single.completeWith(seed: 1);
      await generating;
      expect(provider.output!.profile.id, ImageModelProfile.sdxs.id);
    });

    test('stops initializing when disposed during the runtime check', () async {
      models.installed.add(ImageModelProfile.sdxs.id);
      final checkGate = generation.checkGate = Completer<void>();
      final provider = createUnownedProvider();
      var notifications = 0;
      provider.addListener(() => notifications += 1);

      final initializing = provider.initialize();
      await pumpEventQueue();
      provider.dispose();
      checkGate.complete();
      await initializing;

      expect(notifications, 0);
      expect(models.resolveCalls, 0);
      expect(provider.isInitialized, isFalse);
    });

    test('cancelInstall cancels the running download', () async {
      final provider = await initializedProvider();

      final installing = provider.installModel(ImageModelProfile.sdxs);
      await pumpEventQueue();
      provider.cancelInstall();
      expect(models.lastCancelToken!.isCancelled, isTrue);
      await installing;

      expect(provider.installingId, isNull);
      expect(provider.error, isNull);
      expect(provider.isInstalled(ImageModelProfile.sdxs), isFalse);
    });

    test('dispose cancels the running download', () async {
      final provider = createUnownedProvider();
      await provider.initialize();

      final installing = provider.installModel(ImageModelProfile.sdxs);
      await pumpEventQueue();
      provider.dispose();
      expect(models.lastCancelToken!.isCancelled, isTrue);
      await installing;
    });
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

  group('app exit', () {
    late AppExitCoordinator exitCoordinator;

    setUp(() => exitCoordinator = AppExitCoordinator());

    Future<bool> isDone(Future<void> future) async {
      var done = false;
      unawaited(future.whenComplete(() => done = true));
      await pumpEventQueue();
      return done;
    }

    Future<ImageGenerationProvider> providerWithLoadedModel({
      bool owned = true,
    }) async {
      models.installed
        ..add(ImageModelProfile.sdxs.id)
        ..add(ImageModelProfile.sdTurbo.id);
      final provider = owned
          ? createProvider(exitCoordinator: exitCoordinator)
          : createUnownedProvider(exitCoordinator: exitCoordinator);
      await provider.initialize();
      final generating = provider.generate(prompt: 'fox');
      await pumpEventQueue();
      generation.generator!.runs.single.completeWith(seed: 1);
      await generating;
      return provider;
    }

    test('waits for a model loading in a provider already disposed', () async {
      models.installed.add(ImageModelProfile.sdxs.id);
      final loadGate = generation.loadGate = Completer<void>();
      final provider = createUnownedProvider(exitCoordinator: exitCoordinator);
      await provider.initialize();
      final generating = provider.generate(prompt: 'fox');
      await pumpEventQueue();

      provider.dispose();
      final exit = exitCoordinator.releaseAll();

      expect(await isDone(exit), isFalse);
      loadGate.complete();
      await exit;
      expect(generation.generator!.disposed, isTrue);
      expect(generation.generator!.runs, isEmpty);
      await generating;
    });

    test('waits for a generation in a provider already disposed', () async {
      final provider = await providerWithLoadedModel(owned: false);
      final generating = provider.generate(prompt: 'owl');
      await pumpEventQueue();
      final engine = generation.generator!;
      final disposeGate = engine.disposeGate = Completer<void>();

      provider.dispose();
      final exit = exitCoordinator.releaseAll();

      expect(await isDone(exit), isFalse);
      expect(engine.runs.last.cancelled, isTrue);
      disposeGate.complete();
      await exit;
      await generating;
    });

    test('waits for an engine freed by a model switch', () async {
      final provider = await providerWithLoadedModel();
      final engine = generation.generator!;
      final disposeGate = engine.disposeGate = Completer<void>();

      final switching = provider.selectModel(ImageModelProfile.sdTurbo);
      final exit = exitCoordinator.releaseAll();

      expect(await isDone(exit), isFalse);
      disposeGate.complete();
      await exit;
      await switching;
      expect(engine.disposed, isTrue);
    });

    test('waits for an engine freed by a model delete', () async {
      final provider = await providerWithLoadedModel();
      final engine = generation.generator!;
      final disposeGate = engine.disposeGate = Completer<void>();

      final deleting = provider.deleteModel(ImageModelProfile.sdxs);
      final exit = exitCoordinator.releaseAll();

      expect(await isDone(exit), isFalse);
      disposeGate.complete();
      await exit;
      await deleting;
    });

    test('ignores Generate once the exit started', () async {
      final provider = await providerWithLoadedModel();
      final engine = generation.generator!;
      final disposeGate = engine.disposeGate = Completer<void>();
      final exit = exitCoordinator.releaseAll();
      await pumpEventQueue();

      expect(provider.canGenerate, isFalse);
      await provider.selectModel(ImageModelProfile.sdTurbo);
      await provider.generate(prompt: 'owl');
      expect(generation.loadCount, 1);

      disposeGate.complete();
      await exit;
      await provider.generate(prompt: 'owl');
      expect(generation.loadCount, 1);
      expect(engine.runs, hasLength(1));
      expect(exitCoordinator.isExiting, isTrue);
    });

    test('frees a model whose load the exit request overtook', () async {
      models.installed.add(ImageModelProfile.sdxs.id);
      final loadGate = generation.loadGate = Completer<void>();
      final provider = createProvider(exitCoordinator: exitCoordinator);
      await provider.initialize();
      final generating = provider.generate(prompt: 'fox');
      await pumpEventQueue();

      final exit = exitCoordinator.releaseAll();
      loadGate.complete();
      await exit;
      await generating;

      expect(generation.generator!.disposed, isTrue);
      expect(generation.generator!.runs, isEmpty);
      expect(provider.status, 'Generation cancelled.');
    });

    testWidgets(
      'registers the screen\'s own provider until the screen closes',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: ImageGenerationScreen(exitCoordinator: exitCoordinator),
          ),
        );

        expect(exitCoordinator.releaseCount, 1);

        await tester.pumpWidget(const SizedBox());

        expect(exitCoordinator.releaseCount, 0);
      },
    );

    test('hands its release to the exit when disposed', () async {
      final provider = createUnownedProvider(exitCoordinator: exitCoordinator);
      expect(exitCoordinator.releaseCount, 1);

      provider.dispose();

      expect(exitCoordinator.releaseCount, 0);
    });

    test('skips the runtime check once the exit started', () async {
      final blocker = Completer<void>();
      exitCoordinator.track(blocker.future);
      final exit = exitCoordinator.releaseAll();
      final provider = createProvider(exitCoordinator: exitCoordinator);

      await provider.initialize();

      expect(generation.checkCalls, 0);
      expect(provider.isInitialized, isFalse);
      blocker.complete();
      await exit;
    });

    test('waits for every engine when one fails to free', () async {
      final provider = await providerWithLoadedModel();
      final switched = generation.generator!;
      final switchedGate = switched.disposeGate = Completer<void>();
      final switching = provider.selectModel(ImageModelProfile.sdTurbo);
      final generating = provider.generate(prompt: 'owl');
      await pumpEventQueue();
      generation.generator!.runs.single.completeWith(seed: 2);
      await generating;
      generation.generator!.disposeError = StateError('Metal free failed');

      final exit = exitCoordinator.releaseAll();

      expect(await isDone(exit), isFalse);
      switchedGate.complete();
      await exit;
      await switching;
      expect(switched.disposed, isTrue);
    });

    test('waits for the runtime check', () async {
      final checkGate = generation.checkGate = Completer<void>();
      final provider = createUnownedProvider(exitCoordinator: exitCoordinator);
      final initializing = provider.initialize();
      await pumpEventQueue();

      provider.dispose();
      final exit = exitCoordinator.releaseAll();

      expect(await isDone(exit), isFalse);
      checkGate.complete();
      await exit;
      await initializing;
    });
  });

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
      // Revisions, sizes and SHA-256 values checked against Hugging Face
      // (`x-repo-commit`, `x-linked-size`, `x-linked-etag`) and the files.
      final sdxs = ImageModelProfile.sdxs.modelSource;
      expect(sdxs.url, contains('/3144d898d61492f8382ffcabec055733fc5b2a0e/'));
      expect(sdxs.sizeBytes, 682847200);
      expect(
        sdxs.sha256,
        '409ab23582ee074c6b9d5395784fc0741b0599fb9d138686c69087c71678eb6a',
      );
      expect(ImageModelProfile.sdxs.taesdSource, isNull);

      final turbo = ImageModelProfile.sdTurbo.modelSource;
      expect(turbo.url, contains('/19a31586d02d64a73b4419bc193b3ecfaf38e1f0/'));
      expect(turbo.sizeBytes, 2023745376);
      expect(
        turbo.sha256,
        'd50be7655f0a554cf8041c145d88b210bd5f3c545423119dee62ae08cae51580',
      );

      final taesd = ImageModelProfile.sdTurbo.taesdSource!;
      expect(taesd.url, contains('/614f76814bbe30edbe2e627ace1c2234c81a2c0e/'));
      expect(taesd.sizeBytes, 9793292);
      expect(
        taesd.sha256,
        'db169d69145ec4ff064e49d99c95fa05d3eb04ee453de35824a6d0f325513549',
      );
      expect(taesd.filename, 'taesd.safetensors');
      expect(ImageModelProfile.sdxs.isRecommended, isTrue);
    });

    test('builds library models with the settings of each profile', () {
      final sdxs = ImageModelProfile.sdxs.buildModel(modelPath: '/m.gguf');
      expect(sdxs.source.path, '/m.gguf');
      expect(sdxs.components, isEmpty);
      expect(
        (ImageModelProfile.sdxs.steps, ImageModelProfile.sdxs.guidanceScale),
        (1, 1.0),
      );

      final turbo = const InstalledImageModel(
        profile: ImageModelProfile.sdTurbo,
        modelPath: '/turbo.gguf',
        taesdPath: '/taesd.safetensors',
      ).toGenerationModel();
      expect(turbo.source.path, '/turbo.gguf');
      expect(turbo.components.single.source.path, '/taesd.safetensors');
      expect(turbo.components.single.role, isNull);
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
  Completer<void>? generateGate;
  int loadCount = 0;
  final List<ImageGenerationModel> loadedModels = <ImageGenerationModel>[];
  FakeImageGenerator? generator;

  Completer<void>? checkGate;
  Object? checkError;
  int checkCalls = 0;

  @override
  Future<ImageGenerationCapabilities> checkRuntime() async {
    checkCalls += 1;
    await checkGate?.future;
    if (checkError case final error?) {
      throw error;
    }
    return capabilities;
  }

  @override
  Future<ImageGenerator> load(ImageGenerationModel model) async {
    loadCount += 1;
    loadedModels.add(model);
    await loadGate?.future;
    if (loadError case final error?) {
      throw error;
    }
    return generator = FakeImageGenerator(
      generateError,
      generateGate: generateGate,
    );
  }
}

class FakeImageGenerator implements ImageGenerator {
  final Object? generateError;
  final Completer<void>? generateGate;
  final List<FakeImageGenerationRun> runs = <FakeImageGenerationRun>[];
  bool disposed = false;
  Completer<void>? disposeGate;
  Object? disposeError;

  FakeImageGenerator(this.generateError, {this.generateGate});

  @override
  Future<ImageGenerationCapabilities> get capabilities async =>
      const ImageGenerationCapabilities(
        isSupported: true,
        backendName: 'CPU',
        modelVersion: 'SD 1.x',
      );

  @override
  Future<ImageGenerationRun> generate(ImageGenerationRequest request) async {
    if (generateError case final error?) {
      throw error;
    }
    final run = FakeImageGenerationRun(request);
    runs.add(run);
    await generateGate?.future;
    return run;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    for (final run in runs) {
      run.cancel();
    }
    await disposeGate?.future;
    if (disposeError case final error?) {
      throw error;
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
  Completer<void>? deleteGate;
  CancelToken? lastCancelToken;
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
    lastCancelToken = cancelToken;
    final install = _install = Completer<void>();
    await Future.any<void>([
      install.future,
      cancelToken.whenCancel.then((error) => throw error),
    ]);
    installed.add(profile.id);
    return _installed(profile);
  }

  @override
  Future<void> delete(ImageModelProfile profile) async {
    await deleteGate?.future;
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
