@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/backends/webgpu/interop.dart';
import 'package:llamadart/src/backends/webgpu/webgpu_backend.dart';
import 'package:test/test.dart';

void main() {
  group('WebGPU multimodal engine integration', () {
    late JSObject bridge;
    late WebGpuLlamaBackend backend;
    late LlamaEngine engine;
    late bool mmLoaded;
    late bool sawAudioPart;
    String? lastStateSavePath;
    List<int>? lastStateSaveTokens;
    String? lastStateLoadPath;
    int? lastStateLoadCapacity;

    setUp(() {
      bridge = JSObject();
      mmLoaded = false;
      sawAudioPart = false;
      lastStateSavePath = null;
      lastStateSaveTokens = null;
      lastStateLoadPath = null;
      lastStateLoadCapacity = null;

      bridge.setProperty(
        'loadModelFromUrl'.toJS,
        ((String url, JSObject? config) {
          return Future<void>.value().toJS;
        }).toJS,
      );

      bridge.setProperty(
        'createCompletion'.toJS,
        ((String prompt, JSObject opts) {
          final parts = opts.getProperty('parts'.toJS);
          if (parts.isA<JSArray>() && (parts as JSArray).length > 0) {
            for (int i = 0; i < parts.length; i++) {
              final rawPart = parts.getProperty(i.toJS);
              if (!rawPart.isA<JSObject>()) {
                continue;
              }

              final part = rawPart as JSObject;
              final type = part.getProperty('type'.toJS);
              if (type.isA<JSString>() &&
                  (type as JSString).toDart == 'audio') {
                sawAudioPart = true;
              }
            }
          }

          final onToken = opts.getProperty('onToken'.toJS) as JSFunction?;
          if (onToken != null) {
            final piece = JSUint8Array.withLength(5);
            piece.toDart.setAll(0, <int>[72, 101, 108, 108, 111]);
            onToken.callAsFunction(null, piece, 'Hello'.toJS);
          }

          return Future<void>.value().toJS;
        }).toJS,
      );

      bridge.setProperty(
        'loadMultimodalProjector'.toJS,
        ((String path) {
          mmLoaded = true;
          return Future<JSNumber>.value(1.toJS).toJS;
        }).toJS,
      );
      bridge.setProperty(
        'unloadMultimodalProjector'.toJS,
        (() {
          mmLoaded = false;
          return Future<void>.value().toJS;
        }).toJS,
      );
      bridge.setProperty('supportsVision'.toJS, (() => false).toJS);
      bridge.setProperty('supportsAudio'.toJS, (() => mmLoaded).toJS);

      bridge.setProperty(
        'tokenize'.toJS,
        ((String text, bool addSpecial) {
          final arr = JSUint32Array.withLength(3);
          arr.toDart[0] = 1;
          arr.toDart[1] = 2;
          arr.toDart[2] = 3;
          return Future<JSUint32Array>.value(arr).toJS;
        }).toJS,
      );

      bridge.setProperty(
        'detokenize'.toJS,
        ((JSArray tokens, bool special) {
          return Future<JSString>.value('decoded'.toJS).toJS;
        }).toJS,
      );

      bridge.setProperty(
        'stateSaveFile'.toJS,
        ((String path, JSArray tokens) {
          lastStateSavePath = path;
          lastStateSaveTokens = <int>[];
          for (int i = 0; i < tokens.length; i++) {
            final raw = tokens.getProperty(i.toJS);
            if (raw.isA<JSNumber>()) {
              lastStateSaveTokens!.add((raw as JSNumber).toDartInt);
            }
          }
          return Future<JSBoolean>.value(true.toJS).toJS;
        }).toJS,
      );

      bridge.setProperty(
        'stateLoadFile'.toJS,
        ((String path, int tokenCapacity) {
          lastStateLoadPath = path;
          lastStateLoadCapacity = tokenCapacity;
          final result = JSObject();
          result.setProperty(
            'tokens'.toJS,
            <JSNumber>[7.toJS, 8.toJS, 9.toJS].toJS,
          );
          return Future<JSObject>.value(result).toJS;
        }).toJS,
      );

      bridge.setProperty(
        'embed'.toJS,
        ((String text, JSObject? options) {
          var normalize = true;
          if (options != null) {
            final rawNormalize = options.getProperty('normalize'.toJS);
            if (rawNormalize.isA<JSBoolean>()) {
              normalize = (rawNormalize as JSBoolean).toDart;
            }
          }

          final vector = <double>[
            text.length.toDouble(),
            normalize ? 1.0 : 0.0,
          ];
          return Future<JSArray>.value(
            vector.map((value) => value.toJS).toList(growable: false).toJS,
          ).toJS;
        }).toJS,
      );

      bridge.setProperty(
        'embedBatch'.toJS,
        ((JSArray texts, JSObject? options) {
          var normalize = true;
          if (options != null) {
            final rawNormalize = options.getProperty('normalize'.toJS);
            if (rawNormalize.isA<JSBoolean>()) {
              normalize = (rawNormalize as JSBoolean).toDart;
            }
          }

          final vectors = JSArray();
          for (int i = 0; i < texts.length; i++) {
            final raw = texts.getProperty(i.toJS);
            final text = raw.isA<JSString>() ? (raw as JSString).toDart : '';
            final vector = JSArray();
            vector.setProperty(0.toJS, text.length.toDouble().toJS);
            vector.setProperty(1.toJS, (normalize ? 1.0 : 0.0).toJS);
            vectors.setProperty(i.toJS, vector);
          }
          return Future<JSArray>.value(vectors).toJS;
        }).toJS,
      );

      bridge.setProperty(
        'getModelMetadata'.toJS,
        (() {
          final meta = JSObject();
          meta.setProperty('general.architecture'.toJS, 'llama'.toJS);
          return meta;
        }).toJS,
      );

      bridge.setProperty('getContextSize'.toJS, (() => 1024).toJS);
      bridge.setProperty('isGpuActive'.toJS, (() => true).toJS);
      bridge.setProperty('getBackendName'.toJS, (() => 'WebGPU (Mock)').toJS);
      bridge.setProperty('cancel'.toJS, (() {}).toJS);
      bridge.setProperty(
        'dispose'.toJS,
        (() {
          return Future<void>.value().toJS;
        }).toJS,
      );
      bridge.setProperty(
        'applyChatTemplate'.toJS,
        ((JSArray messages, bool addAssistant, String? customTemplate) {
          return Future<JSString>.value('templated'.toJS).toJS;
        }).toJS,
      );

      backend = WebGpuLlamaBackend(
        bridgeFactory: ([config]) => bridge as LlamaWebGpuBridge,
      );
      engine = LlamaEngine(backend);
    });

    tearDown(() async {
      await engine.dispose();
    });

    test('LlamaEngine create forwards multimodal audio parts', () async {
      await engine.loadModelFromUrl(
        'https://example.com/model.gguf',
        modelParams: const ModelParams(contextSize: 1024),
      );
      await engine.loadMultimodalProjector('https://example.com/mmproj.gguf');

      expect(await engine.supportsAudio, isTrue);
      expect(await engine.supportsVision, isFalse);

      final chunks = await engine.create(<LlamaChatMessage>[
        LlamaChatMessage.withContent(
          role: LlamaChatRole.user,
          content: <LlamaContentPart>[
            const LlamaTextContent('Transcribe this audio.'),
            LlamaAudioContent(
              samples: Float32List.fromList(<double>[0.1, -0.2, 0.3]),
            ),
          ],
        ),
      ], params: const GenerationParams(maxTokens: 8)).toList();

      final output = chunks
          .map((chunk) => chunk.choices.first.delta.content ?? '')
          .join();

      expect(output, contains('Hello'));
      expect(sawAudioPart, isTrue);
    });

    test('LlamaEngine embed and embedBatch work via web bridge', () async {
      await engine.loadModelFromUrl(
        'https://example.com/model.gguf',
        modelParams: const ModelParams(contextSize: 1024),
      );

      final vector = await engine.embed('hello world');
      expect(vector, <double>[11.0, 1.0]);

      final rawVector = await engine.embed('hello world', normalize: false);
      expect(rawVector, <double>[11.0, 0.0]);

      final batch = await engine.embedBatch(const <String>['hello', 'dart']);
      expect(batch, <List<double>>[
        <double>[5.0, 1.0],
        <double>[4.0, 1.0],
      ]);
    });

    test('LlamaEngine state persistence forwards to web bridge', () async {
      await engine.loadModelFromUrl(
        'https://example.com/model.gguf',
        modelParams: const ModelParams(contextSize: 1024),
      );

      expect(engine.supportsStatePersistence, isTrue);

      final saved = await engine.stateSaveFile(
        '/prompt-state.bin',
        tokens: const <int>[1, 2, 3],
      );
      expect(saved, isTrue);
      expect(lastStateSavePath, '/prompt-state.bin');
      expect(lastStateSaveTokens, <int>[1, 2, 3]);

      final restored = await engine.stateLoadFile(
        '/prompt-state.bin',
        tokenCapacity: 1024,
      );
      expect(restored.tokens, <int>[7, 8, 9]);
      expect(lastStateLoadPath, '/prompt-state.bin');
      expect(lastStateLoadCapacity, 1024);
    });
  });
}
