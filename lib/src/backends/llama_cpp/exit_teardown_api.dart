import 'dart:ffi';

import '../isolate_shutdown_releases.dart';
import 'bindings.dart';

const _llamadartAsset = 'package:llamadart/llamadart';
const _wrapperAsset = 'package:llamadart/llamadart_wrapper';

typedef _FreeNative = Void Function(Pointer<Void>);
typedef _TrackNative =
    Bool Function(Pointer<Void>, Pointer<NativeFunction<_FreeNative>>, Int32);
typedef _UntrackNative = Bool Function(Pointer<Void>);
typedef _ModelLoadNative =
    Pointer<llama_model> Function(Pointer<Char>, llama_model_params);
typedef _InitFromModelNative =
    Pointer<llama_context> Function(Pointer<llama_model>, llama_context_params);
typedef _MtmdInitNative =
    Pointer<mtmd_context> Function(
      Pointer<Char>,
      Pointer<llama_model>,
      Pointer<mtmd_context_params>,
    );
typedef _DecodeNative = Int32 Function(Pointer<llama_context>, llama_batch);
typedef _SynchronizeNative = Void Function(Pointer<llama_context>);
typedef _SamplerSampleNative =
    llama_token Function(Pointer<llama_sampler>, Pointer<llama_context>, Int32);
typedef _StateSaveFileNative =
    Bool Function(
      Pointer<llama_context>,
      Pointer<Char>,
      Pointer<llama_token>,
      Size,
    );
typedef _StateLoadFileNative =
    Bool Function(
      Pointer<llama_context>,
      Pointer<Char>,
      Pointer<llama_token>,
      Size,
      Pointer<Size>,
    );
typedef _StateSeqSizeNative =
    Size Function(Pointer<llama_context>, llama_seq_id, Uint32);
typedef _StateSeqDataNative =
    Size Function(
      Pointer<llama_context>,
      Pointer<Uint8>,
      Size,
      llama_seq_id,
      Uint32,
    );
typedef _AdapterLoraInitNative =
    Pointer<llama_adapter_lora> Function(Pointer<llama_model>, Pointer<Char>);
typedef _MtmdTokenizeNative =
    Int32 Function(
      Pointer<mtmd_context>,
      Pointer<mtmd_input_chunks>,
      Pointer<mtmd_input_text>,
      Pointer<Pointer<mtmd_bitmap>>,
      Size,
    );
typedef _MtmdEncodeChunkNative =
    Int32 Function(Pointer<mtmd_context>, Pointer<mtmd_input_chunk>);
typedef _MtmdEvalChunksNative =
    Int32 Function(
      Pointer<mtmd_context>,
      Pointer<llama_context>,
      Pointer<mtmd_input_chunks>,
      llama_pos,
      llama_seq_id,
      Int32,
      Bool,
      Pointer<llama_pos>,
    );
typedef _MtmdEvalChunkSingleNative =
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
typedef _MtmdDecodeImageChunkNative =
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
typedef _SchedGraphComputeNative =
    Int Function(ggml_backend_sched_t, Pointer<ggml_cgraph>);

/// The `llama_dart_exit_stage` value [stage] is tracked in.
int exitStageValue(ShutdownStage stage) => switch (stage) {
  ShutdownStage.session =>
    llama_dart_exit_stage.LLAMA_DART_EXIT_STAGE_SESSION.value,
  ShutdownStage.scheduler =>
    llama_dart_exit_stage.LLAMA_DART_EXIT_STAGE_SCHEDULER.value,
  ShutdownStage.context =>
    llama_dart_exit_stage.LLAMA_DART_EXIT_STAGE_CONTEXT.value,
  ShutdownStage.modelUser =>
    llama_dart_exit_stage.LLAMA_DART_EXIT_STAGE_MODEL_USER.value,
  ShutdownStage.backend =>
    llama_dart_exit_stage.LLAMA_DART_EXIT_STAGE_BACKEND.value,
  ShutdownStage.model =>
    llama_dart_exit_stage.LLAMA_DART_EXIT_STAGE_MODEL.value,
};

