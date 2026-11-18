@TestOn('vm')
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:llamadart/src/backends/backend.dart';
import 'package:llamadart/src/backends/isolate_shutdown_releases.dart';
import 'package:llamadart/src/backends/llama_cpp/bindings.dart' as llama;
import 'package:llamadart/src/backends/llama_cpp/exit_teardown_api.dart';
import 'package:llamadart/src/backends/llama_cpp/llama_cpp_service.dart';
import 'package:llamadart/src/backends/llama_cpp/runtime_admission.dart';
import 'package:llamadart/src/core/exceptions.dart';
import 'package:llamadart/src/core/models/inference/generation_params.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

const String _admittedBuildIdentity =
    'llamadart-native-build/1;llama.cpp=$admittedLlamaCppCommit;variant=test;';

const List<String> _requiredSuffixes = [
  'api_version',
  'supported_modes',
  'params_default',
  'get_info',
  'init',
  'free',
  'push',
  'finish',
  'step',
  'read_text',
  'cancel',
  'set_cancel_flag',
  'reset',
  'last_error',
];

void _writeTestGguf(File file, Map<String, String> stringMetadata) {
  final builder = BytesBuilder();
  void writeU32(int value) {
    final data = ByteData(4)..setUint32(0, value, Endian.little);
    builder.add(data.buffer.asUint8List());
  }

  void writeU64(int value) {
    final data = ByteData(8)..setUint64(0, value, Endian.little);
    builder.add(data.buffer.asUint8List());
  }

  void writeGgufString(String value) {
    final bytes = utf8.encode(value);
    writeU64(bytes.length);
    builder.add(bytes);
  }

  builder.add(ascii.encode('GGUF'));
  writeU32(3); // version
  writeU64(0); // tensor count
  writeU64(stringMetadata.length); // kv count
  for (final entry in stringMetadata.entries) {
    writeGgufString(entry.key);
    writeU32(8); // GGUF_TYPE_STRING
    writeGgufString(entry.value);
  }
  file.writeAsBytesSync(builder.takeBytes(), flush: true);
}

final class _FakeNativeAsrRuntime {
  int apiVersion = 1;
  int supportedModes = 6;
  int getInfoStatus = 0;
  int infoApiVersion = 1;
  int infoMode = 2;
  int infoSampleRate = 16000;
  int infoChannels = 1;
  int initStatus = 0;
  bool returnNullInit = false;
  int setCancelFlagStatus = 0;
  String? errorMessage;

  final List<double> pushedSamples = <double>[];
  final List<int> offeredCounts = <int>[];
  final List<int> scriptedAcceptedCounts = <int>[];
  final List<
    ({
      int status,
      int state,
      int segmentBreaks,
      int samplesConsumed,
      int samplesBuffered,
      String text,
    })
  >
  scriptedSteps = [];
  int finishStatus = 0;
  int initCalls = 0;
  int cancelCalls = 0;
  int freeCalls = 0;
  int resetCalls = 0;
  int? cancelFlagPtrAddress;
  int? scriptedReadTextCount;
  String _pendingText = '';
  int _textReadOffset = 0;
  int? _lastConsumed;
  Pointer<Utf8>? _lastErrorPtr;

