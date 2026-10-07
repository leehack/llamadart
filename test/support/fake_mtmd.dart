import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:mirrors';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:llamadart/src/backends/llama_cpp/bindings.dart';
import 'package:llamadart/src/backends/llama_cpp/exit_teardown_api.dart';
import 'package:llamadart/src/backends/llama_cpp/llama_cpp_service.dart';
import 'package:llamadart/src/backends/llama_cpp/mtmd_chunk_eval.dart';
import 'package:llamadart/src/core/models/chat/content_part.dart';

/// Stands in for libmtmd through [service]'s fallback API: a projector whose
/// one media part evaluates [tokens] as text.
///
/// It records the upstream mtmd function behind each call that creates,
/// tokenizes with, evaluates with or frees the projector. A service on the
/// tracked calls makes those through its `ExitTeardownApi` instead, so they
/// do not reach this fake.
final class FakeMtmd {
  /// Puts [service] on a fallback API backed by this fake. With [chunkEval]
  /// the fallback has the chunk-level functions and presents the prompt as
  /// one text chunk; without it the service evaluates all chunks in one call.
  FakeMtmd.install(
    this.service, {
    required this.tokens,
    this.chunkEval = false,
    this.decode = llama_decode,
    this.audioBitmap = _audioBitmap,
  }) {
    final owner = reflectClass(LlamaCppService).owner as LibraryMirror;
    final apiClass =
        owner.declarations[MirrorSystem.getSymbol('_MtmdApi', owner)]
            as ClassMirror;
    Never unused([Object? _, Object? _, Object? _, Object? _, Object? _]) =>
        throw StateError('unexpected mtmd call');
    final api = apiClass.newInstance(Symbol.empty, const [], {
      #defaultMarker: () => _marker.cast<Char>(),
      #contextParamsDefault: () => Struct.create<mtmd_context_params>(),
      #initFromFile:
          (Pointer<Char> _, Pointer<llama_model> _, mtmd_context_params _) {
            calls.add('mtmd_init_from_file');
            return projector;
          },
      #free: (Pointer<mtmd_context> _) {
        calls.add('mtmd_free');
      },
      // llama_dart_exit_free ignores a pointer that is not tracked, so a
      // projector still held when its isolate ends is left alone.
      #freeAddress: ExitTeardownApi.tryResolve(
        isWindows: Platform.isWindows,
      )!.freeAddress,
      #inputChunksInit: () => Pointer<mtmd_input_chunks>.fromAddress(0x10),
      #inputChunksFree: (Pointer<mtmd_input_chunks> _) {},
      #helperInitOptDefault: unused,
      #helperBitmapInitFromFile: unused,
      #helperBitmapInitFromBuf: unused,
      #bitmapInitFromAudio: (int sampleCount, Pointer<Float> _) =>
          audioBitmap(sampleCount),
      #supportsVision: (Pointer<mtmd_context> _) => false,
      #supportsAudio: (Pointer<mtmd_context> _) => true,
      #supportsVideo: (Pointer<mtmd_context> _) => false,
      #bitmapFree: (Pointer<mtmd_bitmap> bitmap) {
        freedBitmaps.add(bitmap.address);
      },
      #tokenize:
          (
            Pointer<mtmd_context> _,
            Pointer<mtmd_input_chunks> _,
            Pointer<mtmd_input_text> _,
            Pointer<Pointer<mtmd_bitmap>> _,
            int _,
          ) {
            calls.add('mtmd_tokenize');
            return 0;
          },
      #helperEvalChunks:
          (
            Pointer<mtmd_context> _,
            Pointer<llama_context> context,
            Pointer<mtmd_input_chunks> _,
            int nPast,
            int _,
            int nBatch,
            bool _,
            Pointer<llama_pos> newNPast,
          ) {
            calls.add('mtmd_helper_eval_chunks');
            return evalMedia(context, nPast, nBatch, newNPast);
          },
      #chunkEval: chunkEval ? _chunkEvalApi : null,
      #logSet: null,
      #helperLogSet: null,
    }).reflectee;
    _setPrivate('_mtmdPrimarySymbolsUnavailable', true);
    _setPrivate('_mtmdFallbackLookupAttempted', true);
    _setPrivate('_mtmdFallbackApi', api);
  }

  /// The projector the fake `mtmd_init_from_file` returns.
  static final Pointer<mtmd_context> projector = Pointer.fromAddress(0x30);

  /// The service this fake is installed in.
  final LlamaCppService service;

  /// The token ids the media part evaluates to.
  final List<int> tokens;

  /// Whether the fallback has the chunk-level functions.
  final bool chunkEval;

  /// The decode call the media evaluation makes.
  final int Function(Pointer<llama_context> context, llama_batch batch) decode;

  /// The bitmap the fake `mtmd_bitmap_init_from_audio` returns for an audio
  /// part of a sample count; a null pointer fails that part.
  final Pointer<mtmd_bitmap> Function(int sampleCount) audioBitmap;

  /// Upstream mtmd functions called on the projector so far, in order.
  final List<String> calls = <String>[];

  /// Addresses passed to the fake `mtmd_bitmap_free` so far, in order.
  final List<int> freedBitmaps = <int>[];

  /// Media evaluations so far, through this fake or an `ExitTeardownApi`
  /// given [evalMedia].
  int evaluations = 0;

  final Pointer<Utf8> _marker = '<__media__>'.toNativeUtf8();

  /// One media part for a prompt holding the media marker.
  List<LlamaContentPart> get parts => [
    LlamaAudioContent(samples: Float32List(1)),
  ];

  late final MtmdChunkEvalApi _chunkEvalApi = MtmdChunkEvalApi(
    chunksSize: (_) => 1,
    chunksGet: (_, _) => Pointer<mtmd_input_chunk>.fromAddress(0x40),
    chunkType: (_) => mtmd_input_chunk_type.MTMD_INPUT_CHUNK_TYPE_TEXT.value,
    evalChunkSingle: (_, context, _, nPast, _, nBatch, _, newNPast) {
      calls.add('mtmd_helper_eval_chunk_single');
      return evalMedia(context, nPast, nBatch, newNPast);
    },
    encodeChunk: (_, _) => throw StateError('unexpected mtmd call'),
    outputEmbd: (_) => throw StateError('unexpected mtmd call'),
    decodeImageChunk: (_, _, _, _, _, _, _, _, _, _) =>
        throw StateError('unexpected mtmd call'),
  );

  /// Decodes [tokens] on [context] from [nPast] in batches of [nBatch].
  int evalMedia(
    Pointer<llama_context> context,
    int nPast,
    int nBatch,
    Pointer<llama_pos> newNPast,
  ) {
    evaluations++;
    final ids = malloc<llama_token>(tokens.length);
    try {
      ids.asTypedList(tokens.length).setAll(0, tokens);
      for (var start = 0; start < tokens.length; start += nBatch) {
        final count = min(nBatch, tokens.length - start);
        final result = decode(context, llama_batch_get_one(ids + start, count));
        if (result != 0) return result;
      }
      newNPast.value = nPast + tokens.length;
      return 0;
    } finally {
      malloc.free(ids);
    }
  }

  static Pointer<mtmd_bitmap> _audioBitmap(int _) => Pointer.fromAddress(0x20);

  /// Frees the marker text; call after the service is disposed.
  void dispose() => malloc.free(_marker);

  void _setPrivate(String field, Object? value) {
    final owner = reflectClass(LlamaCppService).owner as LibraryMirror;
    reflect(service).setField(MirrorSystem.getSymbol(field, owner), value);
  }
}
