import 'dart:async';
import 'dart:typed_data';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:test/test.dart';

import 'studio_test_fakes.dart';

void main() {
  for (final phase in ['cache', 'load', 'request']) {
    test('Notebook shutdown at ASR $phase prevents late work', () async {
      final storage = _Storage();
      final native = _Native();
      final gate = Completer<void>();
      if (phase == 'cache') storage.cacheGate = gate;
      if (phase == 'load') native.loadGate = gate;
      if (phase == 'request') native.requestGate = gate;
      final notebook = NotebookController(
        storagePort: storage,
        embeddingPort: DummyPlaygroundPort(),
        sttPort: _Speech(native),
        isWeb: false,
        isMobile: false,
      );
      addTearDown(() async {
        await notebook.dispose();
        await storage.dispose();
      });
      final note = await notebook.createNote(audioWavBytes: Uint8List(8));
      final transcribing = notebook.transcribeAudioNote(note.id);
      await switch (phase) {
        'cache' => storage.cacheEntered.future,
        'load' => native.loadEntered.future,
        _ => native.requestEntered.future,
      };
      var shutdownReturned = false;
      final stopping = notebook.dispose().then((_) => shutdownReturned = true);
      await Future<void>.delayed(Duration.zero);
      final earlyReturn = shutdownReturned;
      gate.complete();
      final result = await transcribing;
      await stopping;
      expect(earlyReturn, phase == 'cache');
      expect(result, isNull);
      native.closed = true;
      expect(await notebook.transcribeAudioNote(note.id), isNull);
      expect(native.events, switch (phase) {
        'cache' => isEmpty,
        'load' => ['load'],
        _ => ['load', 'request'],
      });
    });
  }

  test('Notebook ASR download cannot allocate after shutdown', () async {
    final storage = _Storage()..downloadGate = Completer<void>();
    final native = _Native();
    final notebook = NotebookController(
      storagePort: storage,
      embeddingPort: DummyPlaygroundPort(),
      sttPort: _Speech(native),
      isWeb: false,
      isMobile: false,
    );
    addTearDown(() async {
      await notebook.dispose();
      await storage.dispose();
    });
    final note = await notebook.createNote(audioWavBytes: Uint8List(8));
    final transcribing = notebook.transcribeAudioNote(note.id);
    await storage.downloadEntered.future;
    await notebook.dispose();
    native.closed = true;
    storage.downloadGate!.complete();
    final result = await transcribing;
    expect(native.events, isEmpty);
    expect(result, isNull);
  });

  for (final unload in [false, true]) {
    test(
      'Playground aborts its port request after Lab lifetime change (unload=$unload)',
      () async {
        final storage = _Storage()..cacheGate = Completer<void>();
        final native = _Native();
        final port = _Lab(native);
        final lab = LabModelCoordinator(
          storagePort: storage,
          modelLoader: port,
          isWeb: false,
          isMobile: false,
        );
        final playground = PlaygroundWorkspaceController(
          storagePort: storage,
          playgroundPort: port,
          labModels: lab,
          isWeb: false,
          isMobile: false,
        );
        addTearDown(() async {
          await playground.dispose();
          await lab.dispose();
          await storage.dispose();
        });
        final request = playground.runEmbeddings(['hello', 'world']);
        await storage.cacheEntered.future;
        if (unload) {
          await lab.unloadModels();
        } else {
          await playground.dispose();
          await lab.dispose();
          native.closed = true;
        }
        storage.cacheGate!.complete();
        await request;
        expect(native.events, isEmpty);
      },
    );
  }
  for (final lane in ['tts', 'stt', 'image', 'lab']) {
    group(lane, () {
      late _Harness h;
      setUp(() => h = _Harness(lane));
      tearDown(() async {
        await h.dispose();
        await h.storage.dispose();
      });

      test('shutdown invalidates a download without waiting for it', () async {
        h.storage.downloadGate = Completer<void>();
        final loading = h.load();
        await h.storage.downloadEntered.future;
        await h.dispose();
        h.native.closed = true;
        h.storage.downloadGate!.complete();
        await loading;
        expect(h.native.events, isEmpty);
      });

      test(
        'unload invalidates pending download and allows a fresh retry',
        () async {
          h.storage.downloadGate = Completer<void>();
          final loading = h.load();
          await h.storage.downloadEntered.future;
          await h.unload();
          h.storage.downloadGate!.complete();
          await loading;
          expect(h.native.loads, 0);
          h.storage.downloadGate = null;
          await h.load();
          expect(h.native.loads, 1);
        },
      );

      test('shutdown drains a native load already in progress', () async {
        h.native.loadGate = Completer<void>();
        final loading = h.load();
        await h.native.loadEntered.future;
        var shutdownReturned = false;
        final shuttingDown = h.dispose().then((_) => shutdownReturned = true);
        await Future<void>.delayed(Duration.zero);
        final returnedBeforeNativeLoad = shutdownReturned;
        h.native.loadGate!.complete();
        await Future.wait([loading, shuttingDown]);
        expect(returnedBeforeNativeLoad, isFalse);
        h.native.closed = true;
        await h.load();
        await h.request();
        expect(h.native.events, ['load']);
      });

      test(
        'shutdown invalidates a cached-model request before download',
        () async {
          h.storage.cacheGate = Completer<void>();
          final request = h.request();
          await h.storage.cacheEntered.future;
          await h.dispose();
          h.native.closed = true;
          h.storage.cacheGate!.complete();
          await request;
          expect(h.native.events, isEmpty);
        },
      );

      test(
        'unload invalidates a cached-model request before download',
        () async {
          h.storage.cacheGate = Completer<void>();
          final request = h.request();
          await h.storage.cacheEntered.future;
          await h.unload();
          h.storage.cacheGate!.complete();
          await request;
          expect(h.native.loads, 0);
          expect(h.native.requests, 0);
        },
      );

      test('concurrent native loads are serialized', () async {
        h.native.loadGate = Completer<void>();
        final first = h.load();
        await h.native.loadEntered.future;
        final second = h.load();
        await Future<void>.delayed(Duration.zero);
        h.native.loadGate!.complete();
        await Future.wait([first, second]);
        expect(h.native.loads, 2);
        expect(h.native.maxActiveLoads, 1);
      });

      if (lane != 'lab') {
        for (final unload in [false, true]) {
          test(
            'entered inference drains and its stale result is discarded (unload=$unload)',
            () async {
              await h.load();
              h.native.requestGate = Completer<void>();
              final request = h.request();
              await h.native.requestEntered.future;
              var shutdownReturned = false;
              final stopping = (unload ? h.unload() : h.dispose()).then(
                (_) => shutdownReturned = true,
              );
              await Future<void>.delayed(Duration.zero);
              final earlyReturn = shutdownReturned;
              h.native.requestGate!.complete();
              final result = await request;
              await stopping;
              expect(earlyReturn, isFalse);
              expect(result, isNull);
              expect(h.native.requests, 1);
            },
          );
        }
      }

      test('failed download remains retryable', () async {
        h.storage.failDownload = true;
        try {
          await h.load();
        } catch (_) {
          // Lab reports load errors to callers; Speech/Image report in state.
        }
        expect(h.native.loads, 0);
        h.storage.failDownload = false;
        await h.load();
        await h.request();
        expect(h.native.loads, 1);
        expect(h.native.requests, lane == 'lab' ? 0 : 1);
      });
    });
  }
}

