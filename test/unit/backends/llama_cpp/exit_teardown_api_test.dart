@TestOn('vm')
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:llamadart/src/backends/isolate_shutdown_releases.dart';
import 'package:llamadart/src/backends/llama_cpp/bindings.dart';
import 'package:llamadart/src/backends/llama_cpp/exit_teardown_api.dart';
import 'package:llamadart/src/backends/llama_cpp/llama_cpp_service.dart';
import 'package:test/test.dart';

import '../../../support/synthetic_embedding_gguf.dart';

// The exports a service on the tracked calls depends on.
const _symbols = [
  'llama_dart_exit_track',
  'llama_dart_exit_untrack',
  'llama_dart_exit_free',
  'llama_dart_model_load_from_file',
  'llama_dart_init_from_model',
  'llama_dart_mtmd_init_from_file',
  'llama_dart_decode',
  'llama_dart_encode',
  'llama_dart_synchronize',
  'llama_dart_sampler_sample',
  'llama_dart_state_save_file',
  'llama_dart_state_load_file',
  'llama_dart_state_seq_get_size_ext',
  'llama_dart_state_seq_get_data_ext',
  'llama_dart_state_seq_set_data_ext',
  'llama_dart_adapter_lora_init',
  'llama_dart_mtmd_tokenize',
  'llama_dart_mtmd_encode_chunk',
  'llama_dart_mtmd_helper_eval_chunks',
  'llama_dart_mtmd_helper_eval_chunk_single',
  'llama_dart_mtmd_helper_decode_image_chunk',
  'llama_dart_ggml_backend_sched_graph_compute',
];

