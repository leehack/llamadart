import 'dart:ffi';

import 'bindings.dart';
import 'llama_cpp_raw_bindings.dart' as raw_bindings;

typedef _ChunksSizeNative = Size Function(Pointer<mtmd_input_chunks>);
typedef _ChunksSizeDart = int Function(Pointer<mtmd_input_chunks>);
typedef _ChunksGetNative =
    Pointer<mtmd_input_chunk> Function(Pointer<mtmd_input_chunks>, Size);
typedef _ChunksGetDart =
    Pointer<mtmd_input_chunk> Function(Pointer<mtmd_input_chunks>, int);
typedef _ChunkTypeNative = UnsignedInt Function(Pointer<mtmd_input_chunk>);
typedef _ChunkTypeDart = int Function(Pointer<mtmd_input_chunk>);
typedef _EvalChunkSingleNative =
    Int32 Function(
      Pointer<mtmd_context>,
      Pointer<llama_context>,
      Pointer<mtmd_input_chunk>,
      llama_pos,
      llama_seq_id,
      Int32,
      Bool,
      Pointer<llama_pos>,
    );
typedef _EvalChunkSingleDart =
    int Function(
      Pointer<mtmd_context>,
      Pointer<llama_context>,
      Pointer<mtmd_input_chunk>,
      int,
      int,
      int,
      bool,
      Pointer<llama_pos>,
    );
typedef _EncodeChunkNative =
    Int32 Function(Pointer<mtmd_context>, Pointer<mtmd_input_chunk>);
typedef _EncodeChunkDart =
    int Function(Pointer<mtmd_context>, Pointer<mtmd_input_chunk>);
typedef _OutputEmbdNative = Pointer<Float> Function(Pointer<mtmd_context>);
typedef _OutputEmbdDart = Pointer<Float> Function(Pointer<mtmd_context>);
typedef _DecodeImageChunkNative =
    Int32 Function(
      Pointer<mtmd_context>,
      Pointer<llama_context>,
      Pointer<mtmd_input_chunk>,
      Pointer<Float>,
      llama_pos,
      llama_seq_id,
      Int32,
      Pointer<llama_pos>,
      mtmd_helper_post_decode_callback,
      Pointer<Void>,
    );
typedef _DecodeImageChunkDart =
    int Function(
      Pointer<mtmd_context>,
      Pointer<llama_context>,
      Pointer<mtmd_input_chunk>,
      Pointer<Float>,
      int,
      int,
      int,
      Pointer<llama_pos>,
      mtmd_helper_post_decode_callback,
      Pointer<Void>,
    );

/// The mtmd functions that `mtmd_helper_eval_chunks` calls, resolved from one
/// library.
final class MtmdChunkEvalApi {
  /// Creates an API from resolved functions.
  const MtmdChunkEvalApi({
    required this.chunksSize,
    required this.chunksGet,
    required this.chunkType,
    required this.evalChunkSingle,
    required this.encodeChunk,
    required this.outputEmbd,
    required this.decodeImageChunk,
  });

  /// The `package:llamadart/llamadart` asset's bindings.
  static const MtmdChunkEvalApi primary = MtmdChunkEvalApi(
    chunksSize: mtmd_input_chunks_size,
    chunksGet: mtmd_input_chunks_get,
    chunkType: raw_bindings.mtmd_input_chunk_get_type_raw,
    evalChunkSingle: mtmd_helper_eval_chunk_single,
    encodeChunk: mtmd_encode_chunk,
    outputEmbd: mtmd_get_output_embd,
    decodeImageChunk: mtmd_helper_decode_image_chunk,
  );

  /// Resolves every function from [library], or returns `null` if any symbol
  /// is missing.
  static MtmdChunkEvalApi? tryLoad(DynamicLibrary library) {
    try {
      return MtmdChunkEvalApi(
        chunksSize: library.lookupFunction<_ChunksSizeNative, _ChunksSizeDart>(
          'mtmd_input_chunks_size',
        ),
        chunksGet: library.lookupFunction<_ChunksGetNative, _ChunksGetDart>(
          'mtmd_input_chunks_get',
        ),
        chunkType: library.lookupFunction<_ChunkTypeNative, _ChunkTypeDart>(
          'mtmd_input_chunk_get_type',
        ),
        evalChunkSingle: library
            .lookupFunction<_EvalChunkSingleNative, _EvalChunkSingleDart>(
              'mtmd_helper_eval_chunk_single',
            ),
        encodeChunk: library
            .lookupFunction<_EncodeChunkNative, _EncodeChunkDart>(
              'mtmd_encode_chunk',
            ),
        outputEmbd: library.lookupFunction<_OutputEmbdNative, _OutputEmbdDart>(
          'mtmd_get_output_embd',
        ),
        decodeImageChunk: library
            .lookupFunction<_DecodeImageChunkNative, _DecodeImageChunkDart>(
              'mtmd_helper_decode_image_chunk',
            ),
      );
    } on ArgumentError {
      return null;
    }
  }