class _Native {
  final events = <String>[];
  final loadEntered = Completer<void>();
  final requestEntered = Completer<void>();
  Completer<void>? loadGate;
  Completer<void>? requestGate;
  bool closed = false;
  int loads = 0;
  int requests = 0;
  int activeLoads = 0;
  int maxActiveLoads = 0;
  Future<void> load() async {
    events.add(closed ? 'LOAD AFTER DISPOSE' : 'load');
    loads++;
    activeLoads++;
    if (activeLoads > maxActiveLoads) maxActiveLoads = activeLoads;
    if (!loadEntered.isCompleted) loadEntered.complete();
    await loadGate?.future;
    activeLoads--;
  }

  Future<void> request() async {
    events.add(closed ? 'REQUEST AFTER DISPOSE' : 'request');
    requests++;
    if (!requestEntered.isCompleted) requestEntered.complete();
    await requestGate?.future;
  }
}

class _Harness {
  _Harness(String lane) {
    if (lane == 'tts' || lane == 'stt') {
      final c = SpeechWorkspaceController(
        storagePort: storage,
        speechPort: _Speech(native),
        isWeb: false,
        isMobile: false,
      );
      final model = lane == 'tts'
          ? c.availableTtsModels.first
          : c.availableSttModels.first;
      load = () =>
          lane == 'tts' ? c.loadTtsModel(model) : c.loadSttModel(model);
      request = () => lane == 'tts'
          ? c.synthesizeText(text: 'hello')
          : c.transcribeAudio(audioBytes: Uint8List(1));
      unload = c.unloadModels;
      dispose = c.dispose;
    } else if (lane == 'image') {
      final c = ImageWorkspaceController(
        storagePort: storage,
        imagePort: _Image(native),
        isWeb: false,
        isMobile: false,
      );
      load = () => c.loadModel(c.availableModels.first);
      request = () => c.generate(prompt: 'hello');
      unload = c.unloadModel;
      dispose = c.dispose;
    } else {
      final c = LabModelCoordinator(
        storagePort: storage,
        modelLoader: _Lab(native),
        isWeb: false,
        isMobile: false,
      );
      final model = c
          .availableModelsForSpecialty(StudioModelSpecialty.embedding)
          .first;
      load = () => c.loadLabModel(model);
      request = () async => c
          .ensureCachedSpecialtyLoaded(StudioModelSpecialty.embedding)
          .onError<LlamaStateException>((_, _) {});
      unload = c.unloadModels;
      dispose = c.dispose;
    }
  }
  final storage = _Storage();
  final native = _Native();
  late final Future<void> Function() load;
  late final Future<Object?> Function() request;
  late final Future<void> Function() unload;
  late final Future<void> Function() dispose;
}

