@TestOn('vm')
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:llamadart/src/backends/llama_cpp/bindings.dart';
import 'package:llamadart/src/backends/llama_cpp/exit_teardown_api.dart';
import 'package:llamadart/src/backends/llama_cpp/llama_cpp_service.dart';
import 'package:llamadart/src/core/models/inference/generation_params.dart';
import 'package:llamadart/src/core/models/inference/model_params.dart';
import 'package:test/test.dart';

import '../../../support/synthetic_embedding_gguf.dart';

const _params = ModelParams(gpuLayers: 0, contextSize: 64);
const _greedy = GenerationParams(maxTokens: 8, temp: 0, topK: 1, seed: 1);

// The time the fake backend keeps computing after each llama_decode returns.
const _backendMicros = 5000;

// Runs the real llama.cpp runtime on the CPU behind a decode that returns
// before its backend has finished, as Metal's does: the backend stays busy
// for _backendMicros after each llama_decode, until a synchronize waits for
// it.
void main() {
  late Directory dir;
  late LlamaCppService service;
  late int context;
  late List<String> calls;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('llamadart_decode_timing_');
    writeSyntheticLlamaGguf('${dir.path}/model.gguf');
    calls = [];
    final clock = Stopwatch()..start();
    var busyUntil = 0;
    service = LlamaCppService(
      objectCalls: LlamaCppObjectCalls.untracked(
        decode: (ctx, batch) {
          calls.add('decode');
          final status = llama_decode(ctx, batch);
          busyUntil = clock.elapsedMicroseconds + _backendMicros;
          return status;
        },
        synchronize: (ctx) {
          calls.add('synchronize');
          final remaining = busyUntil - clock.elapsedMicroseconds;
          if (remaining > 0) sleep(Duration(microseconds: remaining));
          llama_synchronize(ctx);
        },
      ),
    )..initializeBackend();
    final model = service.loadModel('${dir.path}/model.gguf', _params);
    context = service.createContext(model, _params);
  });

  tearDown(() {
    service.dispose();
    dir.deleteSync(recursive: true);
  });

  test('getPerformanceContext counts the backend work of a decode as '
      'decode time', () async {
    final cancel = calloc<Int8>();
    addTearDown(() => calloc.free(cancel));

    await service
        .generate(context, 'ab', _greedy, cancel.address)
        .drain<void>();
    final perf = service.getPerformanceContext(context);

    expect(perf.evalTokens, greaterThan(0));
    expect(
      perf.decodeMs,
      greaterThanOrEqualTo(perf.evalTokens * _backendMicros / 1000),
    );
    expect(perf.promptEvalMs, greaterThanOrEqualTo(_backendMicros / 1000));
    // Every decode waits for its backend before the next call.
    expect(
      calls.join(' '),
      matches(RegExp(r'^synchronize( decode synchronize)+$')),
    );
  });
}