  /// `mtmd_input_chunks_size`.
  final int Function(Pointer<mtmd_input_chunks> chunks) chunksSize;

  /// `mtmd_input_chunks_get`.
  final Pointer<mtmd_input_chunk> Function(
    Pointer<mtmd_input_chunks> chunks,
    int index,
  )
  chunksGet;

  /// `mtmd_input_chunk_get_type`, as its raw enum value.
  final int Function(Pointer<mtmd_input_chunk> chunk) chunkType;

  /// `mtmd_helper_eval_chunk_single`.
  final int Function(
    Pointer<mtmd_context> ctx,
    Pointer<llama_context> lctx,
    Pointer<mtmd_input_chunk> chunk,
    int nPast,
    int seqId,
    int nBatch,
    bool logitsLast,
    Pointer<llama_pos> newNPast,
  )
  evalChunkSingle;

  /// `mtmd_encode_chunk`.
  final int Function(Pointer<mtmd_context> ctx, Pointer<mtmd_input_chunk> chunk)
  encodeChunk;

  /// `mtmd_get_output_embd`.
  final Pointer<Float> Function(Pointer<mtmd_context> ctx) outputEmbd;

  /// `mtmd_helper_decode_image_chunk`.
  final int Function(
    Pointer<mtmd_context> ctx,
    Pointer<llama_context> lctx,
    Pointer<mtmd_input_chunk> chunk,
    Pointer<Float> encodedEmbd,
    int nPast,
    int seqId,
    int nBatch,
    Pointer<llama_pos> newNPast,
    mtmd_helper_post_decode_callback callback,
    Pointer<Void> userData,
  )
  decodeImageChunk;
}

/// Evaluates [chunks] as `mtmd_helper_eval_chunks` does for `n_past` 0,
/// `seq_id` 0 and `logits_last` true, but stops early once [cancelToken]
/// reads 1.
///
/// The token is read before each chunk. An image or audio chunk's encode and
/// embedding decode are separate calls, and the token is read between them.
/// Returns the first nonzero native result, otherwise 0. After a 0,
/// [newNPast] holds the position after the last fully evaluated chunk.
int evalMtmdChunksUntilCancelled(
  MtmdChunkEvalApi api,
  Pointer<mtmd_context> ctx,
  Pointer<llama_context> lctx,
  Pointer<mtmd_input_chunks> chunks,
  int nBatch,
  Pointer<llama_pos> newNPast,
  Pointer<Int8> cancelToken,
) {
  final nChunks = api.chunksSize(chunks);
  var nPast = 0;
  for (var i = 0; i < nChunks; i++) {
    if (cancelToken.value == 1) break;
    final chunk = api.chunksGet(chunks, i);
    final type = api.chunkType(chunk);
    int result;
    if (type == mtmd_input_chunk_type.MTMD_INPUT_CHUNK_TYPE_IMAGE.value ||
        type == mtmd_input_chunk_type.MTMD_INPUT_CHUNK_TYPE_AUDIO.value) {
      result = api.encodeChunk(ctx, chunk);
      if (result == 0) {
        if (cancelToken.value == 1) break;
        result = api.decodeImageChunk(
          ctx,
          lctx,
          chunk,
          api.outputEmbd(ctx),
          nPast,
          0,
          nBatch,
          newNPast,
          nullptr,
          nullptr,
        );
      }
    } else {
      newNPast.value = nPast;
      result = api.evalChunkSingle(
        ctx,
        lctx,
        chunk,
        nPast,
        0,
        nBatch,
        i == nChunks - 1,
        newNPast,
      );
    }
    if (result != 0) return result;
    nPast = newNPast.value;
  }
  newNPast.value = nPast;
  return 0;
}
