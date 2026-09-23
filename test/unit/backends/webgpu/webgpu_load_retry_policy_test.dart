import 'package:llamadart/src/backends/webgpu/webgpu_load_retry_policy.dart';
import 'package:test/test.dart';

const int _fourMiB = 4 * 1024 * 1024;

WebGpuLoadFailure _failure({
  int attemptIndex = 0,
  int attemptCount = 10,
  String errorText = 'bridge model load failed',
  String? coreVariant,
  String runtimeNotes = '',
  bool forceRemoteFetchRequested = false,
  bool remoteFetchBackendOptedIn = false,
}) {
  return WebGpuLoadFailure(
    attemptIndex: attemptIndex,
    attemptCount: attemptCount,
    errorText: errorText,
    coreVariant: coreVariant,
    runtimeNotes: runtimeNotes,
    forceRemoteFetchRequested: forceRemoteFetchRequested,
    remoteFetchBackendOptedIn: remoteFetchBackendOptedIn,
  );
}

WebGpuLoadEscalation _escalation({int remoteFetchChunkBytes = _fourMiB}) {
  return WebGpuLoadEscalation(remoteFetchChunkBytes: remoteFetchChunkBytes);
}

void main() {
  group('failure text predicates', () {
    test('memory pressure covers every recognised phrase', () {
      for (final phrase in <String>[
        'array buffer allocation failed',
        'out of memory',
        'memory access out of bounds',
        'bad_alloc',
        'aborted(native code called abort())',
      ]) {
        expect(
          isMemoryPressureErrorText('prefix $phrase suffix'),
          isTrue,
          reason: phrase,
        );
      }
      expect(isMemoryPressureErrorText('bridge model load failed'), isFalse);
    });

    test('bigint interop needs both halves of the phrase', () {
      expect(
        isBigIntInteropErrorText('cannot convert a bigint value to a number'),
        isTrue,
      );
      expect(isBigIntInteropErrorText('cannot convert a value'), isFalse);
      expect(isBigIntInteropErrorText('bigint overflow'), isFalse);
    });

    test('thread constructor failure covers both markers', () {
      expect(isThreadConstructorFailureText('thread constructor failed'), true);
      expect(isThreadConstructorFailureText('pthread error 138 raised'), true);
      expect(isThreadConstructorFailureText('error 139'), isFalse);
    });

    test('fs write notes cover every recognised marker', () {
      for (final note in <String>[
        'model_response_nostream',
        'model_fs_write_bigint_error',
        'model_fs_write_abort',
        'model_fs_write_arraybuffer_oom',
        'model_fs_write_failed',
      ]) {
        expect(
          runtimeNotesIndicateModelFsWriteFailure('a;$note;b'),
          isTrue,
          reason: note,
        );
      }
      expect(
        runtimeNotesIndicateModelFsWriteFailure('model_fetch_backend_attempt'),
        isFalse,
      );
    });
  });

  group('smaller remote fetch chunk restart', () {
    WebGpuLoadFailure abortedForcedFetch({int attemptIndex = 0}) {
      return _failure(
        attemptIndex: attemptIndex,
        runtimeNotes: 'model_fetch_backend_attempt;model_fetch_backend_abort',
        coreVariant: 'wasm32',
        forceRemoteFetchRequested: true,
        remoteFetchBackendOptedIn: true,
      );
    }

    test('halves the chunk size and reports the new size', () {
      final decision = classifyWebGpuLoadFailure(
        abortedForcedFetch(),
        _escalation(remoteFetchChunkBytes: 16 * 1024 * 1024),
      );

      expect(decision.action, WebGpuRetryAction.restart);
      expect(decision.escalation.remoteFetchChunkBytes, 8 * 1024 * 1024);
      expect(decision.escalation.remoteFetchChunkRetryCount, 1);
      expect(decision.forceRemoteFetchBackend, isTrue);
      expect(decision.preferMemory64, isNull);
      expect(decision.logMessages, <String>[
        'WebGpuLlamaBackend: fetch-backed model loading aborted; '
            'retrying with smaller fetch chunks '
            '(8192 KiB, attempt #1).',
      ]);
    });

    test('halves ten times from 16 MiB and then gives up', () {
      var state = _escalation(remoteFetchChunkBytes: 16 * 1024 * 1024);
      final sizes = <int>[state.remoteFetchChunkBytes];
      final actions = <WebGpuRetryAction>[];

      for (var i = 0; i < 12; i += 1) {
        final decision = classifyWebGpuLoadFailure(abortedForcedFetch(), state);
        actions.add(decision.action);
        state = decision.escalation;
        if (decision.action != WebGpuRetryAction.restart) {
          break;
        }
        sizes.add(state.remoteFetchChunkBytes);
      }

      expect(sizes, <int>[
        16 * 1024 * 1024,
        8 * 1024 * 1024,
        4 * 1024 * 1024,
        2 * 1024 * 1024,
        1024 * 1024,
        512 * 1024,
        256 * 1024,
        128 * 1024,
        64 * 1024,
        32 * 1024,
        16 * 1024,
      ]);
      expect(
        actions.where((a) => a == WebGpuRetryAction.restart),
        hasLength(10),
      );
      expect(actions.last, WebGpuRetryAction.giveUp);
      expect(state.remoteFetchChunkRetryCount, maxRemoteFetchChunkRestarts);
    });

    test('stops halving at the four KiB floor', () {
      var state = _escalation(remoteFetchChunkBytes: 20 * 1024);
      final sizes = <int>[state.remoteFetchChunkBytes];
      WebGpuRetryDecision decision;

      do {
        decision = classifyWebGpuLoadFailure(abortedForcedFetch(), state);
        state = decision.escalation;
        if (decision.action == WebGpuRetryAction.restart) {
          sizes.add(state.remoteFetchChunkBytes);
        }
      } while (decision.action == WebGpuRetryAction.restart);

      expect(sizes, <int>[
        20 * 1024,
        10 * 1024,
        5 * 1024,
        minRemoteFetchChunkBytes,
      ]);
      expect(decision.action, WebGpuRetryAction.giveUp);
      expect(state.remoteFetchChunkRetryCount, 3);
    });

    test('does not fire when thread creation is the failure', () {
      final decision = classifyWebGpuLoadFailure(
        _failure(
          errorText: 'thread constructor failed',
          runtimeNotes: 'model_fetch_backend_attempt;model_fetch_backend_abort',
          coreVariant: 'wasm32',
          forceRemoteFetchRequested: true,
          remoteFetchBackendOptedIn: true,
        ),
        _escalation(),
      );

      expect(decision.action, WebGpuRetryAction.giveUp);
      expect(decision.escalation.remoteFetchChunkBytes, _fourMiB);
    });

    test('does not fire without the remote fetch opt-in', () {
      final decision = classifyWebGpuLoadFailure(
        _failure(
          runtimeNotes: 'model_fetch_backend_attempt;model_fetch_backend_abort',
          coreVariant: 'wasm32',
          forceRemoteFetchRequested: true,
        ),
        _escalation(),
      );

      expect(decision.escalation.remoteFetchChunkRetryCount, 0);
    });

    test('halves a chunk one byte above the floor down to the floor', () {
      final decision = classifyWebGpuLoadFailure(
        abortedForcedFetch(),
        _escalation(remoteFetchChunkBytes: minRemoteFetchChunkBytes + 1),
      );

      expect(decision.action, WebGpuRetryAction.restart);
      expect(
        decision.escalation.remoteFetchChunkBytes,
        minRemoteFetchChunkBytes,
      );
    });

    test('does not fire when the notes report a thread failure', () {
      for (final note in <String>[
        'thread_constructor_failed',
        'threads_capped_no_coi',
      ]) {
        final decision = classifyWebGpuLoadFailure(
          _failure(
            runtimeNotes:
                'model_fetch_backend_attempt;model_fetch_backend_abort;$note',
            coreVariant: 'wasm32',
            forceRemoteFetchRequested: true,
            remoteFetchBackendOptedIn: true,
          ),
          _escalation(),
        );

        expect(decision.action, WebGpuRetryAction.giveUp, reason: note);
      }
    });

    test('needs both the attempt and the abort note', () {
      for (final notes in <String>[
        'model_fetch_backend_attempt',
        'model_fetch_backend_abort',
      ]) {
        final decision = classifyWebGpuLoadFailure(
          _failure(
            runtimeNotes: notes,
            coreVariant: 'wasm32',
            forceRemoteFetchRequested: true,
            remoteFetchBackendOptedIn: true,
          ),
          _escalation(),
        );

        expect(decision.action, WebGpuRetryAction.giveUp, reason: notes);
      }
    });
  });

  group('streamed loading restart', () {
    test('drops the fetch backend and prefers wasm64 on a wasm32 abort', () {
      final decision = classifyWebGpuLoadFailure(
        _failure(
          coreVariant: 'wasm32',
          runtimeNotes: 'model_fetch_backend_attempt;model_fetch_backend_abort',
        ),
        _escalation(),
      );

      expect(decision.action, WebGpuRetryAction.restart);
      expect(decision.forceRemoteFetchBackend, isFalse);
      expect(decision.preferMemory64, isTrue);
      expect(decision.escalation.retriedWithoutRemoteFetchBackend, isTrue);
      expect(decision.escalation.remoteFetchBackendKnownUnstable, isTrue);
      expect(decision.logMessages, <String>[
        'WebGpuLlamaBackend: fetch-backed model loading aborted on '
            'wasm32; retrying with wasm64 core and streamed '
            'network loading.',
      ]);
    });

    test('leaves the memory64 override alone on a non-wasm32 core', () {
      final decision = classifyWebGpuLoadFailure(
        _failure(
          coreVariant: 'wasm64',
          runtimeNotes: 'model_fetch_backend_attempt;model_fetch_backend_abort',
        ),
        _escalation(),
      );

      expect(decision.action, WebGpuRetryAction.restart);
      expect(decision.preferMemory64, isNull);
      expect(decision.logMessages, <String>[
        'WebGpuLlamaBackend: fetch-backed model loading aborted; '
            'retrying with streamed network loading.',
      ]);
    });

    test('fires at most once', () {
      final failure = _failure(
        coreVariant: 'wasm32',
        runtimeNotes: 'model_fetch_backend_attempt;model_fetch_backend_abort',
      );
      final first = classifyWebGpuLoadFailure(failure, _escalation());
      final second = classifyWebGpuLoadFailure(failure, first.escalation);

      expect(first.action, WebGpuRetryAction.restart);
      expect(second.action, WebGpuRetryAction.giveUp);
    });
  });

  group('remote fetch abort detection', () {
    test('a core abort note during a fetch attempt counts as an abort', () {
      final decision = classifyWebGpuLoadFailure(
        _failure(
          coreVariant: 'wasm32',
          errorText: 'out of memory',
          runtimeNotes: 'model_fetch_backend_attempt;core_abort',
          remoteFetchBackendOptedIn: true,
        ),
        _escalation(),
      );

      expect(decision.action, WebGpuRetryAction.restart);
      expect(decision.escalation.remoteFetchBackendKnownUnstable, isTrue);
      expect(decision.escalation.retriedWithoutRemoteFetchBackend, isTrue);
      expect(decision.forceRemoteFetchBackend, isFalse);
      expect(decision.logMessages, <String>[
        'WebGpuLlamaBackend: fetch-backed model loading aborted on '
            'wasm32; retrying with wasm64 core and streamed '
            'network loading.',
      ]);
    });

    test('a native abort error during a fetch attempt counts as an abort', () {
      final decision = classifyWebGpuLoadFailure(
        _failure(
          coreVariant: 'wasm32',
          errorText: 'aborted(native code called abort())',
          runtimeNotes: 'model_fetch_backend_attempt',
          remoteFetchBackendOptedIn: true,
        ),
        _escalation(),
      );

      expect(decision.action, WebGpuRetryAction.restart);
      expect(decision.escalation.remoteFetchBackendKnownUnstable, isTrue);
      expect(decision.escalation.retriedWithoutRemoteFetchBackend, isTrue);
      expect(decision.forceRemoteFetchBackend, isFalse);
      expect(decision.logMessages, <String>[
        'WebGpuLlamaBackend: fetch-backed model loading aborted on '
            'wasm32; retrying with wasm64 core and streamed '
            'network loading.',
      ]);
    });

    test('neither abort marker counts without a fetch attempt', () {
      for (final failure in <WebGpuLoadFailure>[
        _failure(
          coreVariant: 'wasm32',
          errorText: 'out of memory',
          runtimeNotes: 'core_abort',
          remoteFetchBackendOptedIn: true,
        ),
        _failure(
          coreVariant: 'wasm32',
          errorText: 'aborted(native code called abort())',
          remoteFetchBackendOptedIn: true,
        ),
      ]) {
        final decision = classifyWebGpuLoadFailure(failure, _escalation());

        expect(decision.escalation.remoteFetchBackendKnownUnstable, isFalse);
        expect(decision.forceRemoteFetchBackend, isTrue);
      }
    });
  });

  group('wasm32 restart after a wasm64 interop failure', () {
    test('latches the broken interop and clears both overrides', () {
      final decision = classifyWebGpuLoadFailure(
        _failure(
          coreVariant: 'wasm64',
          errorText: 'cannot convert a bigint value to a number',
        ),
        _escalation(),
      );

      expect(decision.action, WebGpuRetryAction.restart);
      expect(decision.preferMemory64, isFalse);
      expect(decision.forceRemoteFetchBackend, isFalse);
      expect(decision.escalation.retriedWithWasm32, isTrue);
      expect(decision.escalation.wasm64InteropKnownBroken, isTrue);
      expect(decision.logMessages, <String>[
        'WebGpuLlamaBackend: wasm64 BigInt interop failure detected; '
            'retrying with wasm32 core.',
      ]);
    });

    test('also fires on a skipped small fetch without latching interop', () {
      final decision = classifyWebGpuLoadFailure(
        _failure(
          coreVariant: 'wasm64',
          runtimeNotes: 'model_fetch_backend_skipped_small',
        ),
        _escalation(),
      );

      expect(decision.action, WebGpuRetryAction.restart);
      expect(decision.escalation.retriedWithWasm32, isTrue);
      expect(decision.escalation.wasm64InteropKnownBroken, isFalse);
    });

    test('fires at most once', () {
      final failure = _failure(
        coreVariant: 'wasm64',
        errorText: 'cannot convert a bigint value to a number',
      );
      final first = classifyWebGpuLoadFailure(failure, _escalation());
      final second = classifyWebGpuLoadFailure(failure, first.escalation);

      expect(first.action, WebGpuRetryAction.restart);
      expect(second.action, WebGpuRetryAction.giveUp);
    });

    test('a latched broken interop blocks the later wasm64 restart', () {
      final broken = classifyWebGpuLoadFailure(
        _failure(
          coreVariant: 'wasm64',
          errorText: 'cannot convert a bigint value to a number',
        ),
        _escalation(),
      ).escalation;

      final decision = classifyWebGpuLoadFailure(
        _failure(
          coreVariant: 'wasm32',
          errorText: 'out of memory',
          attemptIndex: 9,
        ),
        broken,
      );

      expect(decision.action, WebGpuRetryAction.giveUp);
      expect(decision.preferMemory64, isNull);
    });
  });

  group('wasm64 restart under wasm32 memory pressure', () {
    test('enables the fetch backend when it is opted in and untried', () {
      final decision = classifyWebGpuLoadFailure(
        _failure(
          coreVariant: 'wasm32',
          errorText: 'array buffer allocation failed',
          remoteFetchBackendOptedIn: true,
        ),
        _escalation(),
      );

      expect(decision.action, WebGpuRetryAction.restart);
      expect(decision.preferMemory64, isTrue);
      expect(decision.forceRemoteFetchBackend, isTrue);
      expect(decision.escalation.retriedWithWasm64, isTrue);
      expect(decision.logMessages, <String>[
        'WebGpuLlamaBackend: wasm32 memory pressure detected; '
            'retrying with wasm64 core and explicitly enabled '
            'fetch-backed loading.',
      ]);
    });

    test('reports the streamed retry after a fetch-backed attempt', () {
      final decision = classifyWebGpuLoadFailure(
        _failure(
          coreVariant: 'wasm32',
          errorText: 'out of memory',
          runtimeNotes: 'model_fetch_backend_attempt',
          remoteFetchBackendOptedIn: true,
        ),
        _escalation(),
      );

      expect(decision.forceRemoteFetchBackend, isFalse);
      expect(decision.logMessages, <String>[
        'WebGpuLlamaBackend: wasm32 memory pressure detected after '
            'fetch-backed loading; retrying with wasm64 core and '
            'streamed network loading.',
      ]);
    });

    test('reports the plain streamed retry without the opt-in', () {
      final decision = classifyWebGpuLoadFailure(
        _failure(coreVariant: 'wasm32', errorText: 'out of memory'),
        _escalation(),
      );

      expect(decision.forceRemoteFetchBackend, isFalse);
      expect(decision.logMessages, <String>[
        'WebGpuLlamaBackend: wasm32 memory pressure detected; '
            'retrying with wasm64 core and streamed network loading.',
      ]);
    });

    test(
      'a bare abort note in the same failure blocks re-enabling the backend',
      () {
        final decision = classifyWebGpuLoadFailure(
          _failure(
            coreVariant: 'wasm32',
            errorText: 'out of memory',
            runtimeNotes: 'model_fetch_backend_abort',
            remoteFetchBackendOptedIn: true,
          ),
          _escalation(),
        );

        expect(decision.action, WebGpuRetryAction.restart);
        expect(decision.escalation.remoteFetchBackendKnownUnstable, isTrue);
        expect(decision.forceRemoteFetchBackend, isFalse);
        expect(decision.logMessages, <String>[
          'WebGpuLlamaBackend: wasm32 memory pressure detected; '
              'retrying with wasm64 core and streamed network loading.',
        ]);
      },
    );

    test('an earlier abort also blocks re-enabling the backend', () {
      final decision = classifyWebGpuLoadFailure(
        _failure(
          coreVariant: 'wasm32',
          errorText: 'out of memory',
          remoteFetchBackendOptedIn: true,
        ),
        _escalation().copyWith(remoteFetchBackendKnownUnstable: true),
      );

      expect(decision.forceRemoteFetchBackend, isFalse);
    });

    test('wasm32 staging failure counts as memory pressure', () {
      final decision = classifyWebGpuLoadFailure(
        _failure(
          coreVariant: 'wasm32',
          runtimeNotes: 'model_fs_write_failed',
          remoteFetchBackendOptedIn: true,
        ),
        _escalation(),
      );

      expect(decision.action, WebGpuRetryAction.restart);
      expect(decision.preferMemory64, isTrue);
    });

    test('a wasm32 staging failure advances once the restart is spent', () {
      final decision = classifyWebGpuLoadFailure(
        _failure(
          coreVariant: 'wasm32',
          runtimeNotes: 'model_fs_write_failed',
          remoteFetchBackendOptedIn: true,
        ),
        _escalation().copyWith(retriedWithWasm64: true),
      );

      expect(decision.action, WebGpuRetryAction.advance);
      expect(decision.forceRemoteFetchBackend, isNull);
      expect(decision.logMessages, isEmpty);
    });

    test(
      'a staging failure without the wasm32 core is not memory pressure',
      () {
        final decision = classifyWebGpuLoadFailure(
          _failure(runtimeNotes: 'model_fs_write_failed'),
          _escalation(),
        );

        expect(decision.action, WebGpuRetryAction.giveUp);
      },
    );

    test('a skipped small fetch suppresses the restart', () {
      final decision = classifyWebGpuLoadFailure(
        _failure(
          coreVariant: 'wasm32',
          errorText: 'out of memory',
          runtimeNotes: 'model_fetch_backend_skipped_small',
        ),
        _escalation(),
      );

      expect(decision.action, WebGpuRetryAction.advance);
    });

    test('fires at most once', () {
      final failure = _failure(
        coreVariant: 'wasm32',
        errorText: 'out of memory',
        remoteFetchBackendOptedIn: true,
      );
      final first = classifyWebGpuLoadFailure(failure, _escalation());
      final second = classifyWebGpuLoadFailure(failure, first.escalation);

      expect(first.action, WebGpuRetryAction.restart);
      expect(second.action, WebGpuRetryAction.advance);
    });
  });

  group('wasm64 staging failure', () {
    WebGpuLoadFailure stagingFailure({bool optedIn = true}) {
      return _failure(
        coreVariant: 'wasm64',
        runtimeNotes: 'model_fs_write_failed',
        remoteFetchBackendOptedIn: optedIn,
      );
    }

    test('clamps the chunk size to 128 KiB on the forced retry', () {
      final decision = classifyWebGpuLoadFailure(
        stagingFailure(),
        _escalation(),
      );

      expect(decision.action, WebGpuRetryAction.restart);
      expect(decision.escalation.remoteFetchChunkBytes, fsWriteRetryChunkBytes);
      expect(decision.forceRemoteFetchBackend, isTrue);
      expect(decision.escalation.retriedAfterFsWriteFailureWithRemote, isTrue);
      expect(decision.logMessages, <String>[
        'WebGpuLlamaBackend: wasm64 model staging failed; retrying '
            'with forced fetch-backed loading and '
            '128 KiB chunks.',
      ]);
    });

    test('keeps an already smaller chunk size', () {
      final decision = classifyWebGpuLoadFailure(
        stagingFailure(),
        _escalation(remoteFetchChunkBytes: 64 * 1024),
      );

      expect(decision.escalation.remoteFetchChunkBytes, 64 * 1024);
      expect(decision.logMessages.single, contains('64 KiB chunks'));
    });

    test('gives up with the skip warning once the retry is spent', () {
      final first = classifyWebGpuLoadFailure(stagingFailure(), _escalation());
      final second = classifyWebGpuLoadFailure(
        stagingFailure(),
        first.escalation,
      );

      expect(second.action, WebGpuRetryAction.giveUp);
      expect(second.logMessages, <String>[
        'WebGpuLlamaBackend: wasm64 model staging failed; skipping '
            'fallback ladder because additional nCtx/GPU/thread '
            'reductions are unlikely to recover FS write failures.',
      ]);
    });

    test('gives up immediately without the remote fetch opt-in', () {
      final decision = classifyWebGpuLoadFailure(
        stagingFailure(optedIn: false),
        _escalation(),
      );

      expect(decision.action, WebGpuRetryAction.giveUp);
      expect(decision.logMessages, <String>[
        'WebGpuLlamaBackend: wasm64 model staging failed; '
            'fetch-backed recovery requires explicit opt-in, so no '
            'unsafe remote-fetch retry will be attempted.',
      ]);
    });

    test('never advances the ladder even under memory pressure', () {
      final decision = classifyWebGpuLoadFailure(
        _failure(
          coreVariant: 'wasm64',
          errorText: 'out of memory',
          runtimeNotes: 'model_fs_write_failed',
        ),
        _escalation(),
      );

      expect(decision.action, WebGpuRetryAction.giveUp);
    });
  });

  group('ladder advance and give up', () {
    test('advances while memory pressure and rungs remain', () {
      final decision = classifyWebGpuLoadFailure(
        _failure(
          attemptIndex: 0,
          attemptCount: 10,
          coreVariant: 'wasm64',
          errorText: 'out of memory',
        ),
        _escalation(),
      );

      expect(decision.action, WebGpuRetryAction.advance);
      expect(decision.logMessages, isEmpty);
      expect(decision.preferMemory64, isNull);
      expect(decision.forceRemoteFetchBackend, isNull);
    });

    test('gives up on the last rung', () {
      final decision = classifyWebGpuLoadFailure(
        _failure(
          attemptIndex: 9,
          attemptCount: 10,
          coreVariant: 'wasm64',
          errorText: 'out of memory',
        ),
        _escalation(),
      );

      expect(decision.action, WebGpuRetryAction.giveUp);
    });

    test('gives up when the failure is not memory pressure', () {
      final decision = classifyWebGpuLoadFailure(
        _failure(attemptIndex: 0, attemptCount: 10, coreVariant: 'wasm64'),
        _escalation(),
      );

      expect(decision.action, WebGpuRetryAction.giveUp);
    });

    test('carries the abort override through an advance', () {
      final decision = classifyWebGpuLoadFailure(
        _failure(
          attemptIndex: 0,
          attemptCount: 10,
          coreVariant: 'wasm64',
          errorText: 'out of memory',
          runtimeNotes: 'model_fetch_backend_attempt;model_fetch_backend_abort',
        ),
        _escalation().copyWith(retriedWithoutRemoteFetchBackend: true),
      );

      expect(decision.action, WebGpuRetryAction.advance);
      expect(decision.forceRemoteFetchBackend, isFalse);
      expect(decision.escalation.remoteFetchBackendKnownUnstable, isTrue);
    });

    test('leaves the override alone when the abort was self-inflicted', () {
      final decision = classifyWebGpuLoadFailure(
        _failure(
          attemptIndex: 9,
          attemptCount: 10,
          coreVariant: 'wasm32',
          runtimeNotes: 'model_fetch_backend_attempt;model_fetch_backend_abort',
          forceRemoteFetchRequested: true,
          remoteFetchBackendOptedIn: true,
        ),
        _escalation(remoteFetchChunkBytes: minRemoteFetchChunkBytes),
      );

      expect(decision.action, WebGpuRetryAction.giveUp);
      expect(decision.forceRemoteFetchBackend, isNull);
      expect(decision.escalation.remoteFetchBackendKnownUnstable, isTrue);
    });
  });

  group('escalation state', () {
    List<Object> fieldsOf(WebGpuLoadEscalation state) => <Object>[
      state.remoteFetchChunkBytes,
      state.retriedWithWasm32,
      state.retriedWithWasm64,
      state.retriedWithoutRemoteFetchBackend,
      state.remoteFetchChunkRetryCount,
      state.retriedAfterFsWriteFailureWithRemote,
      state.remoteFetchBackendKnownUnstable,
      state.wasm64InteropKnownBroken,
    ];

    test('copyWith keeps every field it is not given', () {
      const fired = WebGpuLoadEscalation(
        remoteFetchChunkBytes: 5120,
        retriedWithWasm32: true,
        retriedWithWasm64: true,
        retriedWithoutRemoteFetchBackend: true,
        remoteFetchChunkRetryCount: 3,
        retriedAfterFsWriteFailureWithRemote: true,
        remoteFetchBackendKnownUnstable: true,
        wasm64InteropKnownBroken: true,
      );

      expect(fieldsOf(fired.copyWith()), fieldsOf(fired));
    });
  });
}
