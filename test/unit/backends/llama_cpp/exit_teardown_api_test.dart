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
