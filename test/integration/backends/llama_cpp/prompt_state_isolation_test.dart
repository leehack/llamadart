@TestOn('vm')
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:math';
import 'dart:mirrors';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:llamadart/src/backends/llama_cpp/bindings.dart';
import 'package:llamadart/src/backends/llama_cpp/llama_cpp_service.dart';
import 'package:llamadart/src/core/models/chat/content_part.dart';
import 'package:llamadart/src/core/models/inference/generation_params.dart';
import 'package:llamadart/src/core/models/inference/model_params.dart';
import 'package:test/test.dart';

import '../../../test_helper.dart';

const _p1 = 'Once upon a time there was a little girl named Lily.';
const _p2 =
    'Once upon a time there was a little dog named Max who liked to run fast '
    'and chase red balls in the big green park.';
const _p3 = '$_p1 She';

final _decodeFailure = isA<Exception>().having(
  (error) => '$error',
  'message',
  contains('Initial decode failed'),
);

const _greedy = GenerationParams(
  maxTokens: 24,
  temp: 0,
  topK: 1,
  penalty: 1,
  seed: 1,
);

void main() {
  late String modelPath;

  setUpAll(() async {
    modelPath = (await TestHelper.getTestModel()).path;
  });

  // https://github.com/leehack/llamadart/issues/601
  group('a failed prompt decode', () {
    late _Session session;
    late String fresh;

    setUp(() async {
      final reference = _Session.open(modelPath);
      try {
        fresh = await reference.generate(_p3, _greedy);
      } finally {
        reference.dispose();
      }
      session = _Session.open(modelPath);
      addTearDown(session.dispose);
    });

    test('on the suffix path does not leave the prefix cache stale', () async {
      await session.generate(_p1, _greedy);
      await expectLater(
        session.withAbortedDecodes(() => session.generate(_p2, _greedy)),
        throwsA(_decodeFailure),
      );
      expect(await session.generate(_p3, _greedy), fresh);
    });

    test(
      'on the full-prompt path does not leave the prefix cache stale',
      () async {
        await session.generate(_p1, _greedy);
        await expectLater(
          session.withAbortedDecodes(() => session.generate(_p1, _greedy)),
          throwsA(_decodeFailure),
        );
        expect(await session.generate(_p3, _greedy), fresh);
      },
    );
  });

  // https://github.com/leehack/llamadart/issues/603
  test(
    'a media prompt does not seed the repeat penalty from stale memory',
    () async {
      final session = _Session.open(modelPath, contextSize: 4096);
      final fakeMtmd = _FakeMtmd(session, session.tokenize(_p1));
      try {
        const params = GenerationParams(maxTokens: 16, temp: 0, penalty: 2);
        final clean = await session.generate(
          '<__media__>',
          params,
          parts: fakeMtmd.parts,
        );
        // The next generate() can get this request's freed prompt buffer, which
        // holds the media reply's own ids. On macOS a 1 KB buffer (context 256)
        // came back zeroed; this 16 KB one keeps the ids from index 4.
        await session.generate(clean, params.copyWith(maxTokens: 1));

        expect(
          await session.generate('<__media__>', params, parts: fakeMtmd.parts),
          clean,
        );
        expect(fakeMtmd.evaluations, 2);
      } finally {
        fakeMtmd.dispose();
        session.dispose();
      }
    },
  );
}

final class _Session {
  _Session._(this.service, this.modelHandle, this.contextHandle);

  factory _Session.open(String modelPath, {int contextSize = 256}) {
    final params = ModelParams(
      contextSize: contextSize,
      batchSize: 8,
      microBatchSize: 8,
      gpuLayers: 0,
    );
    final service = LlamaCppService();
    final modelHandle = service.loadModel(modelPath, params);
    return _Session._(
      service,
      modelHandle,
      service.createContext(modelHandle, params),
    );
  }

  final LlamaCppService service;
  final int modelHandle;
  final int contextHandle;

  Pointer<llama_context> get context =>
      (_private(service, '_contexts') as Map)[contextHandle].pointer
          as Pointer<llama_context>;

  List<int> tokenize(String text, {bool addSpecial = true}) =>
      service.tokenize(modelHandle, text, addSpecial);

  Future<String> generate(
    String prompt,
    GenerationParams params, {
    List<LlamaContentPart>? parts,
  }) async {
    final cancel = calloc<Int8>();
    try {
      final bytes = <int>[];
      await for (final chunk in service.generate(
        contextHandle,
        prompt,
        params,
        cancel.address,
        parts: parts,
      )) {
        bytes.addAll(chunk);
      }
      return utf8.decode(bytes, allowMalformed: true);
    } finally {
      calloc.free(cancel);
    }
  }