class _Storage extends FakeStudioStoragePort {
  final downloadEntered = Completer<void>();
  final cacheEntered = Completer<void>();
  Completer<void>? downloadGate;
  Completer<void>? cacheGate;
  bool failDownload = false;
  @override
  Future<ResolvedModelAssets> ensureDownloaded(
    StudioModelDescriptor descriptor, {
    required bool isWeb,
    String? bearerToken,
  }) async {
    if (!downloadEntered.isCompleted) downloadEntered.complete();
    await downloadGate?.future;
    if (failDownload) throw StateError('controlled download failure');
    return super.ensureDownloaded(
      descriptor,
      isWeb: isWeb,
      bearerToken: bearerToken,
    );
  }

  @override
  Future<bool> isCached(
    StudioModelDescriptor descriptor, {
    required bool isWeb,
  }) async {
    if (!cacheEntered.isCompleted) cacheEntered.complete();
    await cacheGate?.future;
    return true;
  }
}

class _Speech extends DummySpeechPort {
  _Speech(this.native);
  final _Native native;
  @override
  Future<TextToSpeechCapabilities> loadTtsModel({
    required ResolvedModelAssets assets,
    required bool isWeb,
  }) async {
    await native.load();
    return super.loadTtsModel(assets: assets, isWeb: isWeb);
  }

  @override
  Future<SpeechToTextCapabilities> loadSttModel({
    required ResolvedModelAssets assets,
    required bool isWeb,
  }) async {
    await native.load();
    return super.loadSttModel(assets: assets, isWeb: isWeb);
  }

  @override
  Future<StudioSynthesizedClip> synthesize({
    required String text,
    required bool isWeb,
    String? language,
    String? voice,
    Uint8List? speakerReferenceBytes,
    String? speakerReferencePath,
    double temperature = 0.8,
    void Function(int, TextToSpeechProgressPhase)? onProgress,
  }) async {
    await native.request();
    return super.synthesize(text: text, isWeb: isWeb);
  }

  @override
  Future<StudioTranscriptResult> transcribe({
    Uint8List? audioBytes,
    String? audioFilePath,
    String? contextPrompt,
  }) async {
    await native.request();
    return super.transcribe(audioBytes: audioBytes);
  }
}

class _Image extends CountingMockImagePort {
  _Image(this.native);
  final _Native native;
  @override
  Future<ImageGenerationCapabilities> loadModel({
    required ResolvedModelAssets assets,
    ComputeDevice device = ComputeDevice.auto,
  }) async {
    await native.load();
    return super.loadModel(assets: assets, device: device);
  }

  @override
  Future<StudioGeneratedImageItem> generateImage({
    required String prompt,
    String negativePrompt = '',
    int width = 512,
    int height = 512,
    int steps = 1,
    double guidanceScale = 1.0,
    int? seed,
    void Function(ImageGenerationProgressEvent)? onProgress,
  }) async {
    await native.request();
    return super.generateImage(prompt: prompt);
  }
}

class _Lab extends DummyPlaygroundPort {
  _Lab(this.native);
  final _Native native;
  @override
  Future<void> loadDedicatedModel({
    required ResolvedModelAssets assets,
    required bool isWeb,
  }) => native.load();

  @override
  Future<EmbeddingComparisonResult> computeEmbeddings(
    List<String> texts,
  ) async {
    await native.request();
    return super.computeEmbeddings(texts);
  }
}