/// libllamadart's exit-teardown functions, resolved from one library.
///
/// The library keeps a registry of the objects created through these
/// functions and, on Apple platforms, frees what is left of it during C
/// `exit`, before ggml-metal's static destructor, which aborts while a Metal
/// buffer is still allocated. Teardown waits only for the calls made through
/// these functions, and for a short settle after the last one: any other
/// native call on a tracked object that is in flight when it runs is freed
/// under (`doc/llama_cpp_exit_teardown.md`).
///
/// Windows bundles export these functions from `llamadart.dll` rather than the
/// default `llama.dll` asset, so [tryResolve] resolves `@Native` declarations
/// bound to that asset on Windows. Elsewhere it resolves the generated
/// bindings.
///
/// `llama_dart_exit_call_begin`, `llama_dart_exit_call_end` and
/// `llama_dart_exit_teardown` are left unbound: an isolate killed between
/// begin and end never reaches end, and a Dart program that returns from
/// `main` after teardown waits forever for its blocked isolates.
final class ExitTeardownApi {
  /// Creates an API from resolved functions.
  const ExitTeardownApi({
    required this.track,
    required this.untrack,
    required this.free,
    required this.freeAddress,
    required this.modelLoadFromFile,
    required this.initFromModel,
    required this.mtmdInitFromFile,
    required this.decode,
    required this.encode,
    required this.synchronize,
    required this.samplerSample,
    required this.stateSaveFile,
    required this.stateLoadFile,
    required this.stateSeqGetSizeExt,
    required this.stateSeqGetDataExt,
    required this.stateSeqSetDataExt,
    required this.adapterLoraInit,
    required this.mtmdTokenize,
    required this.mtmdEncodeChunk,
    required this.mtmdHelperEvalChunks,
    required this.mtmdHelperEvalChunkSingle,
    required this.mtmdHelperDecodeImageChunk,
    required this.schedGraphCompute,
  });

  /// The oldest `llamadart-native` release to use these functions with.
  ///
  /// `v0.5.0-1` exports them too, so [tryResolve] accepts it, but its
  /// teardown does not wait for a free that is in flight on the last tracked
  /// object.
  static const String minimumNativeRelease = 'v0.5.0-2';

  /// Resolves every function from the loaded runtime, or returns `null` when
  /// it does not export all of them.
  ///
  /// [isWindows] selects the asset the functions are bound to. [symbol]
  /// replaces that lookup: it returns the address of the function exported
  /// under a name, and throws [ArgumentError] when there is none.
  static ExitTeardownApi? tryResolve({
    required bool isWindows,
    Pointer<NativeType> Function(String name)? symbol,
  }) {
    try {
      return ExitTeardownApi._fromSymbols(
        symbol ?? (name) => symbolAddress(name, isWindows: isWindows),
      );
    } on ArgumentError {
      return null;
    }
  }

  /// The address of the function the loaded runtime exports as [name], from
  /// the asset [isWindows] selects; throws [ArgumentError] when it exports
  /// none.
  static Pointer<NativeType> symbolAddress(
    String name, {
    required bool isWindows,
  }) => (isWindows ? _wrapperAssetSymbol : _bindingsSymbol)(name);

  // Every function is called through the address resolved here, so none can
  // be bound without being part of the probe.
  factory ExitTeardownApi._fromSymbols(
    Pointer<NativeType> Function(String name) symbol,
  ) {
    Pointer<NativeFunction<T>> function<T extends Function>(String name) =>
        symbol(name).cast();
    final free = function<_FreeNative>('llama_dart_exit_free');
    return ExitTeardownApi(
      track: function<_TrackNative>('llama_dart_exit_track').asFunction(),
      untrack: function<_UntrackNative>('llama_dart_exit_untrack').asFunction(),
      free: free.asFunction(),
      freeAddress: free.cast(),
      modelLoadFromFile: function<_ModelLoadNative>(
        'llama_dart_model_load_from_file',
      ).asFunction(),
      initFromModel: function<_InitFromModelNative>(
        'llama_dart_init_from_model',
      ).asFunction(),
      mtmdInitFromFile: function<_MtmdInitNative>(
        'llama_dart_mtmd_init_from_file',
      ).asFunction(),
      decode: function<_DecodeNative>('llama_dart_decode').asFunction(),
      encode: function<_DecodeNative>('llama_dart_encode').asFunction(),
      synchronize: function<_SynchronizeNative>(
        'llama_dart_synchronize',
      ).asFunction(),
      samplerSample: function<_SamplerSampleNative>(
        'llama_dart_sampler_sample',
      ).asFunction(),
      stateSaveFile: function<_StateSaveFileNative>(
        'llama_dart_state_save_file',
      ).asFunction(),
      stateLoadFile: function<_StateLoadFileNative>(
        'llama_dart_state_load_file',
      ).asFunction(),
      stateSeqGetSizeExt: function<_StateSeqSizeNative>(
        'llama_dart_state_seq_get_size_ext',
      ).asFunction(),
      stateSeqGetDataExt: function<_StateSeqDataNative>(
        'llama_dart_state_seq_get_data_ext',
      ).asFunction(),
      stateSeqSetDataExt: function<_StateSeqDataNative>(
        'llama_dart_state_seq_set_data_ext',
      ).asFunction(),
      adapterLoraInit: function<_AdapterLoraInitNative>(
        'llama_dart_adapter_lora_init',
      ).asFunction(),
      mtmdTokenize: function<_MtmdTokenizeNative>(
        'llama_dart_mtmd_tokenize',
      ).asFunction(),
      mtmdEncodeChunk: function<_MtmdEncodeChunkNative>(
        'llama_dart_mtmd_encode_chunk',
      ).asFunction(),
      mtmdHelperEvalChunks: function<_MtmdEvalChunksNative>(
        'llama_dart_mtmd_helper_eval_chunks',
      ).asFunction(),
      mtmdHelperEvalChunkSingle: function<_MtmdEvalChunkSingleNative>(
        'llama_dart_mtmd_helper_eval_chunk_single',
      ).asFunction(),
      mtmdHelperDecodeImageChunk: function<_MtmdDecodeImageChunkNative>(
        'llama_dart_mtmd_helper_decode_image_chunk',
      ).asFunction(),
      schedGraphCompute: function<_SchedGraphComputeNative>(
        'llama_dart_ggml_backend_sched_graph_compute',
      ).asFunction(),
    );
  }

