import 'dart:ffi';

import 'package:llamadart/src/backends/llama_cpp/bindings.dart';
import 'package:llamadart/src/backends/llama_cpp/exit_teardown_api.dart';

/// Evaluates a fake media prompt on [lctx] from position [nPast], writes the
/// position after it to [newNPast] and returns the native result.
typedef FakeMediaEval =
    int Function(
      Pointer<llama_context> lctx,
      int nPast,
      int nBatch,
      Pointer<llama_pos> newNPast,
    );

/// An [ExitTeardownApi] that records the native name of each call made
/// through it.
///
/// Calls go on to [real], except the mtmd functions, which stand in for
/// libmtmd: init returns [projector], tokenize and encode succeed, the two
/// eval functions run [evalMedia], and the image decode leaves the position
/// where it was.
final class RecordingExitTeardown {
  /// Records calls on their way to [real].
  RecordingExitTeardown(this.real, {this.evalMedia});

  /// The projector the fake `llama_dart_mtmd_init_from_file` returns.
  static final Pointer<mtmd_context> projector = Pointer.fromAddress(0x30);

  /// The functions that do the work.
  final ExitTeardownApi real;

  /// What the fake eval functions run; without it they evaluate nothing.
  final FakeMediaEval? evalMedia;

  /// Native names of the calls made so far, in order.
  final List<String> calls = <String>[];

  /// Addresses passed to `llama_dart_exit_free` so far.
  final List<int> freed = <int>[];

  int _eval(
    String name,
    Pointer<llama_context> lctx,
    int nPast,
    int nBatch,
    Pointer<llama_pos> newNPast,
  ) {
    calls.add(name);
    final evalMedia = this.evalMedia;
    if (evalMedia == null) {
      newNPast.value = nPast;
      return 0;
    }
    return evalMedia(lctx, nPast, nBatch, newNPast);
  }

  /// The recording functions.
  late final ExitTeardownApi api = ExitTeardownApi(
    track: (object, free, stage) {
      calls.add('llama_dart_exit_track');
      return real.track(object, free, stage);
    },
    untrack: (object) {
      calls.add('llama_dart_exit_untrack');
      return real.untrack(object);
    },
    free: (object) {
      calls.add('llama_dart_exit_free');
      freed.add(object.address);
      real.free(object);
    },
    freeAddress: real.freeAddress,
    modelLoadFromFile: (path, params) {
      calls.add('llama_dart_model_load_from_file');
      return real.modelLoadFromFile(path, params);
    },
    initFromModel: (model, params) {
      calls.add('llama_dart_init_from_model');
      return real.initFromModel(model, params);
    },
    mtmdInitFromFile: (path, model, params) {
      calls.add('llama_dart_mtmd_init_from_file');
      return projector;
    },
    decode: (ctx, batch) {
      calls.add('llama_dart_decode');
      return real.decode(ctx, batch);
    },
    encode: (ctx, batch) {
      calls.add('llama_dart_encode');
      return real.encode(ctx, batch);
    },
    synchronize: (ctx) {
      calls.add('llama_dart_synchronize');
      real.synchronize(ctx);
    },
    samplerSample: (sampler, ctx, index) {
      calls.add('llama_dart_sampler_sample');
      return real.samplerSample(sampler, ctx, index);
    },
    stateSaveFile: (ctx, path, tokens, tokenCount) {
      calls.add('llama_dart_state_save_file');
      return real.stateSaveFile(ctx, path, tokens, tokenCount);
    },
    stateLoadFile: (ctx, path, tokensOut, tokenCapacity, tokenCountOut) {
      calls.add('llama_dart_state_load_file');
      return real.stateLoadFile(
        ctx,
        path,
        tokensOut,
        tokenCapacity,
        tokenCountOut,
      );
    },
    stateSeqGetSizeExt: (ctx, seqId, flags) {
      calls.add('llama_dart_state_seq_get_size_ext');
      return real.stateSeqGetSizeExt(ctx, seqId, flags);
    },
    stateSeqGetDataExt: (ctx, dst, size, seqId, flags) {
      calls.add('llama_dart_state_seq_get_data_ext');
      return real.stateSeqGetDataExt(ctx, dst, size, seqId, flags);
    },
    stateSeqSetDataExt: (ctx, src, size, seqId, flags) {
      calls.add('llama_dart_state_seq_set_data_ext');
      return real.stateSeqSetDataExt(ctx, src, size, seqId, flags);
    },
    adapterLoraInit: (model, path) {
      calls.add('llama_dart_adapter_lora_init');
      return real.adapterLoraInit(model, path);
    },
    mtmdTokenize: (ctx, output, text, bitmaps, bitmapCount) {
      calls.add('llama_dart_mtmd_tokenize');
      return 0;
    },
    mtmdEncodeChunk: (ctx, chunk) {
      calls.add('llama_dart_mtmd_encode_chunk');
      return 0;
    },
    mtmdHelperEvalChunks:
        (ctx, lctx, chunks, nPast, seqId, nBatch, logitsLast, newNPast) =>
            _eval(
              'llama_dart_mtmd_helper_eval_chunks',
              lctx,
              nPast,
              nBatch,
              newNPast,
            ),
    mtmdHelperEvalChunkSingle:
        (ctx, lctx, chunk, nPast, seqId, nBatch, logitsLast, newNPast) => _eval(
          'llama_dart_mtmd_helper_eval_chunk_single',
          lctx,
          nPast,
          nBatch,
          newNPast,
        ),
    mtmdHelperDecodeImageChunk:
        (
          ctx,
          lctx,
          chunk,
          encodedEmbd,
          nPast,
          seqId,
          nBatch,
          newNPast,
          callback,
          userData,
        ) {
          calls.add('llama_dart_mtmd_helper_decode_image_chunk');
          newNPast.value = nPast;
          return 0;
        },
    schedGraphCompute: (sched, graph) {
      calls.add('llama_dart_ggml_backend_sched_graph_compute');
      return real.schedGraphCompute(sched, graph);
    },
  );
}