  /// Runs [action] while every CPU graph compute on the context aborts, so the
  /// first prompt `llama_decode` fails after generate() changed the KV.
  Future<void> withAbortedDecodes(Future<void> Function() action) async {
    // strlen("x") returns 1, which the ggml abort check reads as true.
    final strlen = DynamicLibrary.process()
        .lookup<NativeFunction<Bool Function(Pointer<Void>)>>('strlen');
    final data = 'x'.toNativeUtf8();
    llama_set_abort_callback(context, strlen, data.cast());
    try {
      await action();
    } finally {
      llama_set_abort_callback(context, nullptr, nullptr);
      malloc.free(data);
    }
  }

  void dispose() => service.dispose();
}

/// Stands in for libmtmd through the service's fallback API: one media part
/// whose evaluation decodes [tokens] as text.
final class _FakeMtmd {
  _FakeMtmd(this.session, this.tokens) {
    final service = session.service;
    final owner = reflectClass(LlamaCppService).owner as LibraryMirror;
    final apiClass =
        owner.declarations[MirrorSystem.getSymbol('_MtmdApi', owner)]
            as ClassMirror;
    Never unused([Object? _, Object? _, Object? _, Object? _, Object? _]) =>
        throw StateError('unexpected mtmd call');
    final api = apiClass.newInstance(Symbol.empty, const [], {
      #defaultMarker: () => _marker.cast<Char>(),
      #contextParamsDefault: unused,
      #initFromFile: unused,
      #free: (Pointer<mtmd_context> _) {},
      #inputChunksInit: () => Pointer<mtmd_input_chunks>.fromAddress(0x10),
      #inputChunksFree: (Pointer<mtmd_input_chunks> _) {},
      #helperInitOptDefault: unused,
      #helperBitmapInitFromFile: unused,
      #helperBitmapInitFromBuf: unused,
      #bitmapInitFromAudio: (int _, Pointer<Float> _) =>
          Pointer<mtmd_bitmap>.fromAddress(0x20),
      #supportsVision: (Pointer<mtmd_context> _) => false,
      #supportsAudio: (Pointer<mtmd_context> _) => true,
      #supportsVideo: (Pointer<mtmd_context> _) => false,
      #bitmapFree: (Pointer<mtmd_bitmap> _) {},
      #tokenize:
          (
            Pointer<mtmd_context> _,
            Pointer<mtmd_input_chunks> _,
            Pointer<mtmd_input_text> _,
            Pointer<Pointer<mtmd_bitmap>> _,
            int _,
          ) => 0,
      #helperEvalChunks: _evalChunks,
      #chunkEval: null,
      #logSet: null,
      #helperLogSet: null,
    }).reflectee;
    _setPrivate(service, '_mtmdPrimarySymbolsUnavailable', true);
    _setPrivate(service, '_mtmdFallbackLookupAttempted', true);
    _setPrivate(service, '_mtmdFallbackApi', api);
    (_private(service, '_mtmdContexts') as Map)[_mtmdHandle] =
        Pointer<mtmd_context>.fromAddress(0x30);
    (_private(service, '_modelToMtmd') as Map)[session.modelHandle] =
        _mtmdHandle;
  }

  static const _mtmdHandle = -603;

  final _Session session;
  final List<int> tokens;
  final Pointer<Utf8> _marker = '<__media__>'.toNativeUtf8();
  int evaluations = 0;

  List<LlamaContentPart> get parts => [
    LlamaAudioContent(samples: Float32List(1)),
  ];

  int _evalChunks(
    Pointer<mtmd_context> _,
    Pointer<llama_context> context,
    Pointer<mtmd_input_chunks> _,
    int nPast,
    int _,
    int nBatch,
    bool _,
    Pointer<llama_pos> newNPast,
  ) {
    evaluations++;
    final ids = malloc<llama_token>(tokens.length);
    try {
      ids.asTypedList(tokens.length).setAll(0, tokens);
      for (var start = 0; start < tokens.length; start += nBatch) {
        final count = min(nBatch, tokens.length - start);
        final result = llama_decode(
          context,
          llama_batch_get_one(ids + start, count),
        );
        if (result != 0) return result;
      }
      newNPast.value = nPast + tokens.length;
      return 0;
    } finally {
      malloc.free(ids);
    }
  }

  void dispose() {
    (_private(session.service, '_mtmdContexts') as Map).remove(_mtmdHandle);
    (_private(session.service, '_modelToMtmd') as Map).remove(
      session.modelHandle,
    );
    malloc.free(_marker);
  }
}

Object? _private(LlamaCppService service, String field) {
  final owner = reflectClass(LlamaCppService).owner as LibraryMirror;
  return reflect(
    service,
  ).getField(MirrorSystem.getSymbol(field, owner)).reflectee;
}

void _setPrivate(LlamaCppService service, String field, Object? value) {
  final owner = reflectClass(LlamaCppService).owner as LibraryMirror;
  reflect(service).setField(MirrorSystem.getSymbol(field, owner), value);
}