  /// `llama_dart_exit_track`, with an [exitStageValue] as `stage`.
  final bool Function(
    Pointer<Void> object,
    Pointer<NativeFunction<Void Function(Pointer<Void>)>> free,
    int stage,
  )
  track;

  /// `llama_dart_exit_untrack`: stops tracking an object without freeing it,
  /// and returns whether it was tracked.
  final bool Function(Pointer<Void> object) untrack;

  /// `llama_dart_exit_free`: frees a tracked object with the function it was
  /// tracked with, and does nothing for any other pointer.
  final void Function(Pointer<Void> object) free;

  /// The address of [free], for `IsolateShutdownReleases`.
  final Pointer<NativeFinalizerFunction> freeAddress;

  /// `llama_dart_model_load_from_file`.
  final Pointer<llama_model> Function(
    Pointer<Char> path,
    llama_model_params params,
  )
  modelLoadFromFile;

  /// `llama_dart_init_from_model`.
  final Pointer<llama_context> Function(
    Pointer<llama_model> model,
    llama_context_params params,
  )
  initFromModel;

  /// `llama_dart_mtmd_init_from_file`.
  final Pointer<mtmd_context> Function(
    Pointer<Char> path,
    Pointer<llama_model> model,
    Pointer<mtmd_context_params> params,
  )
  mtmdInitFromFile;

  /// `llama_dart_decode`, which also waits for the backend.
  final int Function(Pointer<llama_context> ctx, llama_batch batch) decode;

  /// `llama_dart_encode`, which also waits for the backend.
  final int Function(Pointer<llama_context> ctx, llama_batch batch) encode;

  /// `llama_dart_synchronize`.
  final void Function(Pointer<llama_context> ctx) synchronize;

  /// `llama_dart_sampler_sample`.
  final int Function(
    Pointer<llama_sampler> sampler,
    Pointer<llama_context> ctx,
    int index,
  )
  samplerSample;

  /// `llama_dart_state_save_file`.
  final bool Function(
    Pointer<llama_context> ctx,
    Pointer<Char> path,
    Pointer<llama_token> tokens,
    int tokenCount,
  )
  stateSaveFile;

  /// `llama_dart_state_load_file`.
  final bool Function(
    Pointer<llama_context> ctx,
    Pointer<Char> path,
    Pointer<llama_token> tokensOut,
    int tokenCapacity,
    Pointer<Size> tokenCountOut,
  )
  stateLoadFile;

  /// `llama_dart_state_seq_get_size_ext`.
  final int Function(Pointer<llama_context> ctx, int seqId, int flags)
  stateSeqGetSizeExt;

  /// `llama_dart_state_seq_get_data_ext`.
  final int Function(
    Pointer<llama_context> ctx,
    Pointer<Uint8> dst,
    int size,
    int seqId,
    int flags,
  )
  stateSeqGetDataExt;

  /// `llama_dart_state_seq_set_data_ext`.
  final int Function(
    Pointer<llama_context> ctx,
    Pointer<Uint8> src,
    int size,
    int seqId,
    int flags,
  )
  stateSeqSetDataExt;

  /// `llama_dart_adapter_lora_init`.
  final Pointer<llama_adapter_lora> Function(
    Pointer<llama_model> model,
    Pointer<Char> path,
  )
  adapterLoraInit;