  late final NativeCallable<Uint32 Function()> _apiVersionFn =
      NativeCallable<Uint32 Function()>.isolateLocal(
        () => apiVersion,
        exceptionalReturn: 0,
      );
  late final NativeCallable<Uint32 Function()> _supportedModesFn =
      NativeCallable<Uint32 Function()>.isolateLocal(
        () => supportedModes,
        exceptionalReturn: 0,
      );
  late final NativeCallable<llama.llama_dart_asr_stream_params Function()>
  _paramsDefaultFn =
      NativeCallable<
        llama.llama_dart_asr_stream_params Function()
      >.isolateLocal(() {
        final ptr = calloc<llama.llama_dart_asr_stream_params>();
        ptr.ref.struct_size = sizeOf<llama.llama_dart_asr_stream_params>();
        ptr.ref.max_buffered_ms = 30000;
        ptr.ref.sequence_id = 0;
        final value = ptr.ref;
        calloc.free(ptr);
        return value;
      });
  late final NativeCallable<
    Int Function(
      Pointer<llama.llama_context>,
      Pointer<llama.mtmd_context>,
      Uint32,
      Pointer<llama.llama_dart_asr_stream_info>,
    )
  >
  _getInfoFn =
      NativeCallable<
        Int Function(
          Pointer<llama.llama_context>,
          Pointer<llama.mtmd_context>,
          Uint32,
          Pointer<llama.llama_dart_asr_stream_info>,
        )
      >.isolateLocal((
        Pointer<llama.llama_context> ctx,
        Pointer<llama.mtmd_context> mtmd,
        int acceptedModes,
        Pointer<llama.llama_dart_asr_stream_info> outInfo,
      ) {
        if (getInfoStatus == 0 && outInfo != nullptr) {
          outInfo.ref.api_version = infoApiVersion;
          outInfo.ref.mode = infoMode;
          outInfo.ref.sample_rate = infoSampleRate;
          outInfo.ref.channels = infoChannels;
        }
        return getInfoStatus;
      }, exceptionalReturn: -1);
  late final NativeCallable<
    Pointer<llama.llama_dart_asr_stream> Function(
      Pointer<llama.llama_context>,
      Pointer<llama.mtmd_context>,
      Uint32,
      Pointer<llama.llama_dart_asr_stream_params>,
      Pointer<Int>,
    )
  >
  _initFn =
      NativeCallable<
        Pointer<llama.llama_dart_asr_stream> Function(
          Pointer<llama.llama_context>,
          Pointer<llama.mtmd_context>,
          Uint32,
          Pointer<llama.llama_dart_asr_stream_params>,
          Pointer<Int>,
        )
      >.isolateLocal((
        Pointer<llama.llama_context> ctx,
        Pointer<llama.mtmd_context> mtmd,
        int acceptedModes,
        Pointer<llama.llama_dart_asr_stream_params> params,
        Pointer<Int> outStatus,
      ) {
        initCalls++;
        outStatus.value = initStatus;
        if (returnNullInit || initStatus != 0) {
          return nullptr;
        }
        return Pointer<llama.llama_dart_asr_stream>.fromAddress(0xCAFE00);
      });
  late final NativeCallable<Void Function(Pointer<llama.llama_dart_asr_stream>)>
  _freeFn =
      NativeCallable<
        Void Function(Pointer<llama.llama_dart_asr_stream>)
      >.isolateLocal((Pointer<llama.llama_dart_asr_stream> stream) {
        freeCalls++;
      });
  late final NativeCallable<
    Int Function(
      Pointer<llama.llama_dart_asr_stream>,
      Pointer<Float>,
      Size,
      Pointer<Size>,
    )
  >
  _pushFn =
      NativeCallable<
        Int Function(
          Pointer<llama.llama_dart_asr_stream>,
          Pointer<Float>,
          Size,
          Pointer<Size>,
        )
      >.isolateLocal((
        Pointer<llama.llama_dart_asr_stream> stream,
        Pointer<Float> samples,
        int sampleCount,
        Pointer<Size> outAccepted,
      ) {
        offeredCounts.add(sampleCount);
        final accepted = scriptedAcceptedCounts.isNotEmpty
            ? scriptedAcceptedCounts.removeAt(0)
            : sampleCount;
        outAccepted.value = accepted;
        final clamped = accepted.clamp(0, sampleCount);
        for (var i = 0; i < clamped; i++) {
          pushedSamples.add(samples[i]);
        }
        return 0;
      }, exceptionalReturn: -1);
  late final NativeCallable<Int Function(Pointer<llama.llama_dart_asr_stream>)>
  _finishFn =
      NativeCallable<
        Int Function(Pointer<llama.llama_dart_asr_stream>)
      >.isolateLocal(
        (Pointer<llama.llama_dart_asr_stream> stream) => finishStatus,
        exceptionalReturn: -1,
      );
  late final NativeCallable<
    Int Function(
      Pointer<llama.llama_dart_asr_stream>,
      Pointer<llama.llama_dart_asr_stream_progress>,
    )
  >
  _stepFn =
      NativeCallable<
        Int Function(
          Pointer<llama.llama_dart_asr_stream>,
          Pointer<llama.llama_dart_asr_stream_progress>,
        )
      >.isolateLocal((
        Pointer<llama.llama_dart_asr_stream> stream,
        Pointer<llama.llama_dart_asr_stream_progress> outProgress,
      ) {
        if (scriptedSteps.isEmpty) {
          outProgress.ref.state = 0; // NEEDS_AUDIO
          outProgress.ref.samples_consumed =
              _lastConsumed ?? pushedSamples.length;
          return 0;
        }
        final next = scriptedSteps.removeAt(0);
        outProgress.ref.state = next.state;
        outProgress.ref.segment_breaks = next.segmentBreaks;
        outProgress.ref.samples_consumed = next.samplesConsumed;
        outProgress.ref.samples_buffered = next.samplesBuffered;
        _lastConsumed = next.samplesConsumed;
        if (next.text.isNotEmpty) {
          _pendingText += next.text;
        }
        outProgress.ref.text_available =
            utf8.encode(_pendingText).length - _textReadOffset;
        return next.status;
      }, exceptionalReturn: -1);
  late final NativeCallable<
    Int Function(
      Pointer<llama.llama_dart_asr_stream>,
      Pointer<Char>,
      Size,
      Pointer<Size>,
    )
  >
  _readTextFn =
      NativeCallable<
        Int Function(
          Pointer<llama.llama_dart_asr_stream>,
          Pointer<Char>,
          Size,
          Pointer<Size>,
        )
      >.isolateLocal((
        Pointer<llama.llama_dart_asr_stream> stream,
        Pointer<Char> out,
        int capacity,
        Pointer<Size> outLen,
      ) {
        if (scriptedReadTextCount != null) {
          outLen.value = scriptedReadTextCount!;
          scriptedReadTextCount = null;
          return 0;
        }
        final encoded = utf8.encode(_pendingText);
        if (_textReadOffset >= encoded.length) {
          outLen.value = 0;
          return 0;
        }
        final int remaining = encoded.length - _textReadOffset;
        final int toCopy = remaining < capacity ? remaining : capacity;
        final outBytes = out.cast<Uint8>().asTypedList(toCopy);
        outBytes.setRange(0, toCopy, encoded, _textReadOffset);
        _textReadOffset += toCopy;
        outLen.value = toCopy;
        return 0;
      }, exceptionalReturn: -1);
  late final NativeCallable<Void Function(Pointer<llama.llama_dart_asr_stream>)>
  _cancelFn =
      NativeCallable<
        Void Function(Pointer<llama.llama_dart_asr_stream>)
      >.isolateLocal((Pointer<llama.llama_dart_asr_stream> stream) {
        cancelCalls++;
      });
  late final NativeCallable<
    Int Function(Pointer<llama.llama_dart_asr_stream>, Pointer<Int8>)
  >
  _setCancelFlagFn =
      NativeCallable<
        Int Function(Pointer<llama.llama_dart_asr_stream>, Pointer<Int8>)
      >.isolateLocal((
        Pointer<llama.llama_dart_asr_stream> stream,
        Pointer<Int8> flag,
      ) {
        cancelFlagPtrAddress = flag.address;
        return setCancelFlagStatus;
      }, exceptionalReturn: -1);
  late final NativeCallable<Int Function(Pointer<llama.llama_dart_asr_stream>)>
  _resetFn =
      NativeCallable<
        Int Function(Pointer<llama.llama_dart_asr_stream>)
      >.isolateLocal((Pointer<llama.llama_dart_asr_stream> stream) {
        resetCalls++;
        return 0;
      }, exceptionalReturn: -1);
  late final NativeCallable<
    Pointer<Char> Function(Pointer<llama.llama_dart_asr_stream>)
  >
  _lastErrorFn =
      NativeCallable<
        Pointer<Char> Function(Pointer<llama.llama_dart_asr_stream>)
      >.isolateLocal((Pointer<llama.llama_dart_asr_stream> stream) {
        if (errorMessage == null) return nullptr.cast<Char>();
        _lastErrorPtr ??= errorMessage!.toNativeUtf8();
        return _lastErrorPtr!.cast<Char>();
      });