// Runs the real llama.cpp runtime on the CPU.
void main() {
  late Directory dir;
  late String modelPath;

  setUpAll(() => LlamaCppService().initializeBackend());

  setUp(() {
    dir = Directory.systemTemp.createTempSync('llamadart_exit_teardown_');
    modelPath = writeSyntheticLlamaGguf('${dir.path}/model.gguf').path;
  });

  tearDown(() => dir.deleteSync(recursive: true));

  ExitTeardownApi resolved() =>
      ExitTeardownApi.tryResolve(isWindows: Platform.isWindows)!;

  Pointer<llama_model> load(LlamaCppObjectCalls calls) {
    final path = modelPath.toNativeUtf8();
    try {
      final params = llama_model_default_params()..n_gpu_layers = 0;
      final model = calls.loadModel(path.cast(), params);
      expect(model, isNot(nullptr));
      return model;
    } finally {
      malloc.free(path);
    }
  }

  test('maps each shutdown stage to the llama_dart_exit_stage teardown frees '
      'in that order', () {
    expect(
      [for (final stage in ShutdownStage.values) exitStageValue(stage)],
      [0, 1, 2, 3, 4, 5],
    );
  });

  test('resolves from the pinned runtime', () {
    expect(
      ExitTeardownApi.tryResolve(isWindows: Platform.isWindows),
      isNotNull,
    );
    expect(
      LlamaCppObjectCalls.resolve(isWindows: Platform.isWindows).exit,
      isNotNull,
    );
  });

  test('binds every function through the lookup, and resolves none when one '
      'is missing', () {
    final requested = <String>[];
    Pointer<NativeType> exported(String name) {
      requested.add(name);
      return Pointer.fromAddress(0x1000 + requested.length);
    }

    expect(
      ExitTeardownApi.tryResolve(isWindows: false, symbol: exported),
      isNotNull,
    );
    expect(requested, unorderedEquals(_symbols));

    for (final missing in _symbols) {
      expect(
        ExitTeardownApi.tryResolve(
          isWindows: false,
          symbol: (name) => name == missing
              ? throw ArgumentError("Couldn't resolve native function '$name'")
              : exported(name),
        ),
        isNull,
        reason: missing,
      );
    }
  });

  test('calls the function exported under the name of each of its '
      'members', () {
    final exports = _RecordingExports();
    addTearDown(exports.close);
    final api = ExitTeardownApi.tryResolve(
      isWindows: false,
      symbol: exports.symbol,
    )!;
    final batch = llama_batch_init(1, 0, 1);
    addTearDown(() => llama_batch_free(batch));

    final members = <String, void Function()>{
      'llama_dart_exit_track': () => api.track(nullptr, nullptr, 0),
      'llama_dart_exit_untrack': () => api.untrack(nullptr),
      'llama_dart_exit_free': () => api.free(nullptr),
      'llama_dart_model_load_from_file': () =>
          api.modelLoadFromFile(nullptr, llama_model_default_params()),
      'llama_dart_init_from_model': () =>
          api.initFromModel(nullptr, llama_context_default_params()),
      'llama_dart_mtmd_init_from_file': () =>
          api.mtmdInitFromFile(nullptr, nullptr, nullptr),
      'llama_dart_decode': () => api.decode(nullptr, batch),
      'llama_dart_encode': () => api.encode(nullptr, batch),
      'llama_dart_synchronize': () => api.synchronize(nullptr),
      'llama_dart_sampler_sample': () => api.samplerSample(nullptr, nullptr, 0),
      'llama_dart_state_save_file': () =>
          api.stateSaveFile(nullptr, nullptr, nullptr, 0),
      'llama_dart_state_load_file': () =>
          api.stateLoadFile(nullptr, nullptr, nullptr, 0, nullptr),
      'llama_dart_state_seq_get_size_ext': () =>
          api.stateSeqGetSizeExt(nullptr, 0, 0),
      'llama_dart_state_seq_get_data_ext': () =>
          api.stateSeqGetDataExt(nullptr, nullptr, 0, 0, 0),
      'llama_dart_state_seq_set_data_ext': () =>
          api.stateSeqSetDataExt(nullptr, nullptr, 0, 0, 0),
      'llama_dart_adapter_lora_init': () =>
          api.adapterLoraInit(nullptr, nullptr),
      'llama_dart_mtmd_tokenize': () =>
          api.mtmdTokenize(nullptr, nullptr, nullptr, nullptr, 0),
      'llama_dart_mtmd_encode_chunk': () =>
          api.mtmdEncodeChunk(nullptr, nullptr),
      'llama_dart_mtmd_helper_eval_chunks': () => api.mtmdHelperEvalChunks(
        nullptr,
        nullptr,
        nullptr,
        0,
        0,
        0,
        false,
        nullptr,
      ),
      'llama_dart_mtmd_helper_eval_chunk_single': () =>
          api.mtmdHelperEvalChunkSingle(
            nullptr,
            nullptr,
            nullptr,
            0,
            0,
            0,
            false,
            nullptr,
          ),
      'llama_dart_mtmd_helper_decode_image_chunk': () =>
          api.mtmdHelperDecodeImageChunk(
            nullptr,
            nullptr,
            nullptr,
            nullptr,
            0,
            0,
            0,
            nullptr,
            nullptr,
            nullptr,
          ),
      'llama_dart_ggml_backend_sched_graph_compute': () =>
          api.schedGraphCompute(nullptr, nullptr),
    };
    expect(members.keys, unorderedEquals(_symbols));
    for (final MapEntry(key: name, value: call) in members.entries) {
      exports.called.clear();
      call();
      expect(exports.called, [name]);
    }
    expect(
      api.freeAddress.address,
      exports.symbol('llama_dart_exit_free').address,
    );
  });

  test('tracked calls use the exit API for every call', () {
    final exports = _RecordingExports();
    addTearDown(exports.close);
    final api = ExitTeardownApi.tryResolve(
      isWindows: false,
      symbol: exports.symbol,
    )!;
    final calls = LlamaCppObjectCalls.tracked(api);

    expect(calls.loadModel, same(api.modelLoadFromFile));
    expect(calls.createContext, same(api.initFromModel));
    expect(calls.decode, same(api.decode));
    expect(calls.encode, same(api.encode));
    expect(calls.synchronize, same(api.synchronize));
    expect(calls.samplerSample, same(api.samplerSample));
    expect(calls.stateSaveFile, same(api.stateSaveFile));
    expect(calls.stateLoadFile, same(api.stateLoadFile));
    expect(calls.stateSeqGetSizeExt, same(api.stateSeqGetSizeExt));
    expect(calls.stateSeqGetDataExt, same(api.stateSeqGetDataExt));
    expect(calls.stateSeqSetDataExt, same(api.stateSeqSetDataExt));
    expect(calls.adapterLoraInit, same(api.adapterLoraInit));
    calls.freeModel(nullptr);
    calls.freeContext(nullptr);
    expect(exports.called, ['llama_dart_exit_free', 'llama_dart_exit_free']);
  });

  test('frees a tracked object once, with the function it was tracked '
      'with', () {
    final exit = resolved();
    final freed = <int>[];
    final free = NativeCallable<Void Function(Pointer<Void>)>.isolateLocal(
      (Pointer<Void> object) => freed.add(object.address),
    );
    addTearDown(free.close);
    final object = malloc<Int32>();
    addTearDown(() => malloc.free(object));

    expect(
      exit.track(
        object.cast(),
        free.nativeFunction,
        exitStageValue(ShutdownStage.modelUser),
      ),
      isTrue,
    );
    exit.free(object.cast());
    exit.free(object.cast());

    expect(freed, [object.address]);
    expect(exit.untrack(object.cast()), isFalse);
  });

  test('tracked calls create objects the runtime tracks and frees', () {
    final exit = resolved();
    final calls = LlamaCppObjectCalls.tracked(exit);
    expect(calls.modelFreeAddress, exit.freeAddress);
    expect(calls.contextFreeAddress, exit.freeAddress);

    final model = load(calls);
    final context = calls.createContext(
      model,
      llama_context_default_params()..n_ctx = 64,
    );
    expect(context, isNot(nullptr));
    final batch = llama_batch_init(2, 0, 1);
    try {
      batch.n_tokens = 2;
      for (var i = 0; i < 2; i++) {
        batch.token[i] = 1 + i;
        batch.pos[i] = i;
        batch.n_seq_id[i] = 1;
        batch.seq_id[i][0] = 0;
        batch.logits[i] = i;
      }
      expect(calls.decode(context, batch), 0);
      calls.synchronize(context);
    } finally {
      llama_batch_free(batch);
    }

    calls.freeContext(context);
    expect(exit.untrack(context.cast()), isFalse);
    // Untracking shows the load tracked the model; the upstream free then
    // releases what the tracked free no longer knows.
    expect(exit.untrack(model.cast()), isTrue);
    llama_model_free(model);
  });

  test('upstream calls create objects the runtime does not track', () {
    final calls = LlamaCppObjectCalls.upstream;
    expect(calls.exit, isNull);
    expect(
      calls.modelFreeAddress.address,
      Native.addressOf<NativeFunction<Void Function(Pointer<llama_model>)>>(
        llama_model_free,
      ).address,
    );
    expect(
      calls.contextFreeAddress.address,
      Native.addressOf<NativeFunction<Void Function(Pointer<llama_context>)>>(
        llama_free,
      ).address,
    );

    final model = load(calls);
    final context = calls.createContext(
      model,
      llama_context_default_params()..n_ctx = 64,
    );
    expect(context, isNot(nullptr));
    final exit = resolved();
    expect(exit.untrack(context.cast()), isFalse);
    expect(exit.untrack(model.cast()), isFalse);
    calls.freeContext(context);
    calls.freeModel(model);
  });
}