  /// `llama_dart_mtmd_tokenize`.
  final int Function(
    Pointer<mtmd_context> ctx,
    Pointer<mtmd_input_chunks> output,
    Pointer<mtmd_input_text> text,
    Pointer<Pointer<mtmd_bitmap>> bitmaps,
    int bitmapCount,
  )
  mtmdTokenize;

  /// `llama_dart_mtmd_encode_chunk`.
  final int Function(Pointer<mtmd_context> ctx, Pointer<mtmd_input_chunk> chunk)
  mtmdEncodeChunk;

  /// `llama_dart_mtmd_helper_eval_chunks`, which also waits for the backend.
  final int Function(
    Pointer<mtmd_context> ctx,
    Pointer<llama_context> lctx,
    Pointer<mtmd_input_chunks> chunks,
    int nPast,
    int seqId,
    int nBatch,
    bool logitsLast,
    Pointer<llama_pos> newNPast,
  )
  mtmdHelperEvalChunks;

  /// `llama_dart_mtmd_helper_eval_chunk_single`, which also waits for the
  /// backend.
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
  mtmdHelperEvalChunkSingle;

  /// `llama_dart_mtmd_helper_decode_image_chunk`, which also waits for the
  /// backend.
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
  mtmdHelperDecodeImageChunk;

  /// `llama_dart_ggml_backend_sched_graph_compute`, as its raw `ggml_status`.
  final int Function(ggml_backend_sched_t sched, Pointer<ggml_cgraph> graph)
  schedGraphCompute;
}

/// How the service creates and frees models and contexts and makes its long
/// calls on them.
///
/// [LlamaCppObjectCalls.tracked] goes through an [ExitTeardownApi];
/// [upstream] calls llama.cpp directly, which is all a runtime older than
/// [ExitTeardownApi.minimumNativeRelease] offers. One service uses one of
/// them for all of its calls: exit teardown does not wait for an upstream
/// call on a tracked object.
final class LlamaCppObjectCalls {
  LlamaCppObjectCalls._({
    required this.exit,
    required this.loadModel,
    required this.freeModel,
    required this.modelFreeAddress,
    required this.createContext,
    required this.freeContext,
    required this.contextFreeAddress,
    required this.decode,
    required this.encode,
    required this.synchronize,
    required this.samplerSample,
    required this.stateSaveFile,
    required this.stateLoadFile,
    required this.stateSeqGetSizeExt,
    required this.stateSeqGetDataExt,
    required this.stateSeqSetDataExt,
    required this.adapterLoraInit,
  });

  /// The tracked and guarded functions of [exit].
  factory LlamaCppObjectCalls.tracked(ExitTeardownApi exit) =>
      LlamaCppObjectCalls._(
        exit: exit,
        loadModel: exit.modelLoadFromFile,
        freeModel: (model) => exit.free(model.cast()),
        modelFreeAddress: exit.freeAddress,
        createContext: exit.initFromModel,
        freeContext: (context) => exit.free(context.cast()),
        contextFreeAddress: exit.freeAddress,
        decode: exit.decode,
        encode: exit.encode,
        synchronize: exit.synchronize,
        samplerSample: exit.samplerSample,
        stateSaveFile: exit.stateSaveFile,
        stateLoadFile: exit.stateLoadFile,
        stateSeqGetSizeExt: exit.stateSeqGetSizeExt,
        stateSeqGetDataExt: exit.stateSeqGetDataExt,
        stateSeqSetDataExt: exit.stateSeqSetDataExt,
        adapterLoraInit: exit.adapterLoraInit,
      );

  /// The upstream llama.cpp functions; nothing is tracked.
  static final LlamaCppObjectCalls upstream = LlamaCppObjectCalls._(
    exit: null,
    loadModel: llama_model_load_from_file,
    freeModel: llama_model_free,
    modelFreeAddress:
        Native.addressOf<NativeFunction<Void Function(Pointer<llama_model>)>>(
          llama_model_free,
        ).cast(),
    createContext: llama_init_from_model,
    freeContext: llama_free,
    contextFreeAddress:
        Native.addressOf<NativeFunction<Void Function(Pointer<llama_context>)>>(
          llama_free,
        ).cast(),
    decode: llama_decode,
    encode: llama_encode,
    synchronize: llama_synchronize,
    samplerSample: llama_sampler_sample,
    stateSaveFile: llama_state_save_file,
    stateLoadFile: llama_state_load_file,
    stateSeqGetSizeExt: llama_state_seq_get_size_ext,
    stateSeqGetDataExt: llama_state_seq_get_data_ext,
    stateSeqSetDataExt: llama_state_seq_set_data_ext,
    adapterLoraInit: llama_adapter_lora_init,
  );

