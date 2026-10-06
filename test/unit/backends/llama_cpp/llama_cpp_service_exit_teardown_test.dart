@TestOn('vm')
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:llamadart/src/backends/backend.dart';
import 'package:llamadart/src/backends/llama_cpp/exit_teardown_api.dart';
import 'package:llamadart/src/backends/llama_cpp/llama_cpp_service.dart';
import 'package:llamadart/src/core/decision/decision_question.dart';
import 'package:llamadart/src/core/exceptions.dart';
import 'package:llamadart/src/core/models/chat/content_part.dart';
import 'package:llamadart/src/core/models/inference/generation_params.dart';
import 'package:llamadart/src/core/models/inference/model_params.dart';
import 'package:test/test.dart';

import '../../../support/fake_mtmd.dart';
import '../../../support/recording_exit_teardown.dart';
import '../../../support/synthetic_decision_head.dart';
import '../../../support/synthetic_embedding_gguf.dart';

const _params = ModelParams(gpuLayers: 0, contextSize: 64);
const _greedy = GenerationParams(maxTokens: 4, temp: 0, topK: 1, seed: 1);

// Runs the real llama.cpp runtime on the CPU. A service on the tracked calls
// has to make every call that exit teardown waits for through its
// ExitTeardownApi: an upstream call on a tracked object can be freed under.
void main() {
  late Directory dir;
  late RecordingExitTeardown recorder;
  // The fake libmtmd whose media prompt the recorder's eval functions run.
  FakeMtmd? mtmd;
  late LlamaCppService service;
  late int model;
  late int context;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('llamadart_exit_calls_');
    addTearDown(() => dir.deleteSync(recursive: true));
    writeSyntheticLlamaGguf('${dir.path}/model.gguf');
    mtmd = null;
    recorder = RecordingExitTeardown(
      ExitTeardownApi.tryResolve(isWindows: Platform.isWindows)!,
      evalMedia: (context, nPast, nBatch, newNPast) =>
          mtmd!.evalMedia(context, nPast, nBatch, newNPast),
    );
    service = LlamaCppService(
      objectCalls: LlamaCppObjectCalls.tracked(recorder.api),
    )..initializeBackend();
    addTearDown(service.dispose);
    model = service.loadModel('${dir.path}/model.gguf', _params);
    context = service.createContext(model, _params);
  });

  test('creates and frees models and contexts through it', () {
    expect(recorder.calls, [
      'llama_dart_model_load_from_file',
      'llama_dart_init_from_model',
    ]);

    service.freeContext(context);
    service.freeModel(model);

    expect(recorder.freed, hasLength(2));
  });

  test('generates through its decode and sample', () async {
    recorder.calls.clear();

    await _generate(service, context, 'ab', _greedy);

    expect(
      recorder.calls.toSet(),
      containsAll(['llama_dart_decode', 'llama_dart_sampler_sample']),
    );
  });

  test('checkpoints a speculative draft through its sequence state', () async {
    recorder.calls.clear();

    await _generate(
      service,
      context,
      'abababababababab',
      _greedy.copyWith(
        maxTokens: 40,
        penalty: 1,
        speculativeDecodingConfig: const SpeculativeDecodingConfig.ngramSimple(
          ngramSizeN: 1,
          ngramSizeM: 4,
          ngramMinHits: 1,
        ),
      ),
    );

    expect(
      recorder.calls.toSet(),
      containsAll([
        'llama_dart_state_seq_get_size_ext',
        'llama_dart_state_seq_get_data_ext',
      ]),
      reason: 'the n-gram draft that makes the service checkpoint',
    );
  });

  test('embeds through its decode', () {
    recorder.calls.clear();

    expect(service.embed(context, 'exit teardown'), isNotEmpty);

    expect(
      recorder.calls.toSet(),
      containsAll(['llama_dart_synchronize', 'llama_dart_decode']),
    );
  });

  test('saves and loads state through it', () {
    final path = '${dir.path}/state.bin';
    recorder.calls.clear();

    expect(service.stateSaveFile(context, path, [1, 2]), isTrue);
    expect(service.stateLoadFile(context, path, 8), [1, 2]);

    expect(
      recorder.calls.toSet(),
      containsAll([
        'llama_dart_synchronize',
        'llama_dart_state_save_file',
        'llama_dart_state_load_file',
      ]),
    );
  });

  test('loads a LoRA adapter through it', () {
    final path = '${dir.path}/adapter.gguf';
    File(path).writeAsStringSync('not an adapter');
    recorder.calls.clear();

    expect(
      () => service.handleLora(context, path, 1, 'set'),
      throwsA(isA<LlamaModelException>()),
    );

    expect(recorder.calls, contains('llama_dart_adapter_lora_init'));
  });

  test('tracks, runs and frees a decision head through it', () {
    writeSyntheticModernBertGguf(
      '${dir.path}/encoder.gguf',
      decisionTokens: true,
    );
    SyntheticDecisionHead(
      d: 16,
      layers: 1,
      seed: 1,
    ).write('${dir.path}/head.safetensors');
    File(
      '${dir.path}/config.json',
    ).writeAsStringSync('{"max_len": 64, "head_layers": 1}');
    final encoder = service.loadModel('${dir.path}/encoder.gguf', _params);
    recorder.calls.clear();

    final head = service
        .loadDecisionHead(
          encoder,
          '${dir.path}/head.safetensors',
          '${dir.path}/config.json',
        )
        .handle;
    // The CPU backend, the weights buffer and the scheduler.
    expect(
      recorder.calls.where((call) => call == 'llama_dart_exit_track'),
      hasLength(3),
    );
    expect(recorder.calls, contains('llama_dart_init_from_model'));

    recorder.calls.clear();
    service.runDecision(head, [
      BackendDecisionSequence(
        tokens: Int32List.fromList([1, 5, 0, 6, 0, 2]),
        markers: Int32List.fromList([2, 4]),
        questionType: DecisionQuestionType.choice,
      ),
    ]);
    expect(recorder.calls, [
      'llama_dart_encode',
      'llama_dart_ggml_backend_sched_graph_compute',
    ]);

    recorder.freed.clear();
    service.freeDecisionHead(head);
    // Those three objects and the head's encoder context.
    expect(recorder.freed, hasLength(4));
  });

  for (final chunkEval in [true, false]) {
    final evalCall = chunkEval
        ? 'mtmd_helper_eval_chunk_single'
        : 'mtmd_helper_eval_chunks';

    test('creates, evaluates and frees a projector through it '
        '(chunk-level eval: $chunkEval)', () async {
      final projectorPath = '${dir.path}/mmproj.gguf';
      File(projectorPath).writeAsStringSync('GGUF');
      final fake = mtmd = FakeMtmd.install(
        service,
        tokens: service.tokenize(model, 'ab', true),
        chunkEval: chunkEval,
        decode: recorder.real.decode,
      );
      addTearDown(fake.dispose);
      recorder.calls.clear();
      recorder.freed.clear();

      final projector = service.createMultimodalContext(model, projectorPath);
      await _generate(
        service,
        context,
        '<__media__>',
        _greedy,
        parts: fake.parts,
      );
      service.freeMultimodalContext(projector);

      expect(
        recorder.calls,
        containsAllInOrder([
          'llama_dart_mtmd_init_from_file',
          'llama_dart_mtmd_tokenize',
          'llama_dart_$evalCall',
        ]),
      );
      expect(recorder.freed, [RecordingExitTeardown.projector.address]);
      expect(fake.calls, isEmpty);
      expect(fake.evaluations, 1);
    });

    test('creates, evaluates and frees a projector through libmtmd on the '
        'upstream calls (chunk-level eval: $chunkEval)', () async {
      final projectorPath = '${dir.path}/mmproj.gguf';
      File(projectorPath).writeAsStringSync('GGUF');
      final upstream = LlamaCppService(
        objectCalls: LlamaCppObjectCalls.upstream,
      )..initializeBackend();
      addTearDown(upstream.dispose);
      final fake = FakeMtmd.install(
        upstream,
        tokens: service.tokenize(model, 'ab', true),
        chunkEval: chunkEval,
      );
      addTearDown(fake.dispose);
      final upstreamModel = upstream.loadModel(
        '${dir.path}/model.gguf',
        _params,
      );
      final upstreamContext = upstream.createContext(upstreamModel, _params);

      final projector = upstream.createMultimodalContext(
        upstreamModel,
        projectorPath,
      );
      await _generate(
        upstream,
        upstreamContext,
        '<__media__>',
        _greedy,
        parts: fake.parts,
      );
      upstream.freeMultimodalContext(projector);

      expect(fake.calls, [
        'mtmd_init_from_file',
        'mtmd_tokenize',
        evalCall,
        'mtmd_free',
      ]);
    });
  }
}

Future<List<int>> _generate(
  LlamaCppService service,
  int context,
  String prompt,
  GenerationParams params, {
  List<LlamaContentPart>? parts,
}) async {
  final cancel = calloc<Int8>();
  try {
    return [
      for (final chunk
          in await service
              .generate(context, prompt, params, cancel.address, parts: parts)
              .toList())
        ...chunk,
    ];
  } finally {
    calloc.free(cancel);
  }
}