  Pointer<NativeType> lookup(String name) => switch (name) {
    'llama_dart_asr_stream_api_version' => _apiVersionFn.nativeFunction,
    'llama_dart_asr_stream_supported_modes' => _supportedModesFn.nativeFunction,
    'llama_dart_asr_stream_params_default' => _paramsDefaultFn.nativeFunction,
    'llama_dart_asr_stream_get_info' => _getInfoFn.nativeFunction,
    'llama_dart_asr_stream_init' => _initFn.nativeFunction,
    'llama_dart_asr_stream_free' => _freeFn.nativeFunction,
    'llama_dart_asr_stream_push' => _pushFn.nativeFunction,
    'llama_dart_asr_stream_finish' => _finishFn.nativeFunction,
    'llama_dart_asr_stream_step' => _stepFn.nativeFunction,
    'llama_dart_asr_stream_read_text' => _readTextFn.nativeFunction,
    'llama_dart_asr_stream_cancel' => _cancelFn.nativeFunction,
    'llama_dart_asr_stream_set_cancel_flag' => _setCancelFlagFn.nativeFunction,
    'llama_dart_asr_stream_reset' => _resetFn.nativeFunction,
    'llama_dart_asr_stream_last_error' => _lastErrorFn.nativeFunction,
    _ => throw ArgumentError('missing $name'),
  };

  void dispose() {
    _apiVersionFn.close();
    _supportedModesFn.close();
    _paramsDefaultFn.close();
    _getInfoFn.close();
    _initFn.close();
    _freeFn.close();
    _pushFn.close();
    _finishFn.close();
    _stepFn.close();
    _readTextFn.close();
    _cancelFn.close();
    _setCancelFlagFn.close();
    _resetFn.close();
    _lastErrorFn.close();
    if (_lastErrorPtr != null) {
      malloc.free(_lastErrorPtr!);
      _lastErrorPtr = null;
    }
  }
}