  /// [LlamaCppObjectCalls.tracked] when the loaded runtime exports the whole
  /// [ExitTeardownApi], otherwise [upstream].
  static LlamaCppObjectCalls resolve({required bool isWindows}) {
    final exit = ExitTeardownApi.tryResolve(isWindows: isWindows);
    return exit == null ? upstream : LlamaCppObjectCalls.tracked(exit);
  }

  /// The exit-teardown functions these calls go through, or `null` for
  /// [upstream].
  final ExitTeardownApi? exit;

  /// Loads a model; `nullptr` on failure.
  final Pointer<llama_model> Function(
    Pointer<Char> path,
    llama_model_params params,
  )
  loadModel;

  /// Frees a model [loadModel] returned.
  final void Function(Pointer<llama_model> model) freeModel;

  /// The function `IsolateShutdownReleases` frees a model with.
  final Pointer<NativeFinalizerFunction> modelFreeAddress;

  /// Creates a context; `nullptr` on failure.
  final Pointer<llama_context> Function(
    Pointer<llama_model> model,
    llama_context_params params,
  )
  createContext;

  /// Frees a context [createContext] returned.
  final void Function(Pointer<llama_context> context) freeContext;

  /// The function `IsolateShutdownReleases` frees a context with.
  final Pointer<NativeFinalizerFunction> contextFreeAddress;

  /// `llama_decode`.
  final int Function(Pointer<llama_context> ctx, llama_batch batch) decode;

  /// `llama_encode`.
  final int Function(Pointer<llama_context> ctx, llama_batch batch) encode;

  /// `llama_synchronize`.
  final void Function(Pointer<llama_context> ctx) synchronize;

  /// `llama_sampler_sample`.
  final int Function(
    Pointer<llama_sampler> sampler,
    Pointer<llama_context> ctx,
    int index,
  )
  samplerSample;

  /// `llama_state_save_file`.
  final bool Function(
    Pointer<llama_context> ctx,
    Pointer<Char> path,
    Pointer<llama_token> tokens,
    int tokenCount,
  )
  stateSaveFile;

  /// `llama_state_load_file`.
  final bool Function(
    Pointer<llama_context> ctx,
    Pointer<Char> path,
    Pointer<llama_token> tokensOut,
    int tokenCapacity,
    Pointer<Size> tokenCountOut,
  )
  stateLoadFile;

  /// `llama_state_seq_get_size_ext`.
  final int Function(Pointer<llama_context> ctx, int seqId, int flags)
  stateSeqGetSizeExt;

  /// `llama_state_seq_get_data_ext`.
  final int Function(
    Pointer<llama_context> ctx,
    Pointer<Uint8> dst,
    int size,
    int seqId,
    int flags,
  )
  stateSeqGetDataExt;

  /// `llama_state_seq_set_data_ext`.
  final int Function(
    Pointer<llama_context> ctx,
    Pointer<Uint8> src,
    int size,
    int seqId,
    int flags,
  )
  stateSeqSetDataExt;

  /// `llama_adapter_lora_init`.
  final Pointer<llama_adapter_lora> Function(
    Pointer<llama_model> model,
    Pointer<Char> path,
  )
  adapterLoraInit;
}

