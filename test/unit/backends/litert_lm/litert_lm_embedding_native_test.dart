@TestOn('vm')
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/backends/litert_lm/litert_lm_embedding.dart';
import 'package:llamadart/src/backends/litert_lm/litert_lm_backend.dart';
import 'package:llamadart/src/backends/litert_lm/litert_lm_service.dart';
import 'package:llamadart/src/backends/litert_lm/worker.dart';
import 'package:llamadart/src/backends/litert_lm/litert_lm_runtime.dart';
import 'package:test/test.dart';

import '../../../support/suite_system_temp.dart';
import 'litert_lm_embedding_test.dart' show embeddingBundleHeader;

void main() {
  final suite = useSuiteSystemTemp();
  late String library;
  late String model;
  late void Function(int) mode;
  late int Function() allocations;
  late int Function() processorBackends;
  setUpAll(() async {
    final source = File('${suite().path}/embedding.c');
    await source.writeAsString(_source);
    library = '${suite().path}/embedding${Platform.isMacOS ? '.dylib' : '.so'}';
    final result = await Process.run('cc', [
      Platform.isMacOS ? '-dynamiclib' : '-shared',
      '-fPIC',
      source.path,
      '-o',
      library,
    ]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    final lib = DynamicLibrary.open(library);
    mode = lib.lookupFunction<Void Function(Int), void Function(int)>(
      'set_mode',
    );
    allocations = lib.lookupFunction<Int Function(), int Function()>(
      'allocations',
    );
    processorBackends = lib.lookupFunction<Int Function(), int Function()>(
      'processor_backends',
    );
    model = '${suite().path}/model.litertlm';
    await File(model).writeAsBytes(embeddingBundleHeader());
  });
  setUp(() => mode(0));
  Future<LiteRtLmEmbeddingSession> create({
    String? modelPath,
    String? libraryPath,
    String backend = 'cpu',
  }) => LiteRtLmRuntimeClient(libraryPath: libraryPath ?? library)
      .createEmbeddingSession(
        modelPath: modelPath ?? model,
        backend: backend,
        cacheDir: suite().path,
        maxInputLength: 1024,
        numberOfThreads: 2,
      );
  List<LiteRtLmEmbeddingPart> input() => [
    LiteRtLmEmbeddingPart(0, Uint8List.fromList([97, 98])),
  ];
  test(
    'production backend worker and service route embedding mode and reject chat',
    () async {
      final port = ReceivePort();
      final service = LiteRtLmService(
        clientFactory: () => LiteRtLmRuntimeClient(libraryPath: library),
      );
      runLiteRtLmWorkerForTesting(port.sendPort, service, exitOnDispose: false);
      final backend = LiteRtLmBackend(
        initialSendPort: await port.first as SendPort,
      );
      addTearDown(() async {
        await backend.dispose();
        port.close();
      });
      const params = ModelParams(
        liteRtLmEmbeddingEngine: true,
        device: ComputeDevice.cpu,
        contextSize: 1024,
        numberOfThreads: 2,
      );
      expect((await backend.getEmbeddingCapabilities(-1)).text, isFalse);
      final handle = await backend.modelLoad(model, params);
      final context = await backend.contextCreate(handle, params);
      expect((await backend.getEmbeddingCapabilities(context)).audio, isTrue);
      expect(await backend.embedBatch(context, ['a', 'b'], normalize: false), [
        [3, 4],
        [3, 4],
      ]);
      expect(await backend.embedContentBatch(context, []), isEmpty);
      await expectLater(
        backend.generate(context, 'x', const GenerationParams()).toList(),
        throwsA(isA<LlamaUnsupportedException>()),
      );
      await expectLater(
        backend.tokenize(context, 'x'),
        throwsA(isA<LlamaUnsupportedException>()),
      );
      await expectLater(
        backend.embedContentBatch(context, [
          LlamaEmbeddingInput(const [LlamaTextContent('valid')]),
          LlamaEmbeddingInput(const [
            LlamaImageContent(url: 'https://private.invalid'),
          ]),
        ]),
        throwsA(isA<LlamaUnsupportedException>()),
      );
      mode(7);
      await expectLater(
        backend.embedBatch(context, ['valid', 'overflow']),
        throwsA(isA<LlamaInferenceException>()),
      );
      mode(0);
      await backend.contextFree(context);
      expect((await backend.getEmbeddingCapabilities(context)).text, isFalse);
      await backend.modelFree(handle);
      expect(backend.supportsEmbeddings, isFalse);
      expect(allocations(), 0);
    },
  );
  test('context cannot change the engine selected at model load', () async {
    final service = LiteRtLmService();
    addTearDown(service.dispose);
    for (final embedding in [true, false]) {
      final handle = await service.loadModel(
        model,
        ModelParams(
          liteRtLmEmbeddingEngine: embedding,
          device: ComputeDevice.cpu,
        ),
      );
      expect(
        () => service.createContext(
          handle,
          ModelParams(
            liteRtLmEmbeddingEngine: !embedding,
            device: ComputeDevice.cpu,
          ),
        ),
        throwsA(isA<LlamaUnsupportedException>()),
      );
      service.freeModel(handle);
    }
  });
  for (final (kind, partType) in [
    ('tf_lite_vision_adapter', 1),
    ('tf_lite_audio_adapter', 3),
  ]) {
    test(
      'missing $kind fails whole-batch preflight before computation',
      () async {
        final bytes = Uint8List.fromList(embeddingBundleHeader());
        final needle = kind.codeUnits;
        for (var i = 0; i <= bytes.length - needle.length; i++) {
          if (List.generate(
            needle.length,
            (j) => bytes[i + j] == needle[j],
          ).every((v) => v)) {
            bytes[i] = 88;
          }
        }
        final bundle = File('${suite().path}/missing-$partType.litertlm');
        await bundle.writeAsBytes(bytes);
        final service = LiteRtLmService(
          clientFactory: () => LiteRtLmRuntimeClient(libraryPath: library),
        );
        addTearDown(service.dispose);
        const params = ModelParams(
          liteRtLmEmbeddingEngine: true,
          device: ComputeDevice.cpu,
          numberOfThreads: 2,
        );
        final handle = await service.loadModel(bundle.path, params);
        final context = service.createContext(handle, params);
        final caps = await service.embeddingCapabilities(context);
        expect(partType == 1 ? caps.image : caps.audio, isFalse);
        await expectLater(
          service.embed(context, [
            input(),
            [LiteRtLmEmbeddingPart(partType, Uint8List(1))],
          ], normalize: true),
          throwsA(isA<LlamaUnsupportedException>()),
        );
        service.freeModel(handle);
        expect(allocations(), 0);
      },
    );
  }
  test(
    'native GPU load rejects the unsafe ABI before context or runtime work',
    () async {
      final service = LiteRtLmService();
      addTearDown(service.dispose);
      await expectLater(
        service.loadModel(
          model,
          const ModelParams(
            liteRtLmEmbeddingEngine: true,
            device: ComputeDevice.gpu,
          ),
        ),
        throwsA(
          isA<LlamaUnsupportedException>().having(
            (e) => e.message,
            'ABI diagnostic',
            allOf(contains('v0.18.0-2'), contains('dd3db31236')),
          ),
        ),
      );
    },
  );
  test('rejects native GPU and NPU before native allocation', () async {
    for (final backend in ['gpu', 'npu']) {
      await expectLater(
        create(backend: backend),
        throwsA(
          isA<LlamaUnsupportedException>().having(
            (e) => e.message,
            'condition',
            backend == 'gpu' ? contains('dd3db31236') : contains('CPU'),
          ),
        ),
      );
      expect(allocations(), 0);
    }
  });
  test(
    'single and batch copy pooled width, normalize and overflow-error options',
    () async {
      final session = await create();
      expect(processorBackends(), 3);
      expect(
        [
          session.capabilities.text,
          session.capabilities.image,
          session.capabilities.audio,
        ],
        [true, true, true],
      );
      expect(await session.compute([input()], normalize: true), [
        [closeTo(0.6, 1e-6), closeTo(0.8, 1e-6)],
      ]);
      expect(await session.compute([input(), input()], normalize: false), [
        [3, 4],
        [3, 4],
      ]);
      expect(await session.compute([], normalize: true), isEmpty);
      session.dispose();
      session.dispose();
      expect(allocations(), 0);
      expect(
        () => session.compute([input()], normalize: true),
        throwsA(isA<LlamaStateException>()),
      );
    },
  );
  for (final fault in [1, 2, 3, 4, 5, 6, 7, 8]) {
    test(
      'native fault $fault releases every allocated input option and response',
      () async {
        final session = await create();
        mode(fault);
        await expectLater(
          session.compute(
            fault == 7 || fault == 8 ? [input(), input()] : [input()],
            normalize: true,
          ),
          throwsA(isA<LlamaInferenceException>()),
        );
        mode(0);
        expect(await session.compute([input()], normalize: false), [
          [3, 4],
        ]);
        session.dispose();
        expect(allocations(), 0);
      },
    );
  }
  test('settings and engine failures clean up', () async {
    for (final fault in [9, 10]) {
      mode(fault);
      await expectLater(create(), throwsA(isA<LlamaException>()));
      expect(allocations(), 0);
    }
  });
  test(
    'truncated and excessive native headers reject before C allocation',
    () async {
      for (final bytes in [
        Uint8List(1),
        Uint8List(32),
        Uint8List.fromList(embeddingBundleHeader())..[27] = 127,
      ]) {
        final bad = File('${suite().path}/bounds.litertlm');
        await bad.writeAsBytes(bytes);
        await expectLater(
          create(modelPath: bad.path),
          throwsA(isA<LlamaUnsupportedException>()),
        );
        expect(allocations(), 0);
      }
    },
  );
  test(
    'unknown bundle and old runtime fail before allocating an engine',
    () async {
      final bad = File('${suite().path}/bad.litertlm');
      await bad.writeAsBytes(Uint8List(32));
      await expectLater(
        create(modelPath: bad.path),
        throwsA(isA<LlamaUnsupportedException>()),
      );
      final source = File('${suite().path}/old.c');
      await source.writeAsString(
        _source.replaceAll(
          'litert_lm_embedding_engine_compute_embedding_batch',
          'old_compute_batch',
        ),
      );
      final old = '${suite().path}/old${Platform.isMacOS ? '.dylib' : '.so'}';
      final result = await Process.run('cc', [
        Platform.isMacOS ? '-dynamiclib' : '-shared',
        '-fPIC',
        source.path,
        '-o',
        old,
      ]);
      expect(result.exitCode, 0);
      await expectLater(
        create(libraryPath: old),
        throwsA(isA<LlamaUnsupportedException>()),
      );
      expect(allocations(), 0);
    },
  );
}

const _source = r'''
#include <stdlib.h>
void* litert_lm_engine_settings_create(void){return NULL;}
#include <stddef.h>
#include <stdbool.h>
#include <math.h>
#include <string.h>
static int mode=0, live=0, processors=0;
int processor_backends(void){return processors;}
void set_mode(int n){mode=n;}
int allocations(void){return live;}
static void* alloc(void){live++;return calloc(1,16);}
static void del(void*p){if(p){live--;free(p);}}
void* litert_lm_embedding_engine_settings_create(const char*m,const char*b,const char*v,const char*a){processors=(v&&strcmp(v,"cpu")==0?1:0)|(a&&strcmp(a,"cpu")==0?2:0);return mode==9||strcmp(b,"cpu")!=0?NULL:alloc();}
void litert_lm_embedding_engine_settings_delete(void*p){del(p);}
void litert_lm_embedding_engine_settings_set_cache_dir(void*p,const char*s){}
void litert_lm_embedding_engine_settings_set_max_input_length(void*p,int n){}
void litert_lm_embedding_engine_settings_set_num_threads(void*p,int n){((int*)p)[0]=n;}
void* litert_lm_embedding_engine_create(void*p){return mode==10||((int*)p)[0]!=2?NULL:alloc();}
void litert_lm_embedding_engine_delete(void*p){del(p);}
void* litert_lm_embedding_options_create(void){return mode==1?NULL:alloc();}
void litert_lm_embedding_options_delete(void*p){del(p);}
void litert_lm_embedding_options_set_normalize(void*p,bool n){((int*)p)[0]=n;}
void litert_lm_embedding_options_set_input_overflow_strategy(void*p,int n){((int*)p)[1]=n;}
void* litert_lm_input_data_create(int t,const void*d,size_t n){return mode==2?NULL:alloc();}
void litert_lm_input_data_delete(void*p){del(p);}
static float raw[2]={3,4}, normalized[2]={0.6f,0.8f}, invalid[2]={NAN,1};
void* litert_lm_embedding_engine_compute_embedding(void*e,const void*const*i,size_t n,const void*o){if(mode==3||((int*)o)[1]!=2)return NULL;void*r=alloc();((int*)r)[0]=((int*)o)[0];return r;}
void litert_lm_embedding_response_delete(void*p){del(p);}
size_t litert_lm_embedding_response_get_size(const void*p){return mode==4?0:2;}
const float* litert_lm_embedding_response_get_values(const void*p){if(mode==5)return NULL;if(mode==6)return invalid;return ((int*)p)[0]?normalized:raw;}
void* litert_lm_embedding_engine_compute_embedding_batch(void*e,const void*const*const*i,const size_t*n,size_t b,const void*o){return mode==7?NULL:litert_lm_embedding_engine_compute_embedding(e,NULL,0,o);}
size_t litert_lm_embedding_responses_get_size(const void*p){return mode==8?1:2;}
const void* litert_lm_embedding_responses_get_at(const void*p,size_t i){return p;}
void litert_lm_embedding_responses_delete(void*p){del(p);}
''';
