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

  /// Called with the native name of each call before it is made.
  void Function(String name)? onCall;

  /// Decides, for a call that reaches libllamadart or libmtmd, whether it
  /// returns its failure value instead: `nullptr`, `false`, `0` for a size,
  /// `LLAMA_TOKEN_NULL` for a sample, `GGML_STATUS_FAILED` for a graph compute
  /// and `LLAMA_DART_STATUS_EXCEPTION` for another status.
  /// `llama_dart_synchronize` then does nothing.
  bool Function(String name)? fail;

  /// Native names of the calls made so far, in order.
  final List<String> calls = <String>[];

  /// Addresses passed to `llama_dart_exit_free` so far.
  final List<int> freed = <int>[];

  /// Addresses of the objects created or tracked through this API so far.
  final List<int> owned = <int>[];

  /// Token count of the batch of each `llama_dart_decode` so far.
  final List<int> decodedTokens = <int>[];

  /// The [owned] objects not passed to `llama_dart_exit_free` yet.
  List<int> get unfreed => [
    for (final address in owned)
      if (!freed.contains(address)) address,
  ];

  /// The [calls] with one letter per call: `d` for a one-token decode and `D`
  /// for a longer one, `S` sample, `Y` synchronize, `G` and `H` the sequence
  /// state size and data reads, `X` its write, and `?` for any other call.
  String get shorthand {
    var decode = 0;
    return [
      for (final call in calls)
        switch (call) {
          'llama_dart_decode' => decodedTokens[decode++] == 1 ? 'd' : 'D',
          'llama_dart_sampler_sample' => 'S',
          'llama_dart_synchronize' => 'Y',
          'llama_dart_state_seq_get_size_ext' => 'G',
          'llama_dart_state_seq_get_data_ext' => 'H',
          'llama_dart_state_seq_set_data_ext' => 'X',
          _ => '?',
        },
    ].join();
  }

  static const int _statusException = -2147483648;

  // Records [name] and returns whether the call goes on to do its work.
  bool _proceeds(String name) {
    onCall?.call(name);
    calls.add(name);
    return !(fail?.call(name) ?? false);
  }

  /// Forgets the calls recorded so far; [owned] and [freed] are kept.
  void clearCalls() {
    calls.clear();
    decodedTokens.clear();
  }

  int _eval(
    String name,
    Pointer<llama_context> lctx,
    int nPast,
    int nBatch,
    Pointer<llama_pos> newNPast,
  ) {
    if (!_proceeds(name)) return _statusException;
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
      _proceeds('llama_dart_exit_track');
      owned.add(object.address);
      return real.track(object, free, stage);
    },
    untrack: (object) {
      _proceeds('llama_dart_exit_untrack');
      return real.untrack(object);
    },
    free: (object) {
      _proceeds('llama_dart_exit_free');
      freed.add(object.address);
      real.free(object);
    },
    freeAddress: real.freeAddress,
    modelLoadFromFile: (path, params) {
      if (!_proceeds('llama_dart_model_load_from_file')) return nullptr;
      final model = real.modelLoadFromFile(path, params);
      owned.add(model.address);
      return model;
    },
    initFromModel: (model, params) {
      if (!_proceeds('llama_dart_init_from_model')) return nullptr;
      final context = real.initFromModel(model, params);
      owned.add(context.address);
      return context;
    },
    mtmdInitFromFile: (path, model, params) {
      if (!_proceeds('llama_dart_mtmd_init_from_file')) return nullptr;
      owned.add(projector.address);
      return projector;
    },
    decode: (ctx, batch) {
      final proceeds = _proceeds('llama_dart_decode');
      decodedTokens.add(batch.n_tokens);
      return proceeds ? real.decode(ctx, batch) : _statusException;
    },
    encode: (ctx, batch) {
      if (!_proceeds('llama_dart_encode')) return _statusException;
      return real.encode(ctx, batch);
    },
    synchronize: (ctx) {
      if (_proceeds('llama_dart_synchronize')) real.synchronize(ctx);
    },
    samplerSample: (sampler, ctx, index) {
      if (!_proceeds('llama_dart_sampler_sample')) return LLAMA_TOKEN_NULL;
      return real.samplerSample(sampler, ctx, index);
    },
    stateSaveFile: (ctx, path, tokens, tokenCount) {
      if (!_proceeds('llama_dart_state_save_file')) return false;
      return real.stateSaveFile(ctx, path, tokens, tokenCount);
    },
    stateLoadFile: (ctx, path, tokensOut, tokenCapacity, tokenCountOut) {
      if (!_proceeds('llama_dart_state_load_file')) return false;
      return real.stateLoadFile(
        ctx,
        path,
        tokensOut,
        tokenCapacity,
        tokenCountOut,
      );
    },
    stateSeqGetSizeExt: (ctx, seqId, flags) {
      if (!_proceeds('llama_dart_state_seq_get_size_ext')) return 0;
      return real.stateSeqGetSizeExt(ctx, seqId, flags);
    },
    stateSeqGetDataExt: (ctx, dst, size, seqId, flags) {
      if (!_proceeds('llama_dart_state_seq_get_data_ext')) return 0;
      return real.stateSeqGetDataExt(ctx, dst, size, seqId, flags);
    },
    stateSeqSetDataExt: (ctx, src, size, seqId, flags) {
      if (!_proceeds('llama_dart_state_seq_set_data_ext')) return 0;
      return real.stateSeqSetDataExt(ctx, src, size, seqId, flags);
    },
    adapterLoraInit: (model, path) {
      if (!_proceeds('llama_dart_adapter_lora_init')) return nullptr;
      return real.adapterLoraInit(model, path);
    },
    mtmdTokenize: (ctx, output, text, bitmaps, bitmapCount) {
      return _proceeds('llama_dart_mtmd_tokenize') ? 0 : _statusException;
    },
    mtmdEncodeChunk: (ctx, chunk) {
      _proceeds('llama_dart_mtmd_encode_chunk');
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
          _proceeds('llama_dart_mtmd_helper_decode_image_chunk');
          newNPast.value = nPast;
          return 0;
        },
    schedGraphCompute: (sched, graph) {
      if (!_proceeds('llama_dart_ggml_backend_sched_graph_compute')) {
        return ggml_status.GGML_STATUS_FAILED.value;
      }
      return real.schedGraphCompute(sched, graph);
    },
  );
}