Pointer<NativeType> _bindingsSymbol(String symbol) => switch (symbol) {
  'llama_dart_exit_track' => Native.addressOf<NativeFunction<_TrackNative>>(
    llama_dart_exit_track,
  ),
  'llama_dart_exit_untrack' => Native.addressOf<NativeFunction<_UntrackNative>>(
    llama_dart_exit_untrack,
  ),
  'llama_dart_exit_free' => Native.addressOf<NativeFunction<_FreeNative>>(
    llama_dart_exit_free,
  ),
  'llama_dart_model_load_from_file' =>
    Native.addressOf<NativeFunction<_ModelLoadNative>>(
      llama_dart_model_load_from_file,
    ),
  'llama_dart_init_from_model' =>
    Native.addressOf<NativeFunction<_InitFromModelNative>>(
      llama_dart_init_from_model,
    ),
  'llama_dart_mtmd_init_from_file' =>
    Native.addressOf<NativeFunction<_MtmdInitNative>>(
      llama_dart_mtmd_init_from_file,
    ),
  'llama_dart_decode' => Native.addressOf<NativeFunction<_DecodeNative>>(
    llama_dart_decode,
  ),
  'llama_dart_encode' => Native.addressOf<NativeFunction<_DecodeNative>>(
    llama_dart_encode,
  ),
  'llama_dart_synchronize' =>
    Native.addressOf<NativeFunction<_SynchronizeNative>>(
      llama_dart_synchronize,
    ),
  'llama_dart_sampler_sample' =>
    Native.addressOf<NativeFunction<_SamplerSampleNative>>(
      llama_dart_sampler_sample,
    ),
  'llama_dart_state_save_file' =>
    Native.addressOf<NativeFunction<_StateSaveFileNative>>(
      llama_dart_state_save_file,
    ),
  'llama_dart_state_load_file' =>
    Native.addressOf<NativeFunction<_StateLoadFileNative>>(
      llama_dart_state_load_file,
    ),
  'llama_dart_state_seq_get_size_ext' =>
    Native.addressOf<NativeFunction<_StateSeqSizeNative>>(
      llama_dart_state_seq_get_size_ext,
    ),
  'llama_dart_state_seq_get_data_ext' =>
    Native.addressOf<NativeFunction<_StateSeqDataNative>>(
      llama_dart_state_seq_get_data_ext,
    ),
  'llama_dart_state_seq_set_data_ext' =>
    Native.addressOf<NativeFunction<_StateSeqDataNative>>(
      llama_dart_state_seq_set_data_ext,
    ),
  'llama_dart_adapter_lora_init' =>
    Native.addressOf<NativeFunction<_AdapterLoraInitNative>>(
      llama_dart_adapter_lora_init,
    ),
  'llama_dart_mtmd_tokenize' =>
    Native.addressOf<NativeFunction<_MtmdTokenizeNative>>(
      llama_dart_mtmd_tokenize,
    ),
  'llama_dart_mtmd_encode_chunk' =>
    Native.addressOf<NativeFunction<_MtmdEncodeChunkNative>>(
      llama_dart_mtmd_encode_chunk,
    ),
  'llama_dart_mtmd_helper_eval_chunks' =>
    Native.addressOf<NativeFunction<_MtmdEvalChunksNative>>(
      llama_dart_mtmd_helper_eval_chunks,
    ),
  'llama_dart_mtmd_helper_eval_chunk_single' =>
    Native.addressOf<NativeFunction<_MtmdEvalChunkSingleNative>>(
      llama_dart_mtmd_helper_eval_chunk_single,
    ),
  'llama_dart_mtmd_helper_decode_image_chunk' =>
    Native.addressOf<NativeFunction<_MtmdDecodeImageChunkNative>>(
      llama_dart_mtmd_helper_decode_image_chunk,
    ),
  'llama_dart_ggml_backend_sched_graph_compute' =>
    Native.addressOf<NativeFunction<_SchedGraphComputeNative>>(
      _schedGraphCompute,
    ),
  _ => throw ArgumentError.value(symbol, 'symbol', 'not bound'),
};

