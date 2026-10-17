@TestOn('vm')
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:mirrors';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:llamadart/backend.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/backends/llama_cpp/bindings.dart';
import 'package:llamadart/src/backends/llama_cpp/exit_teardown_api.dart';
import 'package:llamadart/src/backends/llama_cpp/llama_cpp_backend.dart';
import 'package:llamadart/src/backends/llama_cpp/llama_cpp_service.dart';
import 'package:llamadart/src/backends/llama_cpp/worker_messages.dart';
import 'package:test/test.dart';

import '../../../support/fake_native_barrier.dart';
import '../../../support/recording_exit_teardown.dart';
import '../../../support/synthetic_embedding_gguf.dart';

void main() {
  test(
    'unstarted and unknown contexts have no capabilities or worker startup',
    () async {
      final backend = NativeLlamaBackend();
      addTearDown(backend.dispose);
      final caps = await backend.getEmbeddingCapabilities(99);
      expect([caps.text, caps.image, caps.audio], [false, false, false]);
      expect(await backend.embedContentBatch(99, []), isEmpty);
      expect(backend.isReady, isFalse);
      final service = LlamaCppService();
      final unloaded = service.getEmbeddingCapabilities(99);
      expect(
        [unloaded.text, unloaded.image, unloaded.audio],
        [false, false, false],
      );
    },
  );

  test(
    'worker snapshot merges text verbatim and copies every media source',
    () {
      final port = ReceivePort();
      addTearDown(port.close);
      final bytes = Uint8List.fromList([1, 2, 3]);
      final pcm = Float32List.fromList([0, 0.25]);
      final request = EmbedContentBatchRequest(
        7,
        [
          LlamaEmbeddingInput([
            const LlamaTextContent('a '),
            const LlamaTextContent(''),
            const LlamaTextContent('\nbé'),
            LlamaImageContent(bytes: bytes, width: 1, height: 1),
            const LlamaTextContent('c'),
            const LlamaTextContent('d'),
            LlamaAudioContent(samples: pcm),
            LlamaAudioContent(bytes: bytes),
            const LlamaImageContent(path: 'image'),
            const LlamaAudioContent(path: 'audio'),
            const LlamaImageContent(url: 'https://invalid.example'),
          ]),
        ],
        false,
        123,
        port.sendPort,
      );
      bytes[0] = 9;
      pcm[0] = 1;
      final parts = request.inputs.single.parts;
      expect(parts, hasLength(8));
      expect((parts[0] as LlamaTextContent).text, 'a \nbé');
      expect((parts[1] as LlamaImageContent).bytes, [1, 2, 3]);
      expect((parts[1] as LlamaImageContent).width, 1);
      expect((parts[2] as LlamaTextContent).text, 'cd');
      expect((parts[3] as LlamaAudioContent).samples, [0, 0.25]);
      expect((parts[4] as LlamaAudioContent).bytes, [1, 2, 3]);
      expect((parts[5] as LlamaImageContent).path, 'image');
      expect((parts[6] as LlamaAudioContent).path, 'audio');
      expect((parts[7] as LlamaImageContent).url, 'https://invalid.example');
    },
  );

  test(
    'content RPC copies media, preserves normalization, cancels and keeps typed errors',
    () async {
      final port = ReceivePort();
      late NativeLlamaBackend backend;
      var mode = 'ok';
      final subscription = port.listen((message) {
        if (message is EmbeddingCapabilitiesRequest) {
          message.sendPort.send(
            mode == 'error'
                ? ErrorResponse(
                    'unsupported',
                    kind: WorkerErrorKind.unsupported,
                  )
                : mode == 'unknown'
                ? 'invalid'
                : EmbeddingCapabilitiesResponse(
                    const LlamaEmbeddingCapabilities(text: true),
                  ),
          );
        } else if (message is EmbedContentBatchRequest) {
          expect(message.normalize, isFalse);
          expect(
            (message.inputs.single.parts.single as LlamaImageContent).bytes,
            [1, 2],
          );
          expect(
            Pointer<Int8>.fromAddress(message.cancelTokenAddress).value,
            mode == 'cancel' ? 1 : 0,
          );
          message.sendPort.send(
            mode == 'error'
                ? ErrorResponse('failed', kind: WorkerErrorKind.inference)
                : mode == 'unknown'
                ? 'invalid'
                : EmbedBatchResponse([
                    [1, 2],
                  ]),
          );
        } else if (message is WorkerRequest) {
          message.sendPort.send(null);
        }
      });
      backend = NativeLlamaBackend(initialSendPort: port.sendPort);
      addTearDown(() async {
        await backend.dispose();
        await subscription.cancel();
        port.close();
      });
      expect((await backend.getEmbeddingCapabilities(7)).text, isTrue);
      for (final next in ['ok', 'cancel', 'error', 'unknown']) {
        mode = next;
        final bytes = Uint8List.fromList([1, 2]);
        final future = backend.embedContentBatch(7, [
          LlamaEmbeddingInput([LlamaImageContent(bytes: bytes)]),
        ], normalize: false);
        bytes[0] = 9;
        if (mode == 'cancel') backend.cancelGeneration();
        if (mode == 'error' || mode == 'unknown') {
          await expectLater(future, throwsA(isA<LlamaInferenceException>()));
        } else {
          expect(await future, [
            [1, 2],
          ]);
        }
      }
      mode = 'error';
      await expectLater(
        backend.getEmbeddingCapabilities(7),
        throwsA(isA<LlamaUnsupportedException>()),
      );
      mode = 'unknown';
      await expectLater(
        backend.getEmbeddingCapabilities(7),
        throwsA(isA<LlamaInferenceException>()),
      );
    },
  );

  test('prepared media cleanup frees chunks before bitmaps exactly once', () {
    final library = reflectClass(LlamaCppService).owner as LibraryMirror;
    final type =
        library.declarations[MirrorSystem.getSymbol(
              '_PreparedEmbedding',
              library,
            )]
            as ClassMirror;
    final freed = <int>[];
    final object = type.newInstance(Symbol.empty, [], {
      #freeChunks: (Pointer<mtmd_input_chunks> p) => freed.add(p.address),
      #freeBitmap: (Pointer<mtmd_bitmap> p) => freed.add(p.address),
    });
    object.setField(
      MirrorSystem.getSymbol('chunks', library),
      Pointer<mtmd_input_chunks>.fromAddress(1),
    );
    (object.getField(MirrorSystem.getSymbol('bitmaps', library)).reflectee
            as List<Pointer<mtmd_bitmap>>)
        .addAll([Pointer.fromAddress(2), Pointer.fromAddress(3)]);
    object.invoke(#dispose, []);
    object.invoke(#dispose, []);
    expect(freed, [1, 2, 3]);
  });

  test('mixed ABI is optional and rejects each missing required symbol', () {
    final names = <String>[];
    final api = LlamaCppMixedBatchApi.tryResolve(
      symbol: (name) {
        names.add(name);
        return Pointer<NativeType>.fromAddress(1);
      },
    );
    expect(api, isNotNull);
    expect(
      names,
      containsAll([
        'llama_dart_process',
        'llama_dart_batch_ext_init',
        'llama_batch_ext_add_embd',
        'mtmd_decode_use_mrope',
      ]),
    );
    for (final missing in names) {
      expect(
        LlamaCppMixedBatchApi.tryResolve(
          symbol: (name) {
            if (name == missing) throw ArgumentError('missing');
            return Pointer<NativeType>.fromAddress(1);
          },
        ),
        isNull,
        reason: missing,
      );
    }
    expect(LlamaCppMixedBatchApi.tryResolve(), isNotNull);
  });

  test(
    'native text-only model preserves raw and normalized adjacent-text parity',
    () {
      final dir = Directory.systemTemp.createTempSync(
        'native_content_embedding_',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      final modelFile = writeSyntheticLlamaGguf(
        '${dir.path}/model.gguf',
        poolingType: 1,
        causalAttention: false,
      );
      final service = LlamaCppService()..initializeBackend();
      addTearDown(service.dispose);
      const params = ModelParams(
        gpuLayers: 0,
        preferredBackend: GpuBackend.cpu,
        contextSize: 64,
        batchSize: 64,
        microBatchSize: 32,
      );
      final model = service.loadModel(modelFile.path, params);
      final context = service.createContext(model, params);
      expect(service.embedContentBatch(-1, []), isEmpty);
      final caps = service.getEmbeddingCapabilities(context);
      expect([caps.text, caps.image, caps.audio], [true, false, false]);
      for (final normalize in [true, false]) {
        final expected = service.embed(context, 'a \nbé', normalize: normalize);
        final actual = service.embedContentBatch(context, [
          LlamaEmbeddingInput([
            const LlamaTextContent('a '),
            const LlamaTextContent(''),
            const LlamaTextContent('\nbé'),
          ]),
        ], normalize: normalize);
        expect(actual.single, orderedEquals(expected));
      }
      expect(
        () => service.embedContentBatch(context, [
          LlamaEmbeddingInput([LlamaAudioContent(samples: Float32List(4))]),
        ]),
        throwsA(isA<LlamaUnsupportedException>()),
      );
      expect(
        () => service.embedContentBatch(context, [
          LlamaEmbeddingInput([LlamaTextContent('a ' * 100)]),
        ]),
        throwsA(isA<LlamaInferenceException>()),
      );
      final cancel = calloc<Int8>()..value = 1;
      addTearDown(() => calloc.free(cancel));
      expect(
        () => service.embedContentBatch(context, [
          LlamaEmbeddingInput([const LlamaTextContent('a')]),
        ], cancelToken: cancel),
        throwsA(isA<LlamaInferenceException>()),
      );
      cancel.value = 0;
      expect(
        service.embedContentBatch(context, [
          LlamaEmbeddingInput([const LlamaTextContent('a')]),
        ], cancelToken: cancel).single,
        service.embed(context, 'a'),
      );
    },
  );

  test(
    'rank classifiers and unpooled causal decoders do not claim text embedding support',
    () {
      final dir = Directory.systemTemp.createTempSync(
        'native_embedding_probe_',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      final service = LlamaCppService()..initializeBackend();
      addTearDown(service.dispose);
      const params = ModelParams(
        gpuLayers: 0,
        preferredBackend: GpuBackend.cpu,
        contextSize: 64,
        batchSize: 64,
        microBatchSize: 64,
      );
      for (final pooling in [0, 4]) {
        final path = writeSyntheticLlamaGguf(
          '${dir.path}/model$pooling.gguf',
          poolingType: pooling,
          causalAttention: true,
        ).path;
        final model = service.loadModel(path, params);
        final context = service.createContext(model, params);
        final caps = service.getEmbeddingCapabilities(context);
        expect([caps.text, caps.image, caps.audio], [false, false, false]);
        service.freeContext(context);
        service.freeModel(model);
      }
    },
  );

  test(
    'mixed wrapper dispatch pins DECODE, failures, exception poisoning and allocation',
    () {
      final recorder = RecordingExitTeardown(
        ExitTeardownApi.tryResolve(isWindows: false)!,
      );
      final barrier = FakeNativeBarrier();
      addTearDown(barrier.dispose);
      final context = Pointer<llama_context>.fromAddress(100);
      final batch = Pointer<llama_batch_ext>.fromAddress(200);
      final projector = Pointer<mtmd_context>.fromAddress(300);
      var result = 0;
      var allocationFails = false;
      final seen = <Object>[];
      final outputModes = <bool>[];
      final calls = LlamaCppObjectCalls.tracked(
        recorder.api,
        barrier: barrier.api,
        mixedBatchResolver: () => LlamaCppMixedBatchApi(
          init: (ctx) {
            expect(ctx, context);
            return allocationFails ? nullptr : batch;
          },
          setOutput: (_, enabled) => outputModes.add(enabled),
          process: (ctx, type, b) {
            seen.addAll([ctx, type, b]);
            return result;
          },
        ),
      );
      expect(calls.createEmbeddingBatch(context), batch);
      calls.processEmbeddingBatch(context, batch);
      expect(seen, [context, 1, batch]);
      for (final status in [-1, -4]) {
        result = status;
        expect(
          () => calls.processEmbeddingBatch(context, batch),
          throwsA(isA<LlamaUnsupportedException>()),
        );
      }
      result = 2;
      expect(
        () => calls.processEmbeddingBatch(context, batch),
        throwsA(isA<LlamaInferenceException>()),
      );
      allocationFails = true;
      expect(
        () => calls.createEmbeddingBatch(context),
        throwsA(isA<LlamaInferenceException>()),
      );
      barrier.catchException();
      expect(
        () => calls.createEmbeddingBatch(context),
        throwsA(isA<LlamaInferenceException>()),
      );
      expect(
        () => calls.failures.ensureUsable(context, 'context'),
        throwsA(isA<LlamaStateException>()),
      );
      calls.failures.forget(context);
      barrier.clear();
      result = -2147483648;
      barrier.catchException();
      expect(
        () => calls.processEmbeddingBatch(context, batch),
        throwsA(isA<LlamaInferenceException>()),
      );
      expect(
        () => calls.failures.ensureUsable(context, 'context'),
        throwsA(isA<LlamaStateException>()),
      );
      calls.setEmbeddingOutput(context, false);
      expect(
        outputModes,
        isEmpty,
        reason: 'free-only contexts cannot be touched during error cleanup',
      );
      expect(
        () => calls.setEmbeddingOutput(context, true),
        throwsA(isA<LlamaStateException>()),
      );
      calls.failures.forget(context);
      calls.setEmbeddingOutput(context, true);
      calls.setEmbeddingOutput(context, false);
      expect(outputModes, [true, false]);
      barrier.clear();
      calls.encodeEmbeddingChunk(projector, nullptr);
      expect(recorder.calls, contains('llama_dart_mtmd_encode_chunk'));
      final failedEncode = LlamaCppObjectCalls.tracked(
        _withFailedEncoder(recorder.api),
        barrier: barrier.api,
      );
      expect(
        () => failedEncode.encodeEmbeddingChunk(projector, nullptr),
        throwsA(isA<LlamaInferenceException>()),
      );
      expect(
        () => LlamaCppObjectCalls.upstream.encodeEmbeddingChunk(
          projector,
          nullptr,
        ),
        throwsA(isA<LlamaUnsupportedException>()),
      );
      expect(LlamaCppObjectCalls.upstream.mixedBatch, isNull);
    },
  );

  test('native backend implements both embedding contracts', () {
    final backend = NativeLlamaBackend();
    expect(backend, isA<BackendEmbeddings>());
    expect(backend, isA<BackendMultimodalEmbeddings>());
  });
}

ExitTeardownApi _withFailedEncoder(ExitTeardownApi real) => ExitTeardownApi(
  track: real.track,
  untrack: real.untrack,
  free: real.free,
  freeAddress: real.freeAddress,
  modelLoadFromFile: real.modelLoadFromFile,
  initFromModel: real.initFromModel,
  mtmdInitFromFile: real.mtmdInitFromFile,
  decode: real.decode,
  encode: real.encode,
  synchronize: real.synchronize,
  samplerSample: real.samplerSample,
  stateSaveFile: real.stateSaveFile,
  stateLoadFile: real.stateLoadFile,
  stateSeqGetSizeExt: real.stateSeqGetSizeExt,
  stateSeqGetDataExt: real.stateSeqGetDataExt,
  stateSeqSetDataExt: real.stateSeqSetDataExt,
  adapterLoraInit: real.adapterLoraInit,
  mtmdTokenize: real.mtmdTokenize,
  mtmdHelperEvalChunks: real.mtmdHelperEvalChunks,
  mtmdHelperEvalChunkSingle: real.mtmdHelperEvalChunkSingle,
  mtmdHelperDecodeImageChunk: real.mtmdHelperDecodeImageChunk,
  schedGraphCompute: real.schedGraphCompute,
  mtmdEncodeChunk: (_, _) => 1,
);