/// Stands in for a runtime's exports: one native function per name, each of
/// which records its name in [called] and returns zero.
final class _RecordingExports {
  final List<String> called = <String>[];

  late final Map<String, NativeCallable<Function>> _functions = {
    'llama_dart_exit_track':
        NativeCallable<
          Bool Function(
            Pointer<Void>,
            Pointer<NativeFunction<Void Function(Pointer<Void>)>>,
            Int32,
          )
        >.isolateLocal(
          (Pointer<Void> _, Pointer<NativeType> _, int _) =>
              _record('llama_dart_exit_track', false),
          exceptionalReturn: false,
        ),
    'llama_dart_exit_untrack':
        NativeCallable<Bool Function(Pointer<Void>)>.isolateLocal(
          (Pointer<Void> _) => _record('llama_dart_exit_untrack', false),
          exceptionalReturn: false,
        ),
    'llama_dart_exit_free':
        NativeCallable<Void Function(Pointer<Void>)>.isolateLocal(
          (Pointer<Void> _) => _record('llama_dart_exit_free', null),
        ),
    'llama_dart_model_load_from_file':
        NativeCallable<
          Pointer<llama_model> Function(Pointer<Char>, llama_model_params)
        >.isolateLocal(
          (Pointer<Char> _, llama_model_params _) => _record(
            'llama_dart_model_load_from_file',
            nullptr.cast<llama_model>(),
          ),
        ),
    'llama_dart_init_from_model':
        NativeCallable<
          Pointer<llama_context> Function(
            Pointer<llama_model>,
            llama_context_params,
          )
        >.isolateLocal(
          (Pointer<llama_model> _, llama_context_params _) => _record(
            'llama_dart_init_from_model',
            nullptr.cast<llama_context>(),
          ),
        ),
    'llama_dart_mtmd_init_from_file':
        NativeCallable<
          Pointer<mtmd_context> Function(
            Pointer<Char>,
            Pointer<llama_model>,
            Pointer<mtmd_context_params>,
          )
        >.isolateLocal(
          (
            Pointer<Char> _,
            Pointer<llama_model> _,
            Pointer<mtmd_context_params> _,
          ) => _record(
            'llama_dart_mtmd_init_from_file',
            nullptr.cast<mtmd_context>(),
          ),
        ),
    for (final name in ['llama_dart_decode', 'llama_dart_encode'])
      name:
          NativeCallable<
            Int32 Function(Pointer<llama_context>, llama_batch)
          >.isolateLocal(
            (Pointer<llama_context> _, llama_batch _) => _record(name, 0),
            exceptionalReturn: 0,
          ),
    'llama_dart_synchronize':
        NativeCallable<Void Function(Pointer<llama_context>)>.isolateLocal(
          (Pointer<llama_context> _) => _record('llama_dart_synchronize', null),
        ),
    'llama_dart_sampler_sample':
        NativeCallable<
          Int32 Function(Pointer<llama_sampler>, Pointer<llama_context>, Int32)
        >.isolateLocal(
          (Pointer<llama_sampler> _, Pointer<llama_context> _, int _) =>
              _record('llama_dart_sampler_sample', 0),
          exceptionalReturn: 0,
        ),
    'llama_dart_state_save_file':
        NativeCallable<
          Bool Function(
            Pointer<llama_context>,
            Pointer<Char>,
            Pointer<Int32>,
            Size,
          )
        >.isolateLocal(
          (
            Pointer<llama_context> _,
            Pointer<Char> _,
            Pointer<Int32> _,
            int _,
          ) => _record('llama_dart_state_save_file', false),
          exceptionalReturn: false,
        ),
    'llama_dart_state_load_file':
        NativeCallable<
          Bool Function(
            Pointer<llama_context>,
            Pointer<Char>,
            Pointer<Int32>,
            Size,
            Pointer<Size>,
          )
        >.isolateLocal(
          (
            Pointer<llama_context> _,
            Pointer<Char> _,
            Pointer<Int32> _,
            int _,
            Pointer<Size> _,
          ) => _record('llama_dart_state_load_file', false),
          exceptionalReturn: false,
        ),
    'llama_dart_state_seq_get_size_ext':
        NativeCallable<
          Size Function(Pointer<llama_context>, Int32, Uint32)
        >.isolateLocal(
          (Pointer<llama_context> _, int _, int _) =>
              _record('llama_dart_state_seq_get_size_ext', 0),
          exceptionalReturn: 0,
        ),
    for (final name in [
      'llama_dart_state_seq_get_data_ext',
      'llama_dart_state_seq_set_data_ext',
    ])
      name:
          NativeCallable<
            Size Function(
              Pointer<llama_context>,
              Pointer<Uint8>,
              Size,
              Int32,
              Uint32,
            )
          >.isolateLocal(
            (Pointer<llama_context> _, Pointer<Uint8> _, int _, int _, int _) =>
                _record(name, 0),
            exceptionalReturn: 0,
          ),
    'llama_dart_adapter_lora_init':
        NativeCallable<
          Pointer<llama_adapter_lora> Function(
            Pointer<llama_model>,
            Pointer<Char>,
          )
        >.isolateLocal(
          (Pointer<llama_model> _, Pointer<Char> _) => _record(
            'llama_dart_adapter_lora_init',
            nullptr.cast<llama_adapter_lora>(),
          ),
        ),
    'llama_dart_mtmd_tokenize':
        NativeCallable<
          Int32 Function(
            Pointer<mtmd_context>,
            Pointer<mtmd_input_chunks>,
            Pointer<mtmd_input_text>,
            Pointer<Pointer<mtmd_bitmap>>,
            Size,
          )
        >.isolateLocal(
          (
            Pointer<mtmd_context> _,
            Pointer<mtmd_input_chunks> _,
            Pointer<mtmd_input_text> _,
            Pointer<Pointer<mtmd_bitmap>> _,
            int _,
          ) => _record('llama_dart_mtmd_tokenize', 0),
          exceptionalReturn: 0,
        ),
    'llama_dart_mtmd_encode_chunk':
        NativeCallable<
          Int32 Function(Pointer<mtmd_context>, Pointer<mtmd_input_chunk>)
        >.isolateLocal(
          (Pointer<mtmd_context> _, Pointer<mtmd_input_chunk> _) =>
              _record('llama_dart_mtmd_encode_chunk', 0),
          exceptionalReturn: 0,
        ),
    'llama_dart_mtmd_helper_eval_chunks':
        NativeCallable<
          Int32 Function(
            Pointer<mtmd_context>,
            Pointer<llama_context>,
            Pointer<mtmd_input_chunks>,
            Int32,
            Int32,
            Int32,
            Bool,
            Pointer<Int32>,
          )
        >.isolateLocal(
          (
            Pointer<mtmd_context> _,
            Pointer<llama_context> _,
            Pointer<mtmd_input_chunks> _,
            int _,
            int _,
            int _,
            bool _,
            Pointer<Int32> _,
          ) => _record('llama_dart_mtmd_helper_eval_chunks', 0),
          exceptionalReturn: 0,
        ),
    'llama_dart_mtmd_helper_eval_chunk_single':
        NativeCallable<
          Int32 Function(
            Pointer<mtmd_context>,
            Pointer<llama_context>,
            Pointer<mtmd_input_chunk>,
            Int32,
            Int32,
            Int32,
            Bool,
            Pointer<Int32>,
          )
        >.isolateLocal(
          (
            Pointer<mtmd_context> _,
            Pointer<llama_context> _,
            Pointer<mtmd_input_chunk> _,
            int _,
            int _,
            int _,
            bool _,
            Pointer<Int32> _,
          ) => _record('llama_dart_mtmd_helper_eval_chunk_single', 0),
          exceptionalReturn: 0,
        ),
    'llama_dart_mtmd_helper_decode_image_chunk':
        NativeCallable<
          Int32 Function(
            Pointer<mtmd_context>,
            Pointer<llama_context>,
            Pointer<mtmd_input_chunk>,
            Pointer<Float>,
            Int32,
            Int32,
            Int32,
            Pointer<Int32>,
            mtmd_helper_post_decode_callback,
            Pointer<Void>,
          )
        >.isolateLocal(
          (
            Pointer<mtmd_context> _,
            Pointer<llama_context> _,
            Pointer<mtmd_input_chunk> _,
            Pointer<Float> _,
            int _,
            int _,
            int _,
            Pointer<Int32> _,
            mtmd_helper_post_decode_callback _,
            Pointer<Void> _,
          ) => _record('llama_dart_mtmd_helper_decode_image_chunk', 0),
          exceptionalReturn: 0,
        ),
    'llama_dart_ggml_backend_sched_graph_compute':
        NativeCallable<
          Int Function(ggml_backend_sched_t, Pointer<ggml_cgraph>)
        >.isolateLocal(
          (ggml_backend_sched_t _, Pointer<ggml_cgraph> _) =>
              _record('llama_dart_ggml_backend_sched_graph_compute', 0),
          exceptionalReturn: 0,
        ),
  };

  T _record<T>(String name, T result) {
    called.add(name);
    return result;
  }

  /// The address of the function exported as [name].
  Pointer<NativeType> symbol(String name) => _functions[name]!.nativeFunction;

  void close() {
    for (final function in _functions.values) {
      function.close();
    }
  }
}