Pointer<NativeType> _wrapperAssetSymbol(String symbol) => switch (symbol) {
  'llama_dart_exit_track' => Native.addressOf<NativeFunction<_TrackNative>>(
    _wrapperTrack,
  ),
  'llama_dart_exit_untrack' => Native.addressOf<NativeFunction<_UntrackNative>>(
    _wrapperUntrack,
  ),
  'llama_dart_exit_free' => Native.addressOf<NativeFunction<_FreeNative>>(
    _wrapperFree,
  ),
  'llama_dart_model_load_from_file' =>
    Native.addressOf<NativeFunction<_ModelLoadNative>>(_wrapperModelLoad),
  'llama_dart_init_from_model' =>
    Native.addressOf<NativeFunction<_InitFromModelNative>>(
      _wrapperInitFromModel,
    ),
  'llama_dart_mtmd_init_from_file' =>
    Native.addressOf<NativeFunction<_MtmdInitNative>>(_wrapperMtmdInit),
  'llama_dart_decode' => Native.addressOf<NativeFunction<_DecodeNative>>(
    _wrapperDecode,
  ),
  'llama_dart_encode' => Native.addressOf<NativeFunction<_DecodeNative>>(
    _wrapperEncode,
  ),
  'llama_dart_synchronize' =>
    Native.addressOf<NativeFunction<_SynchronizeNative>>(_wrapperSynchronize),
  'llama_dart_sampler_sample' =>
    Native.addressOf<NativeFunction<_SamplerSampleNative>>(
      _wrapperSamplerSample,
    ),
  'llama_dart_state_save_file' =>
    Native.addressOf<NativeFunction<_StateSaveFileNative>>(
      _wrapperStateSaveFile,
    ),
  'llama_dart_state_load_file' =>
    Native.addressOf<NativeFunction<_StateLoadFileNative>>(
      _wrapperStateLoadFile,
    ),
  'llama_dart_state_seq_get_size_ext' =>
    Native.addressOf<NativeFunction<_StateSeqSizeNative>>(
      _wrapperStateSeqGetSizeExt,
    ),
  'llama_dart_state_seq_get_data_ext' =>
    Native.addressOf<NativeFunction<_StateSeqDataNative>>(
      _wrapperStateSeqGetDataExt,
    ),
  'llama_dart_state_seq_set_data_ext' =>
    Native.addressOf<NativeFunction<_StateSeqDataNative>>(
      _wrapperStateSeqSetDataExt,
    ),
  'llama_dart_adapter_lora_init' =>
    Native.addressOf<NativeFunction<_AdapterLoraInitNative>>(
      _wrapperAdapterLoraInit,
    ),
  'llama_dart_mtmd_tokenize' =>
    Native.addressOf<NativeFunction<_MtmdTokenizeNative>>(_wrapperMtmdTokenize),
  'llama_dart_mtmd_encode_chunk' =>
    Native.addressOf<NativeFunction<_MtmdEncodeChunkNative>>(
      _wrapperMtmdEncodeChunk,
    ),
  'llama_dart_mtmd_helper_eval_chunks' =>
    Native.addressOf<NativeFunction<_MtmdEvalChunksNative>>(
      _wrapperMtmdEvalChunks,
    ),
  'llama_dart_mtmd_helper_eval_chunk_single' =>
    Native.addressOf<NativeFunction<_MtmdEvalChunkSingleNative>>(
      _wrapperMtmdEvalChunkSingle,
    ),
  'llama_dart_mtmd_helper_decode_image_chunk' =>
    Native.addressOf<NativeFunction<_MtmdDecodeImageChunkNative>>(
      _wrapperMtmdDecodeImageChunk,
    ),
  'llama_dart_ggml_backend_sched_graph_compute' =>
    Native.addressOf<NativeFunction<_SchedGraphComputeNative>>(
      _wrapperSchedGraphCompute,
    ),
  _ => throw ArgumentError.value(symbol, 'symbol', 'not bound'),
};

// The generated binding converts the result to a `ggml_status`, which throws
// for a value this package does not know.
@Native<_SchedGraphComputeNative>(
  assetId: _llamadartAsset,
  symbol: 'llama_dart_ggml_backend_sched_graph_compute',
)
external int _schedGraphCompute(
  ggml_backend_sched_t sched,
  Pointer<ggml_cgraph> graph,
);

@Native<_TrackNative>(assetId: _wrapperAsset, symbol: 'llama_dart_exit_track')
external bool _wrapperTrack(
  Pointer<Void> object,
  Pointer<NativeFunction<_FreeNative>> free,
  int stage,
);

@Native<_FreeNative>(assetId: _wrapperAsset, symbol: 'llama_dart_exit_free')
external void _wrapperFree(Pointer<Void> object);

@Native<_UntrackNative>(
  assetId: _wrapperAsset,
  symbol: 'llama_dart_exit_untrack',
)
external bool _wrapperUntrack(Pointer<Void> object);

@Native<_ModelLoadNative>(
  assetId: _wrapperAsset,
  symbol: 'llama_dart_model_load_from_file',
)
external Pointer<llama_model> _wrapperModelLoad(
  Pointer<Char> path,
  llama_model_params params,
);

@Native<_InitFromModelNative>(
  assetId: _wrapperAsset,
  symbol: 'llama_dart_init_from_model',
)
external Pointer<llama_context> _wrapperInitFromModel(
  Pointer<llama_model> model,
  llama_context_params params,
);

@Native<_MtmdInitNative>(
  assetId: _wrapperAsset,
  symbol: 'llama_dart_mtmd_init_from_file',
)
external Pointer<mtmd_context> _wrapperMtmdInit(
  Pointer<Char> path,
  Pointer<llama_model> model,
  Pointer<mtmd_context_params> params,
);

@Native<_DecodeNative>(assetId: _wrapperAsset, symbol: 'llama_dart_decode')
external int _wrapperDecode(Pointer<llama_context> ctx, llama_batch batch);

@Native<_DecodeNative>(assetId: _wrapperAsset, symbol: 'llama_dart_encode')
external int _wrapperEncode(Pointer<llama_context> ctx, llama_batch batch);

@Native<_SynchronizeNative>(
  assetId: _wrapperAsset,
  symbol: 'llama_dart_synchronize',
)
external void _wrapperSynchronize(Pointer<llama_context> ctx);