void main() {
  group('ASR stream ABI admission and symbol resolution', () {
    late _FakeNativeAsrRuntime runtime;

    setUp(() {
      runtime = _FakeNativeAsrRuntime();
    });

    tearDown(() {
      runtime.dispose();
    });

    for (final missing in _requiredSuffixes) {
      test('missing required $missing does not admit a partial ASR API', () {
        final requested = <String>[];
        final modes = LlamaCppService.tryLoadAsrStreamApiModesForTest((name) {
          requested.add(name);
          if (name == 'llama_dart_asr_stream_$missing') {
            throw ArgumentError('missing export');
          }
          return runtime.lookup(name);
        });
        expect(modes, isNull);
        expect(requested, contains('llama_dart_asr_stream_$missing'));
      });
    }

    for (final incompatible in [0, 2]) {
      test('ABI $incompatible is rejected before binding other exports', () {
        runtime.apiVersion = incompatible;
        final requested = <String>[];
        final modes = LlamaCppService.tryLoadAsrStreamApiModesForTest((name) {
          requested.add(name);
          return runtime.lookup(name);
        });
        expect(modes, isNull);
        expect(requested, ['llama_dart_asr_stream_api_version']);
      });
    }

    test('supported_modes intersects with shifted mode mask 6', () {
      runtime.supportedModes = 1; // unshifted / NONE bit
      final none = LlamaCppService.tryLoadAsrStreamApiModesForTest(
        runtime.lookup,
      );
      expect(none, 0);

      runtime.supportedModes = 14; // bits 1, 2, and unknown bit 3
      final masked = LlamaCppService.tryLoadAsrStreamApiModesForTest(
        runtime.lookup,
      );
      expect(masked, 6);
    });

    test('asset symbol table maps all 14 exports on primary and wrapper', () {
      // Verify every suffix is handled without ArgumentError on both OS paths.
      for (final isWindows in [false, true]) {
        for (final suffix in _requiredSuffixes) {
          try {
            LlamaCppService.asrStreamAssetSymbolForTest(
              'llama_dart_asr_stream_$suffix',
              isWindows: isWindows,
            );
          } on ArgumentError catch (error) {
            // Native.addressOf throws ArgumentError only when the local test
            // asset lacks the symbol; unknown-name throws with 'Unknown ASR'.
            expect(error.message, isNot('Unknown ASR stream symbol'));
          }
        }
      }
    });

    test(
      'resolve throws LlamaUnsupportedException when runtime lacks exports',
      () {
        final service = LlamaCppService(
          isWindows: false,
          buildIdentity: () => _admittedBuildIdentity,
        );
        expect(
          () => service.resolveAsrStreamApiForTest(
            candidates: const [],
            assetSymbol: (name) => throw ArgumentError('missing $name'),
          ),
          throwsA(isA<LlamaUnsupportedException>()),
        );
        // Cached negative lookup still throws LlamaUnsupportedException.
        expect(
          () => service.resolveAsrStreamApiForTest(
            candidates: const [],
            assetSymbol: runtime.lookup,
          ),
          throwsA(isA<LlamaUnsupportedException>()),
        );
      },
    );

    test('real resolver refuses an unadmitted runtime', () {
      for (final identity in [
        null,
        'llamadart-native-build/1;llama.cpp=deadbeef;',
      ]) {
        final service = LlamaCppService(
          isWindows: false,
          buildIdentity: () => identity,
        );
        expect(
          () => service.resolveAsrStreamApiForTest(
            candidates: const [],
            assetSymbol: runtime.lookup,
          ),
          throwsA(
            isA<LlamaUnsupportedException>()
                .having(
                  (e) => e.message,
                  'message',
                  contains('Live speech recognition'),
                )
                .having(
                  (e) => e.message,
                  'message',
                  contains(admittedLlamaCppRelease),
                ),
          ),
        );
      }
    });
  });

  group('ASR stream probe and FFI state machine', () {
    late _FakeNativeAsrRuntime runtime;
    late Directory tempDir;
    late File projectorFile;
    late LlamaCppService service;
    late int contextHandle;
    late int mmHandle;
    late int seqCapacity;

    setUp(() {
      runtime = _FakeNativeAsrRuntime();
      tempDir = Directory.systemTemp.createTempSync('asr_stream_test_');
      projectorFile = File(path.join(tempDir.path, 'mmproj.gguf'));
      _writeTestGguf(projectorFile, {
        'clip.gen.audio.projector_type': 'lfm3a_gen',
        'clip.audio.projector_type': 'lfm3a',
      });
      seqCapacity = 2048;

      final exitApi = ExitTeardownApi(
        track: (_, _, _) => false,
        untrack: (_) => false,
        free: (_) {},
        freeAddress: nullptr,
        modelLoadFromFile: (_, _) => nullptr,
        initFromModel: (_, _) => nullptr,
        mtmdInitFromFile: (_, _, _) => nullptr,
        decode: (_, _) => 0,
        encode: (_, _) => 0,
        synchronize: (_) {},
        samplerSample: (_, _, _) => 0,
        stateSaveFile: (_, _, _, _) => false,
        stateLoadFile: (_, _, _, _, _) => false,
        stateSeqGetSizeExt: (_, _, _) => 0,
        stateSeqGetDataExt: (_, _, _, _, _) => 0,
        stateSeqSetDataExt: (_, _, _, _, _) => 0,
        adapterLoraInit: (_, _) => nullptr,
        mtmdTokenize: (_, _, _, _, _) => 0,
        mtmdEncodeChunk: (_, _) => 0,
        mtmdHelperEvalChunks: (_, _, _, _, _, _, _, _) => 0,
        mtmdHelperEvalChunkSingle: (_, _, _, _, _, _, _, _) => 0,
        mtmdHelperDecodeImageChunk: (_, _, _, _, _, _, _, _, _, _) => 0,
        schedGraphCompute: (_, _) => 0,
      );
      final calls = LlamaCppObjectCalls.tracked(
        exitApi,
        contextSequenceCapacity: (_) => seqCapacity,
      );
      service = LlamaCppService(
        isWindows: false,
        objectCalls: calls,
        buildIdentity: () => _admittedBuildIdentity,
        asrStreamSymbolLookup: runtime.lookup,
      );

      contextHandle = 1;
      mmHandle = 2;
      service.registerAsrTestHandles(
        contextHandle: contextHandle,
        mmHandle: mmHandle,
        calls: calls,
        projectorPath: projectorFile.path,
      );
    });

    tearDown(() {
      service.dispose();
      runtime.dispose();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test(
      'probe enforces 2048 floor for LFM3, metadata precedence, and family match',
      () async {
        expect(
          await service.asrStreamUnsupportedReason(contextHandle, mmHandle),
          isNull,
        );

        seqCapacity = 2047;
        expect(
          await service.asrStreamUnsupportedReason(contextHandle, mmHandle),
          contains('2048'),
        );
        seqCapacity = 2048;

        // Mismatched mode for lfm3a (TOKEN_DELAY instead of PROMPTED_CHUNKS)
        runtime.infoMode = 1;
        expect(
          await service.asrStreamUnsupportedReason(contextHandle, mmHandle),
          contains('does not match'),
        );

        // clip.projector_type takes precedence over clip.audio.projector_type
        _writeTestGguf(projectorFile, {
          'clip.audio.projector_type': 'lfm3a',
          'clip.projector_type': 'voxtral_rt',
        });
        service.clearAsrTestProjectorTypes();
        seqCapacity = 512; // Small working context allowed for TOKEN_DELAY
        expect(
          await service.asrStreamUnsupportedReason(contextHandle, mmHandle),
          isNull,
        );

        // Qwen3-ASR / unknown projector fails closed
        _writeTestGguf(projectorFile, {'clip.projector_type': 'qwen3_asr'});
        service.clearAsrTestProjectorTypes();
        expect(
          await service.asrStreamUnsupportedReason(contextHandle, mmHandle),
          contains('qwen3_asr'),
        );
      },
    );

    test(
      'probe preserves UPSTREAM_ERROR as LlamaSpeechException and overrides positive probe when init returns UNSUPPORTED',
      () async {
        runtime.getInfoStatus = -5; // UPSTREAM_ERROR
        await expectLater(
          () => service.asrStreamUnsupportedReason(contextHandle, mmHandle),
          throwsA(isA<LlamaSpeechException>()),
        );

        runtime.getInfoStatus = 0;
        runtime.returnNullInit = true;
        runtime.initStatus = -2; // UNSUPPORTED
        await expectLater(
          () => service.startAsrStream(
            1,
            contextHandle,
            mmHandle,
            0,
            onText: (_, _) {},
          ),
          throwsA(isA<LlamaUnsupportedException>()),
        );
      },
    );

    test(
      'push retries short/zero acceptance, respects view offsets, preserves whitespace & UTF-8, and processes segment breaks before text',
      () async {
        final updates = <String>[];
        final cancelFlag = malloc<Int8>()..value = 0;
        addTearDown(() => malloc.free(cancelFlag));

        await service.startAsrStream(
          10,
          contextHandle,
          mmHandle,
          cancelFlag.address,
          onText: (text, accepted) => updates.add('$text@$accepted'),
        );
        expect(runtime.cancelFlagPtrAddress, cancelFlag.address);

        // Script: first push accepts 0, steps WORKING -> NEEDS_AUDIO;
        // second push accepts 2, steps WORKING with segment 0 text "héllo ";
        // third push accepts remaining 2.
        runtime.scriptedAcceptedCounts.addAll([0, 2, 2]);
        runtime.scriptedSteps.addAll([
          (
            status: 0,
            state: 1, // WORKING
            segmentBreaks: 0,
            samplesConsumed: 0,
            samplesBuffered: 4,
            text: '',
          ),
          (
            status: 0,
            state: 0, // NEEDS_AUDIO
            segmentBreaks: 0,
            samplesConsumed: 0,
            samplesBuffered: 4,
            text: '',
          ),
          (
            status: 0,
            state: 0, // NEEDS_AUDIO
            segmentBreaks: 0,
            samplesConsumed: 2,
            samplesBuffered: 0,
            text: 'héllo',
          ),
          (
            status: 0,
            state: 0, // NEEDS_AUDIO
            segmentBreaks: 0,
            samplesConsumed: 4,
            samplesBuffered: 0,
            text: '',
          ),
        ]);

        final backing = Float32List.fromList([99, 1.0, 2.0, 3.0, 4.0, 88]);
        final view = Float32List.sublistView(backing, 1, 5);
        final accepted = await service.pushAsrPcm(10, 0, view);
        expect(accepted, 4);
        expect(runtime.pushedSamples, [1.0, 2.0, 3.0, 4.0]);
        expect(updates, ['héllo@2']);

        // Empty restart followed by visible text joins with one space on finish.
        runtime.scriptedSteps.addAll([
          (
            status: 0,
            state: 1, // WORKING
            segmentBreaks: 1,
            samplesConsumed: 4,
            samplesBuffered: 0,
            text: '',
          ),
          (
            status: 0,
            state: 2, // FINISHED
            segmentBreaks: 1,
            samplesConsumed: 4,
            samplesBuffered: 0,
            text: 'world!',
          ),
        ]);
        final result = await service.finishAsrStream(10, 4);
        expect(result.finalText, 'héllo world!');
        expect(result.acceptedSamples, 4);
        expect(result.consumedSamples, 4);
        expect(runtime.freeCalls, 1);
        expect(IsolateShutdownReleases.current.debugHeldForTesting, isEmpty);
      },
    );

    test(
      'CONTEXT_FULL drains terminal text and throws LlamaSpeechTranscriptTruncatedException(contextSize)',
      () async {
        await service.startAsrStream(
          11,
          contextHandle,
          mmHandle,
          0,
          onText: (_, _) {},
        );
        runtime.scriptedSteps.addAll([
          (
            status: 0,
            state: 1,
            segmentBreaks: 0,
            samplesConsumed: 1,
            samplesBuffered: 1,
            text: 'partial',
          ),
          (
            status: -7, // CONTEXT_FULL
            state: 2,
            segmentBreaks: 0,
            samplesConsumed: 1,
            samplesBuffered: 0,
            text: ' tail',
          ),
        ]);

        await expectLater(
          () => service.pushAsrPcm(11, 0, Float32List.fromList([0.1, 0.2])),
          throwsA(
            isA<LlamaSpeechTranscriptTruncatedException>()
                .having(
                  (e) => e.limit,
                  'limit',
                  LlamaSpeechTranscriptLimit.contextSize,
                )
                .having(
                  (e) => e.partialTranscript,
                  'partialTranscript',
                  'partial tail',
                ),
          ),
        );
        expect(runtime.freeCalls, 1);
      },
    );

    test(
      'early EOG with consumed < accepted throws LlamaSpeechTranscriptTruncatedException(runtime)',
      () async {
        await service.startAsrStream(
          12,
          contextHandle,
          mmHandle,
          0,
          onText: (_, _) {},
        );
        await service.pushAsrPcm(12, 0, Float32List.fromList([0.1, 0.2, 0.3]));

        runtime.scriptedSteps.add((
          status: 0,
          state: 2, // FINISHED
          segmentBreaks: 0,
          samplesConsumed: 2, // < 3 accepted
          samplesBuffered: 0,
          text: 'early',
        ));

        await expectLater(
          () => service.finishAsrStream(12, 3),
          throwsA(
            isA<LlamaSpeechTranscriptTruncatedException>()
                .having(
                  (e) => e.limit,
                  'limit',
                  LlamaSpeechTranscriptLimit.runtime,
                )
                .having(
                  (e) => e.partialTranscript,
                  'partialTranscript',
                  'early',
                ),
          ),
        );
        expect(runtime.freeCalls, 1);
      },
    );

    test(
      'active ASR session reserves context against stateSaveFile, stateLoadFile, generate, embed, score, LoRA, and TTS',
      () async {
        await service.startAsrStream(
          13,
          contextHandle,
          mmHandle,
          0,
          onText: (_, _) {},
        );

        final statePath = path.join(tempDir.path, 'state.bin');
        expect(
          () => service.stateSaveFile(contextHandle, statePath, const [1, 2]),
          throwsA(isA<LlamaStateException>()),
        );
        expect(
          () => service.stateLoadFile(contextHandle, statePath, 16),
          throwsA(isA<LlamaStateException>()),
        );
        await expectLater(
          service
              .generate(contextHandle, 'hi', const GenerationParams(), 0)
              .toList(),
          throwsA(isA<LlamaStateException>()),
        );
        expect(
          () => service.embed(contextHandle, 'hi'),
          throwsA(isA<LlamaStateException>()),
        );
        expect(
          () => service.embedBatch(contextHandle, const ['hi']),
          throwsA(isA<LlamaStateException>()),
        );
        expect(
          () => service.scoreNextToken(
            contextHandle,
            'hi',
            candidates: const [1],
            topK: 1,
            reusePromptPrefix: false,
          ),
          throwsA(isA<LlamaStateException>()),
        );
        expect(
          () => service.handleLora(contextHandle, null, null, 'clear'),
          throwsA(isA<LlamaStateException>()),
        );
        await expectLater(
          service.synthesizeTextToSpeech(
            contextHandle,
            mmHandle,
            const BackendTextToSpeechRequest(text: 'hi'),
            0,
          ),
          throwsA(isA<LlamaStateException>()),
        );

        runtime.scriptedSteps.add((
          status: 0,
          state: 2, // FINISHED
          segmentBreaks: 0,
          samplesConsumed: 0,
          samplesBuffered: 0,
          text: '',
        ));
        await service.finishAsrStream(13, 0);
        expect(service.hasActiveAsrStream, isFalse);
      },
    );

    test(
      'startAsrStream clears cachedPromptTokens and kvFromStateLoad',
      () async {
        service.setAsrTestCachedPromptTokens(contextHandle, const [
          10,
          20,
          30,
        ], kvFromStateLoad: true);
        await service.startAsrStream(
          14,
          contextHandle,
          mmHandle,
          0,
          onText: (_, _) {},
        );
        final cache = service.getAsrTestCachedPromptState(contextHandle);
        expect(cache.cachedPromptTokens, isNull);
        expect(cache.kvFromStateLoad, isFalse);
      },
    );

    test(
      'startAsrStream refuses active generation and pre-raised cancel flag before init',
      () async {
        service.setAsrTestContextGenerating(contextHandle, active: true);
        await expectLater(
          () => service.startAsrStream(
            15,
            contextHandle,
            mmHandle,
            0,
            onText: (_, _) {},
          ),
          throwsA(isA<LlamaStateException>()),
        );
        service.setAsrTestContextGenerating(contextHandle, active: false);
        expect(runtime.initCalls, 0);

        final flag = calloc<Int8>();
        try {
          flag.value = 1;
          await expectLater(
            () => service.startAsrStream(
              16,
              contextHandle,
              mmHandle,
              flag.address,
              onText: (_, _) {},
            ),
            throwsA(isA<LlamaSpeechException>()),
          );
          expect(runtime.initCalls, 0);
        } finally {
          calloc.free(flag);
        }
      },
    );

    test(
      'sample offset mismatch, stale cancel, double close, and freeModel cleanup',
      () async {
        await service.startAsrStream(
          17,
          contextHandle,
          mmHandle,
          0,
          onText: (_, _) {},
        );
        // Stale cancel does not affect session 17.
        service.cancelAsrStream(999);
        expect(service.hasActiveAsrStream, isTrue);

        // Wrong sample offset is rejected without closing or corrupting state.
        await expectLater(
          () => service.pushAsrPcm(17, 1, Float32List.fromList([0.1])),
          throwsA(isA<LlamaStateException>()),
        );
        await service.pushAsrPcm(17, 0, Float32List.fromList([0.1, 0.2]));
        await expectLater(
          () => service.finishAsrStream(17, 1),
          throwsA(isA<LlamaStateException>()),
        );

        // freeModel tears down the active ASR session and frees it once.
        service.freeModel(1);
        expect(service.hasActiveAsrStream, isFalse);
        expect(runtime.freeCalls, 1);

        // Double close / dispose never frees the native stream a second time.
        service.closeAsrStreamIfIdle(17);
        service.dispose();
        expect(runtime.freeCalls, 1);

        // Concurrent freeModel while pushAsrPcm is paused in WORKING hits
        // _closeAsrSession on the same session twice without double-freeing.
        final calls2 = LlamaCppObjectCalls.tracked(
          ExitTeardownApi(
            track: (_, _, _) => false,
            untrack: (_) => false,
            free: (_) {},
            freeAddress: nullptr,
            modelLoadFromFile: (_, _) => nullptr,
            initFromModel: (_, _) => nullptr,
            mtmdInitFromFile: (_, _, _) => nullptr,
            decode: (_, _) => 0,
            encode: (_, _) => 0,
            synchronize: (_) {},
            samplerSample: (_, _, _) => 0,
            stateSaveFile: (_, _, _, _) => false,
            stateLoadFile: (_, _, _, _, _) => false,
            stateSeqGetSizeExt: (_, _, _) => 0,
            stateSeqGetDataExt: (_, _, _, _, _) => 0,
            stateSeqSetDataExt: (_, _, _, _, _) => 0,
            adapterLoraInit: (_, _) => nullptr,
            mtmdTokenize: (_, _, _, _, _) => 0,
            mtmdEncodeChunk: (_, _) => 0,
            mtmdHelperEvalChunks: (_, _, _, _, _, _, _, _) => 0,
            mtmdHelperEvalChunkSingle: (_, _, _, _, _, _, _, _) => 0,
            mtmdHelperDecodeImageChunk: (_, _, _, _, _, _, _, _, _, _) => 0,
            schedGraphCompute: (_, _) => 0,
          ),
          contextSequenceCapacity: (_) => seqCapacity,
        );
        final service2 = LlamaCppService(
          isWindows: false,
          objectCalls: calls2,
          buildIdentity: () => _admittedBuildIdentity,
          asrStreamSymbolLookup: runtime.lookup,
        );
        addTearDown(service2.dispose);
        service2.registerAsrTestHandles(
          contextHandle: contextHandle,
          mmHandle: mmHandle,
          calls: calls2,
          projectorPath: projectorFile.path,
        );
        await service2.startAsrStream(
          170,
          contextHandle,
          mmHandle,
          0,
          onText: (_, _) {},
        );
        runtime.scriptedSteps.add((
          status: 0,
          state: 1, // WORKING
          segmentBreaks: 0,
          samplesConsumed: 1,
          samplesBuffered: 1,
          text: '',
        ));
        Future<void>(() => service2.freeModel(1));
        await expectLater(
          () => service2.pushAsrPcm(170, 0, Float32List.fromList([0.1, 0.2])),
          throwsA(isA<LlamaSpeechException>()),
        );
        expect(runtime.freeCalls, 2);
      },
    );

    test(
      'push throws on zero-progress NEEDS_AUDIO and yields event loop between WORKING steps',
      () async {
        // Zero acceptance + NEEDS_AUDIO with zero progress throws instead of spinning.
        await service.startAsrStream(
          18,
          contextHandle,
          mmHandle,
          0,
          onText: (_, _) {},
        );
        runtime.scriptedAcceptedCounts.add(0);
        runtime.scriptedSteps.add((
          status: 0,
          state: 0, // NEEDS_AUDIO
          segmentBreaks: 0,
          samplesConsumed: 0,
          samplesBuffered: 0,
          text: '',
        ));
        await expectLater(
          () => service.pushAsrPcm(18, 0, Float32List.fromList([0.1, 0.2])),
          throwsA(
            isA<LlamaSpeechException>().having(
              (e) => e.message,
              'message',
              contains('made no progress'),
            ),
          ),
        );

        // Event loop yields between WORKING steps so scheduled cancel takes effect.
        await service.startAsrStream(
          19,
          contextHandle,
          mmHandle,
          0,
          onText: (_, _) {},
        );
        runtime.scriptedSteps.addAll([
          (
            status: 0,
            state: 1, // WORKING
            segmentBreaks: 0,
            samplesConsumed: 1,
            samplesBuffered: 1,
            text: '',
          ),
          (
            status: 0,
            state:
                0, // NEEDS_AUDIO (should not be reached if event loop yields)
            segmentBreaks: 0,
            samplesConsumed: 2,
            samplesBuffered: 0,
            text: '',
          ),
        ]);
        Future<void>(() => service.cancelAsrStream(19));
        await expectLater(
          () => service.pushAsrPcm(19, 0, Float32List.fromList([0.1, 0.2])),
          throwsA(isA<LlamaSpeechException>()),
        );
        expect(runtime.scriptedSteps, hasLength(1));
      },
    );

    test(
      'rejects malformed native counts, decreasing segments, idle WORKING loops, NEEDS_AUDIO after finish, and early FINISHED on push',
      () async {
        // M40: accepted > remaining
        await service.startAsrStream(
          20,
          contextHandle,
          mmHandle,
          0,
          onText: (_, _) {},
        );
        runtime.scriptedAcceptedCounts.add(5);
        await expectLater(
          () => service.pushAsrPcm(20, 0, Float32List.fromList([0.1, 0.2])),
          throwsA(isA<LlamaSpeechException>()),
        );

        // M39: read_text count > capacity
        await service.startAsrStream(
          21,
          contextHandle,
          mmHandle,
          0,
          onText: (_, _) {},
        );
        runtime.scriptedReadTextCount = 999999;
        runtime.scriptedSteps.add((
          status: 0,
          state: 0, // NEEDS_AUDIO
          segmentBreaks: 0,
          samplesConsumed: 1,
          samplesBuffered: 0,
          text: '',
        ));
        await expectLater(
          () => service.pushAsrPcm(21, 0, Float32List.fromList([0.1])),
          throwsA(isA<LlamaSpeechException>()),
        );

        // M35: decreasing segment_breaks
        await service.startAsrStream(
          22,
          contextHandle,
          mmHandle,
          0,
          onText: (_, _) {},
        );
        runtime.scriptedSteps.add((
          status: 0,
          state: 0, // NEEDS_AUDIO
          segmentBreaks: 2,
          samplesConsumed: 1,
          samplesBuffered: 0,
          text: 'a',
        ));
        await service.pushAsrPcm(22, 0, Float32List.fromList([0.1]));
        runtime.scriptedSteps.add((
          status: 0,
          state: 0, // NEEDS_AUDIO
          segmentBreaks: 1,
          samplesConsumed: 2,
          samplesBuffered: 0,
          text: '',
        ));
        await expectLater(
          () => service.pushAsrPcm(22, 1, Float32List.fromList([0.2])),
          throwsA(isA<LlamaSpeechException>()),
        );

        // M37: NEEDS_AUDIO during finish
        await service.startAsrStream(
          23,
          contextHandle,
          mmHandle,
          0,
          onText: (_, _) {},
        );
        runtime.scriptedSteps.add((
          status: 0,
          state: 0, // NEEDS_AUDIO
          segmentBreaks: 0,
          samplesConsumed: 0,
          samplesBuffered: 0,
          text: '',
        ));
        await expectLater(
          () => service.finishAsrStream(23, 0),
          throwsA(isA<LlamaSpeechException>()),
        );

        // M38: unsolicited FINISHED during push preserves partial transcript
        await service.startAsrStream(
          24,
          contextHandle,
          mmHandle,
          0,
          onText: (_, _) {},
        );
        runtime.scriptedSteps.add((
          status: 0,
          state: 2, // FINISHED
          segmentBreaks: 0,
          samplesConsumed: 1,
          samplesBuffered: 0,
          text: 'cutoff',
        ));
        await expectLater(
          () => service.pushAsrPcm(24, 0, Float32List.fromList([0.1, 0.2])),
          throwsA(
            isA<LlamaSpeechTranscriptTruncatedException>()
                .having(
                  (e) => e.limit,
                  'limit',
                  LlamaSpeechTranscriptLimit.runtime,
                )
                .having(
                  (e) => e.partialTranscript,
                  'partialTranscript',
                  'cutoff',
                ),
          ),
        );

        // M36: idle WORKING loop (> 10000 identical WORKING steps)
        await service.startAsrStream(
          25,
          contextHandle,
          mmHandle,
          0,
          onText: (_, _) {},
        );
        runtime.scriptedSteps.addAll(
          List.generate(
            10002,
            (_) => (
              status: 0,
              state: 1, // WORKING
              segmentBreaks: 0,
              samplesConsumed: 0,
              samplesBuffered: 1,
              text: '',
            ),
          ),
        );
        await expectLater(
          () => service.pushAsrPcm(25, 0, Float32List.fromList([0.1])),
          throwsA(
            isA<LlamaSpeechException>().having(
              (e) => e.message,
              'message',
              contains('stopped making progress'),
            ),
          ),
        );
      },
    );
  });
}