@Native<_SamplerSampleNative>(
  assetId: _wrapperAsset,
  symbol: 'llama_dart_sampler_sample',
)
external int _wrapperSamplerSample(
  Pointer<llama_sampler> sampler,
  Pointer<llama_context> ctx,
  int index,
);

@Native<_StateSaveFileNative>(
  assetId: _wrapperAsset,
  symbol: 'llama_dart_state_save_file',
)
external bool _wrapperStateSaveFile(
  Pointer<llama_context> ctx,
  Pointer<Char> path,
  Pointer<llama_token> tokens,
  int tokenCount,
);

@Native<_StateLoadFileNative>(
  assetId: _wrapperAsset,
  symbol: 'llama_dart_state_load_file',
)
external bool _wrapperStateLoadFile(
  Pointer<llama_context> ctx,
  Pointer<Char> path,
  Pointer<llama_token> tokensOut,
  int tokenCapacity,
  Pointer<Size> tokenCountOut,
);

@Native<_StateSeqSizeNative>(
  assetId: _wrapperAsset,
  symbol: 'llama_dart_state_seq_get_size_ext',
)
external int _wrapperStateSeqGetSizeExt(
  Pointer<llama_context> ctx,
  int seqId,
  int flags,
);

@Native<_StateSeqDataNative>(
  assetId: _wrapperAsset,
  symbol: 'llama_dart_state_seq_get_data_ext',
)
external int _wrapperStateSeqGetDataExt(
  Pointer<llama_context> ctx,
  Pointer<Uint8> dst,
  int size,
  int seqId,
  int flags,
);

@Native<_StateSeqDataNative>(
  assetId: _wrapperAsset,
  symbol: 'llama_dart_state_seq_set_data_ext',
)
external int _wrapperStateSeqSetDataExt(
  Pointer<llama_context> ctx,
  Pointer<Uint8> src,
  int size,
  int seqId,
  int flags,
);

@Native<_AdapterLoraInitNative>(
  assetId: _wrapperAsset,
  symbol: 'llama_dart_adapter_lora_init',
)
external Pointer<llama_adapter_lora> _wrapperAdapterLoraInit(
  Pointer<llama_model> model,
  Pointer<Char> path,
);

@Native<_MtmdTokenizeNative>(
  assetId: _wrapperAsset,
  symbol: 'llama_dart_mtmd_tokenize',
)
external int _wrapperMtmdTokenize(
  Pointer<mtmd_context> ctx,
  Pointer<mtmd_input_chunks> output,
  Pointer<mtmd_input_text> text,
  Pointer<Pointer<mtmd_bitmap>> bitmaps,
  int bitmapCount,
);

@Native<_MtmdEncodeChunkNative>(
  assetId: _wrapperAsset,
  symbol: 'llama_dart_mtmd_encode_chunk',
)
external int _wrapperMtmdEncodeChunk(
  Pointer<mtmd_context> ctx,
  Pointer<mtmd_input_chunk> chunk,
);

@Native<_MtmdEvalChunksNative>(
  assetId: _wrapperAsset,
  symbol: 'llama_dart_mtmd_helper_eval_chunks',
)
external int _wrapperMtmdEvalChunks(
  Pointer<mtmd_context> ctx,
  Pointer<llama_context> lctx,
  Pointer<mtmd_input_chunks> chunks,
  int nPast,
  int seqId,
  int nBatch,
  bool logitsLast,
  Pointer<llama_pos> newNPast,
);

@Native<_MtmdEvalChunkSingleNative>(
  assetId: _wrapperAsset,
  symbol: 'llama_dart_mtmd_helper_eval_chunk_single',
)
external int _wrapperMtmdEvalChunkSingle(
  Pointer<mtmd_context> ctx,
  Pointer<llama_context> lctx,
  Pointer<mtmd_input_chunk> chunk,
  int nPast,
  int seqId,
  int nBatch,
  bool logitsLast,
  Pointer<llama_pos> newNPast,
);

@Native<_MtmdDecodeImageChunkNative>(
  assetId: _wrapperAsset,
  symbol: 'llama_dart_mtmd_helper_decode_image_chunk',
)
external int _wrapperMtmdDecodeImageChunk(
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
);

@Native<_SchedGraphComputeNative>(
  assetId: _wrapperAsset,
  symbol: 'llama_dart_ggml_backend_sched_graph_compute',
)
external int _wrapperSchedGraphCompute(
  ggml_backend_sched_t sched,
  Pointer<ggml_cgraph> graph,
);
