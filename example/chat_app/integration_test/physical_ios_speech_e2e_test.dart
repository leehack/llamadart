@Tags(['local-only', 'e2e'])
@Timeout(Duration(hours: 6))
/// Canonical physical-iOS speech integration test harness.
///
/// Validates four rows against real runtimes and checksum-pinned local files:
/// 1. llama.cpp Qwen3-ASR — capabilities, exact fixture transcript, active
///    cancellation, real microphone capture, and fresh reload.
/// 2. LiteRT-LM dedicated streaming ASR — partials, exactly one final event,
///    exact transcript, deterministic cancellation, fresh recognizer reload.
/// 3. llama.cpp Qwen3-TTS — 24 kHz mono synthesis, progress, WAV export and
///    strict read-back, cancellation after real progress, reload, and a
///    non-audible ASR round-trip.
/// 4. LiteRT-LM TTS — expected unsupported classification through the real
///    LiteRT-LM backend with a typed [LlamaUnsupportedException].
///
/// Fail-closed: never skips, never plays audio, never downloads, and requires
/// every path, digest, transcript, preset, and duration as a `--dart-define`.
/// The optional `IOS_SPEECH_ROW` define selects one canonical row for a
/// missing-row rerun; omit it or use `all` for the complete strict matrix.
///
/// Each path define is either a safe absolute on-device path or an
/// `@appcache/<relative>` reference. Installing onto a physical device rotates
/// the app data-container UUID, so an absolute container path captured before
/// the install stops resolving; the `@appcache/` form is bound to the runtime
/// cache directory during preflight, before any artifact is read.
///
/// Run with:
/// ```
/// cd example/chat_app && flutter drive --no-pub \
///   --publish-port \
///   --no-start-paused --device-vmservice-port="$IOS_SPEECH_DEVICE_VM_PORT" \
///   --host-vmservice-port="$IOS_SPEECH_HOST_VM_PORT" \
///   --driver=test_driver/integration_test.dart \
///   --target=integration_test/physical_ios_speech_e2e_test.dart \
///   --timeout=21600 -d "$PHYSICAL_IOS_DEVICE_ID" \
///   --dart-define=IOS_SPEECH_QWEN3_ASR_MODEL_PATH="$IOS_SPEECH_QWEN3_ASR_MODEL_PATH" \
///   --dart-define=IOS_SPEECH_QWEN3_ASR_MODEL_SHA256="$IOS_SPEECH_QWEN3_ASR_MODEL_SHA256" \
///   --dart-define=IOS_SPEECH_QWEN3_ASR_MMPROJ_PATH="$IOS_SPEECH_QWEN3_ASR_MMPROJ_PATH" \
///   --dart-define=IOS_SPEECH_QWEN3_ASR_MMPROJ_SHA256="$IOS_SPEECH_QWEN3_ASR_MMPROJ_SHA256" \
///   --dart-define=IOS_SPEECH_ASR_AUDIO_PATH="$IOS_SPEECH_ASR_AUDIO_PATH" \
///   --dart-define=IOS_SPEECH_ASR_AUDIO_SHA256="$IOS_SPEECH_ASR_AUDIO_SHA256" \
///   --dart-define=IOS_SPEECH_ASR_EXPECTED_TRANSCRIPT="$IOS_SPEECH_ASR_EXPECTED_TRANSCRIPT" \
///   --dart-define=IOS_SPEECH_MIC_DURATION_SECONDS="$IOS_SPEECH_MIC_DURATION_SECONDS" \
///   --dart-define=IOS_SPEECH_MIC_EXPECTED_TRANSCRIPT="$IOS_SPEECH_MIC_EXPECTED_TRANSCRIPT" \
///   --dart-define=IOS_SPEECH_LITERT_ASR_MODEL_PATH="$IOS_SPEECH_LITERT_ASR_MODEL_PATH" \
///   --dart-define=IOS_SPEECH_LITERT_ASR_MODEL_SHA256="$IOS_SPEECH_LITERT_ASR_MODEL_SHA256" \
///   --dart-define=IOS_SPEECH_LITERT_ASR_TOKENIZER_PATH="$IOS_SPEECH_LITERT_ASR_TOKENIZER_PATH" \
///   --dart-define=IOS_SPEECH_LITERT_ASR_TOKENIZER_SHA256="$IOS_SPEECH_LITERT_ASR_TOKENIZER_SHA256" \
///   --dart-define=IOS_SPEECH_LITERT_ASR_PRESET="$IOS_SPEECH_LITERT_ASR_PRESET" \
///   --dart-define=IOS_SPEECH_LITERT_ASR_AUDIO_PATH="$IOS_SPEECH_LITERT_ASR_AUDIO_PATH" \
///   --dart-define=IOS_SPEECH_LITERT_ASR_AUDIO_SHA256="$IOS_SPEECH_LITERT_ASR_AUDIO_SHA256" \
///   --dart-define=IOS_SPEECH_LITERT_ASR_EXPECTED_TRANSCRIPT="$IOS_SPEECH_LITERT_ASR_EXPECTED_TRANSCRIPT" \
///   --dart-define=IOS_SPEECH_QWEN3_TTS_MODEL_PATH="$IOS_SPEECH_QWEN3_TTS_MODEL_PATH" \
///   --dart-define=IOS_SPEECH_QWEN3_TTS_MODEL_SHA256="$IOS_SPEECH_QWEN3_TTS_MODEL_SHA256" \
///   --dart-define=IOS_SPEECH_QWEN3_TTS_MMPROJ_PATH="$IOS_SPEECH_QWEN3_TTS_MMPROJ_PATH" \
///   --dart-define=IOS_SPEECH_QWEN3_TTS_MMPROJ_SHA256="$IOS_SPEECH_QWEN3_TTS_MMPROJ_SHA256" \
///   --dart-define=IOS_SPEECH_TTS_TEXT="$IOS_SPEECH_TTS_TEXT" \
///   --dart-define=IOS_SPEECH_TTS_OUTPUT_PATH="$IOS_SPEECH_TTS_OUTPUT_PATH" \
///   --dart-define=IOS_SPEECH_TTS_EXPECTED_TRANSCRIPT="$IOS_SPEECH_TTS_EXPECTED_TRANSCRIPT" \
///   --dart-define=IOS_SPEECH_LITERT_LM_MODEL_PATH="$IOS_SPEECH_LITERT_LM_MODEL_PATH" \
///   --dart-define=IOS_SPEECH_LITERT_LM_MODEL_SHA256="$IOS_SPEECH_LITERT_LM_MODEL_SHA256"
/// ```
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:llamadart/llamadart.dart';

import 'package:llamadart_chat_example/services/audio_recording_service.dart';
import 'support/physical_ios_speech_e2e_support.dart';

/// 100 ms of 16 kHz mono PCM per push, so no single call hands the native
/// session an unbounded buffer.
const int _pcmChunkSamples = 1600;

const Duration _modelLoadTimeout = Duration(minutes: 8);
const Duration _transcribeTimeout = Duration(minutes: 6);
const Duration _streamTimeout = Duration(minutes: 6);
const Duration _synthesizeTimeout = Duration(minutes: 8);
const Duration _cancelTimeout = Duration(seconds: 45);
const Duration _cleanupTimeout = Duration(seconds: 60);
const Duration _activeCancellationObservation = Duration(milliseconds: 250);
const Duration _artifactHashTimeout = Duration(minutes: 10);

/// These are audio-codec frame ceilings, not decoded PCM sample ceilings.
const int _ttsMaxCodecFrames = 2048;
const int _ttsReloadMaxCodecFrames = 512;
const int _ttsCancelMaxCodecFrames = 2048;

const int _maxLiteRtAsrFixtureBytes = 64 * 1024 * 1024;

const Set<String> _row1ArtifactLabels = <String>{
  'qwen3AsrModel',
  'qwen3AsrMmproj',
  'asrAudio',
};
const Set<String> _row2ArtifactLabels = <String>{
  'liteRtAsrModel',
  'liteRtAsrTokenizer',
  'liteRtAsrAudio',
};
const Set<String> _row3ArtifactLabels = <String>{
  'qwen3TtsModel',
  'qwen3TtsMmproj',
  'qwen3AsrModel',
  'qwen3AsrMmproj',
};
const Set<String> _row4ArtifactLabels = <String>{'liteRtLmModel'};

const ModelParams _cpuParams = ModelParams(
  contextSize: 4096,
  preferredBackend: GpuBackend.cpu,
  gpuLayers: 0,
);

const String _selectedRowSelection = String.fromEnvironment(
  PhysicalIosSpeechEnvKeys.rowSelection,
  defaultValue: physicalIosSpeechAllRows,
);

Future<void> _disposeEngine(LlamaEngine engine, String label) =>
    awaitBounded(engine.dispose(), _cleanupTimeout, '$label.dispose');

Future<void> _settleSpeechTask({
  required void Function() cancel,
  required Future<Object?> done,
  required Future<Object?> eventsClosed,
  required String label,
}) async {
  Object? firstError;
  StackTrace? firstStackTrace;

  Future<void> run(Future<void> Function() action) async {
    try {
      await action();
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
  }

  await run(() async => cancel());
  await run(() => awaitBounded(done, _cleanupTimeout, '$label.cleanupDone'));
  await run(
    () => awaitBounded(
      eventsClosed,
      _cleanupTimeout,
      '$label.cleanupEventsClosed',
    ),
  );
  final cleanupError = firstError;
  if (cleanupError != null) {
    Error.throwWithStackTrace(cleanupError, firstStackTrace!);
  }
}

Future<Uint8List> _readBoundedFixture(File file, String label) async {
  final length = await awaitBounded(
    file.length(),
    _cleanupTimeout,
    '$label.length',
  );
  if (length <= 44 || length > _maxLiteRtAsrFixtureBytes) {
    throw StateError(
      '$label must be a nonempty WAV no larger than '
      '$_maxLiteRtAsrFixtureBytes bytes.',
    );
  }
  return awaitBounded(file.readAsBytes(), _cleanupTimeout, '$label.read');
}

Future<void> _cleanupRecorder(
  AudioRecordingService recorder,
  String? recordingPath,
) async {
  Object? cleanupError;
  StackTrace? cleanupStackTrace;
  try {
    if (recordingPath == null) {
      await awaitBounded(recorder.cancel(), _cleanupTimeout, 'row1.mic.cancel');
    } else {
      await awaitBounded(
        recorder.deleteRecording(recordingPath),
        _cleanupTimeout,
        'row1.mic.delete',
      );
    }
  } catch (error, stackTrace) {
    cleanupError = error;
    cleanupStackTrace = stackTrace;
  }
  try {
    await awaitBounded(recorder.dispose(), _cleanupTimeout, 'row1.mic.dispose');
  } catch (error, stackTrace) {
    cleanupError ??= error;
    cleanupStackTrace ??= stackTrace;
  }
  if (cleanupError != null) {
    Error.throwWithStackTrace(cleanupError, cleanupStackTrace!);
  }
}

void _emitAndValidateResults(
  List<SpeechE2ERowResult> rows, {
  required Set<String> expectedIds,
}) {
  for (final row in rows) {
    debugPrint(row.toResultLine());
  }
  final summary = SpeechE2ESummary(rows);
  debugPrint(summary.toSummaryLine());
  summary.validateSelectedRows(expectedIds);
}

void _recordPreflightFailure(
  List<SpeechE2ERowResult> results,
  Object error,
  Iterable<String> rowIds,
) {
  for (final id in rowIds) {
    results.add(
      SpeechE2ERowResult(
        id: id,
        status: SpeechE2ERowStatus.fail,
        backend: unresolvedSpeechBackendForRow(id),
        duration: Duration.zero,
        error: error,
      ),
    );
  }
}

/// Loads a Qwen3 model plus its projector on explicit llama.cpp CPU.
Future<LlamaEngine> _loadCpuEngine(
  String modelPath,
  String mmprojPath,
  String label,
) async {
  final engine = LlamaEngine(LlamaBackend());
  try {
    await awaitBounded(
      engine.loadModel(modelPath, modelParams: _cpuParams),
      _modelLoadTimeout,
      '$label.loadModel',
    );
    await awaitBounded(
      engine.loadMultimodalProjector(mmprojPath),
      _modelLoadTimeout,
      '$label.loadMultimodalProjector',
    );
    final gpuLayers = await awaitBounded(
      engine.getResolvedGpuLayers(),
      _cleanupTimeout,
      '$label.getResolvedGpuLayers',
    );
    if (gpuLayers == null || gpuLayers != 0) {
      throw StateError(
        '$label expected 0 resolved GPU layers for llama.cpp CPU, but resolved '
        '${gpuLayers ?? 'null'}.',
      );
    }
    requireSpeechBackendIdentity(
      await awaitBounded(
        engine.getBackendName(),
        _cleanupTimeout,
        '$label.getBackendName',
      ),
      SpeechE2EBackendKind.llamaCppCpu,
    );
    return engine;
  } catch (error, stackTrace) {
    try {
      await _disposeEngine(engine, label);
    } catch (_) {
      // Preserve the model/projector load failure as the authoritative error.
    }
    Error.throwWithStackTrace(error, stackTrace);
  }
}

Future<String> _transcribeExact({
  required SpeechToTextEngine recognizer,
  required String audioPath,
  required String expectedTranscript,
  required String label,
}) async {
  final task = await awaitBounded(
    recognizer.transcribe(
      SpeechToTextRequest(
        audio: SpeechAudioFileInput(audioPath),
        maxOutputTokens: 512,
      ),
    ),
    _transcribeTimeout,
    '$label.start',
  );
  final eventsFuture = collectSpeechEvents(task.events);
  String? fingerprint;
  await runWithSpeechCleanup(
    body: () async {
      final completion = await awaitBounded(
        task.done,
        _transcribeTimeout,
        '$label.done',
      );
      final events = await awaitBounded(
        eventsFuture,
        _transcribeTimeout,
        '$label.eventsClosed',
      );
      if (completion.state != SpeechToTextCompletionState.completed) {
        throw StateError(
          '$label ended in ${completion.state.name} instead of completed'
          '${completion.error == null ? '' : ': ${safeSpeechErrorDiagnostic(completion.error!)}'}',
        );
      }
      final result = completion.result;
      if (result == null) {
        throw StateError('$label completed without a SpeechToTextResult.');
      }
      final finalEvents = events.whereType<SpeechToTextFinalEvent>().toList();
      if (finalEvents.length != 1) {
        throw StateError(
          '$label emitted ${finalEvents.length} final events instead of one.',
        );
      }
      final text = result.text;
      expectExactNormalizedTranscript(
        actual: text,
        expected: expectedTranscript,
        label: label,
      );
      expectExactNormalizedTranscript(
        actual: finalEvents.single.result.text,
        expected: expectedTranscript,
        label: '$label.finalEvent',
      );
      fingerprint = transcriptFingerprint(text);
    },
    cleanup: () => _settleSpeechTask(
      cancel: task.cancel,
      done: task.done,
      eventsClosed: eventsFuture,
      label: label,
    ),
  );
  return fingerprint!;
}

/// Streams [samples] into [session] in bounded chunks.
Future<void> _pushBoundedPcm(
  SpeechToTextStreamingSession session,
  Float32List samples,
  String label,
) async {
  final elapsed = Stopwatch()..start();
  var index = 0;
  for (final chunk in chunkPcmSamples(samples, _pcmChunkSamples)) {
    final remaining = _streamTimeout - elapsed.elapsed;
    if (remaining <= Duration.zero) {
      throw TimeoutException(
        '$label exceeded the total bounded-PCM push deadline.',
        _streamTimeout,
      );
    }
    await awaitBounded(
      session.addPcm(chunk),
      remaining,
      '$label.addPcm[$index]',
    );
    index++;
  }
}

/// Runs one row, always recording a result and never aborting the harness.
Future<void> _recordRow({
  required String id,
  required List<SpeechE2ERowResult> results,
  required Future<SpeechE2ERowResult> Function(Stopwatch elapsed) body,
}) async {
  final stopwatch = Stopwatch()..start();
  try {
    final result = await body(stopwatch);
    if (result.id != id) {
      throw StateError('Speech row body returned a mismatched row id.');
    }
    results.add(result);
  } catch (error) {
    results.add(
      SpeechE2ERowResult(
        id: id,
        status: classifySpeechRowFailure(error),
        backend: unresolvedSpeechBackendForRow(id),
        duration: stopwatch.elapsed,
        error: error,
        actionMarker: speechRowFailureMarker(error),
      ),
    );
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('canonical physical-iOS speech E2E validation', (
    WidgetTester _,
  ) async {
    final selectedRowIds = selectPhysicalIosSpeechRowIds(_selectedRowSelection);
    final expectedRowIds = selectedRowIds.toSet();
    final rowResults = <SpeechE2ERowResult>[];
    try {
      if (kIsWeb || !Platform.isIOS) {
        throw StateError(
          'physical_ios_speech_e2e_test requires the iOS device runtime.',
        );
      }
      if (!isPhysicalIosApplicationExecutablePath(
        Platform.resolvedExecutable,
      )) {
        throw StateError(
          'physical_ios_speech_e2e_test requires an app installed on physical '
          'iOS hardware.',
        );
      }
    } catch (error) {
      _recordPreflightFailure(rowResults, error, selectedRowIds);
      _emitAndValidateResults(rowResults, expectedIds: expectedRowIds);
      return;
    }

    late final PhysicalIosSpeechConfig config;
    late final Map<String, PhysicalIosSpeechArtifactFailure> artifactFailures;
    try {
      // Resolution must precede every artifact read: a device install mints a
      // fresh data-container UUID, so `@appcache/` defines only name a real
      // file once bound to the runtime cache directory.
      config = await canonicalizePhysicalIosSpeechFilesystemLayout(
        await resolvePhysicalIosSpeechCachePaths(
          PhysicalIosSpeechConfig.fromEnvironment(),
        ),
      );
      artifactFailures = await config.validateArtifactsCollectingFailures(
        timeoutPerArtifact: _artifactHashTimeout,
      );
    } catch (error) {
      _recordPreflightFailure(rowResults, error, selectedRowIds);
      _emitAndValidateResults(rowResults, expectedIds: expectedRowIds);
      return;
    }

    // =====================================================================
    // ROW 1: llama.cpp Qwen3-ASR
    // =====================================================================
    if (selectedRowIds.contains('llama_cpp_qwen3_asr')) {
      await _recordRow(
        id: 'llama_cpp_qwen3_asr',
        results: rowResults,
        body: (elapsed) async {
          requireValidSpeechArtifacts(artifactFailures, _row1ArtifactLabels);
          String? backendName;
          final engine = await _loadCpuEngine(
            config.qwen3AsrModelPath,
            config.qwen3AsrMmprojPath,
            'row1.engine',
          );
          await runWithSpeechCleanup(
            body: () async {
              final gpuLayers = await awaitBounded(
                engine.getResolvedGpuLayers(),
                _cleanupTimeout,
                'row1.getResolvedGpuLayers',
              );
              if (gpuLayers == null || gpuLayers != 0) {
                throw StateError(
                  'Expected 0 GPU layers for llama.cpp CPU, but the runtime '
                  'resolved ${gpuLayers ?? 'null'} GPU layers.',
                );
              }

              final recognizer = SpeechToTextEngine(
                engine,
                modelProfile: SpeechToTextModelProfile.qwen3Asr,
              );
              final caps = await awaitBounded(
                recognizer.capabilities,
                _cleanupTimeout,
                'row1.capabilities',
              );
              expect(
                caps.isSupported,
                isTrue,
                reason:
                    caps.unsupportedReason ?? 'Qwen3-ASR should be supported',
              );
              expect(
                caps.implementation,
                equals(SpeechToTextImplementation.multimodalPromptAdapter),
              );
              expect(caps.supportsCancellation, isTrue);
              final reportedBackend = caps.backendName;
              final String resolvedBackend;
              if (reportedBackend case final String value) {
                resolvedBackend = value;
              } else {
                resolvedBackend = await awaitBounded(
                  engine.getBackendName(),
                  _cleanupTimeout,
                  'row1.getBackendName',
                );
              }
              backendName = requireSpeechBackendIdentity(
                resolvedBackend,
                SpeechE2EBackendKind.llamaCppCpu,
              );

              await _transcribeExact(
                recognizer: recognizer,
                audioPath: config.asrAudioPath,
                expectedTranscript: config.asrExpectedTranscript,
                label: 'row1.fixture',
              );

              final cancelTask = await awaitBounded(
                recognizer.transcribe(
                  SpeechToTextRequest(
                    audio: SpeechAudioFileInput(config.asrAudioPath),
                    maxOutputTokens: 512,
                  ),
                ),
                _transcribeTimeout,
                'row1.cancel.start',
              );
              final cancelEventsFuture = collectSpeechEvents(cancelTask.events);
              await runWithSpeechCleanup(
                body: () async {
                  await requireStillActiveBeforeCancellation(
                    cancelTask.done,
                    _activeCancellationObservation,
                    'row1.cancel',
                  );
                  cancelTask.cancel();
                  final cancelCompletion = await awaitBounded(
                    cancelTask.done,
                    _cancelTimeout,
                    'row1.cancel.done',
                  );
                  final cancelEvents = await awaitBounded(
                    cancelEventsFuture,
                    _cancelTimeout,
                    'row1.cancel.eventsClosed',
                  );
                  expect(
                    verifySttCancellation(cancelCompletion),
                    isTrue,
                    reason:
                        'Cancelled transcription must reach the cancelled state',
                  );
                  expect(
                    cancelEvents.whereType<SpeechToTextFinalEvent>(),
                    isEmpty,
                    reason:
                        'Cancelled transcription must not emit a final result',
                  );
                },
                cleanup: () => _settleSpeechTask(
                  cancel: cancelTask.cancel,
                  done: cancelTask.done,
                  eventsClosed: cancelEventsFuture,
                  label: 'row1.cancel',
                ),
              );

              // Physical microphone capture. The recorder is created outside the
              // capture try so a failing start() or stop() still disposes it.
              final recorder = AudioRecordingService();
              String? micWavPath;
              await runWithSpeechCleanup(
                body: () async {
                  if (!recorder.isSupported) {
                    throw const AudioRecordingException(
                      AudioRecordingFailure.unsupported,
                      'AudioRecordingService reports no recorder on this device.',
                    );
                  }
                  await awaitBounded(
                    recorder.start(),
                    _cleanupTimeout,
                    'row1.mic.start',
                  );
                  await Future<void>.delayed(
                    Duration(seconds: config.micDurationSeconds),
                  );
                  final capturedPath = await awaitBounded(
                    recorder.stop(),
                    _cleanupTimeout,
                    'row1.mic.stop',
                  );
                  micWavPath = capturedPath;

                  expect(
                    await awaitBounded(
                      File(capturedPath).exists(),
                      _cleanupTimeout,
                      'row1.mic.exists',
                    ),
                    isTrue,
                  );
                  final micBytes = await awaitBounded(
                    recorder.readRecording(capturedPath),
                    _cleanupTimeout,
                    'row1.mic.read',
                  );
                  final micInfo = validatePcm16Wav(
                    micBytes,
                    expectedSampleRate: 16000,
                    expectedChannels: 1,
                    requireNonSilent: true,
                  );
                  expect(micInfo.sampleFrames, greaterThan(0));
                  expect(micInfo.durationSeconds, greaterThan(0.0));

                  await _transcribeExact(
                    recognizer: recognizer,
                    audioPath: capturedPath,
                    expectedTranscript: config.micExpectedTranscript,
                    label: 'row1.microphone',
                  );
                },
                cleanup: () => _cleanupRecorder(recorder, micWavPath),
              );
            },
            cleanup: () => _disposeEngine(engine, 'row1.engine'),
          );

          // Fresh engine over the same immutable paths proves unload/reload.
          final reloadEngine = await _loadCpuEngine(
            config.qwen3AsrModelPath,
            config.qwen3AsrMmprojPath,
            'row1.reload',
          );
          await runWithSpeechCleanup(
            body: () => _transcribeExact(
              recognizer: SpeechToTextEngine(
                reloadEngine,
                modelProfile: SpeechToTextModelProfile.qwen3Asr,
              ),
              audioPath: config.asrAudioPath,
              expectedTranscript: config.asrExpectedTranscript,
              label: 'row1.reload.fixture',
            ),
            cleanup: () => _disposeEngine(reloadEngine, 'row1.reload'),
          );

          final validatedBackendName = backendName;
          if (validatedBackendName == null) {
            throw StateError('row1 did not resolve its runtime backend.');
          }
          return SpeechE2ERowResult(
            id: 'llama_cpp_qwen3_asr',
            status: SpeechE2ERowStatus.pass,
            backend: validatedBackendName,
            duration: elapsed.elapsed,
            digestIdentifiers: {
              'model': config.qwen3AsrModelSha256.substring(0, 8),
              'mmproj': config.qwen3AsrMmprojSha256.substring(0, 8),
              'fixture': config.asrAudioSha256.substring(0, 8),
            },
            assertionSummary:
                'llama.cpp CPU with 0 GPU layers, caps verified, exact fixture '
                'transcript, active cancellation, physical mic capture with '
                'strict mono PCM16 WAV, exact mic transcript, cleanup, fresh CPU '
                'reload on the same pinned paths',
          );
        },
      );
    }

    // =====================================================================
    // ROW 2: LiteRT-LM dedicated streaming ASR
    // =====================================================================
    if (selectedRowIds.contains('litert_lm_streaming_asr')) {
      await _recordRow(
        id: 'litert_lm_streaming_asr',
        results: rowResults,
        body: (elapsed) async {
          requireValidSpeechArtifacts(artifactFailures, _row2ArtifactLabels);
          final floatSamples = decodePcm16WavToFloat32(
            await _readBoundedFixture(
              File(config.liteRtAsrAudioPath),
              'row2.fixture',
            ),
            expectedSampleRate: 16000,
            expectedChannels: 1,
            requireNonSilent: true,
          );

          final runtimeConfig = LiteRtLmAsrRuntimeConfig(
            modelPath: config.liteRtAsrModelPath,
            tokenizerPath: config.liteRtAsrTokenizerPath,
            modelPreset: config.liteRtAsrPreset,
          );

          final liteRtEngine = SpeechToTextEngine.liteRtLm(runtimeConfig);
          final caps = await awaitBounded(
            liteRtEngine.capabilities,
            _cleanupTimeout,
            'row2.capabilities',
          );
          expect(
            caps.isSupported,
            isTrue,
            reason:
                caps.unsupportedReason ?? 'LiteRT-LM ASR should be supported',
          );
          expect(
            caps.implementation,
            equals(SpeechToTextImplementation.dedicatedBackend),
          );
          expect(caps.supportsPartialResults, isTrue);
          expect(caps.supportsStreamingInput, isTrue);
          expect(caps.supportsInputBackpressure, isTrue);
          expect(caps.supportsCancellation, isTrue);
          final backendName = requireSpeechBackendIdentity(
            caps.backendName ?? '',
            SpeechE2EBackendKind.liteRtLmAsrCpu,
          );

          final session = await awaitBounded(
            liteRtEngine.startStream(),
            _streamTimeout,
            'row2.session.start',
          );
          // Subscribe before any PCM is pushed and await stream closure after
          // terminal completion so the final event cannot race assertions.
          final eventsFuture = collectSpeechEvents(session.events);
          var sessionSettled = false;
          await runWithSpeechCleanup(
            body: () async {
              await _pushBoundedPcm(session, floatSamples, 'row2.session');
              await awaitBounded(
                session.finish(),
                _streamTimeout,
                'row2.session.finish',
              );
              final completion = await awaitBounded(
                session.done,
                _streamTimeout,
                'row2.session.done',
              );
              final events = await awaitBounded(
                eventsFuture,
                _streamTimeout,
                'row2.session.eventsClosed',
              );
              sessionSettled = true;
              final partialEvents = events
                  .whereType<SpeechToTextPartialEvent>()
                  .toList();
              final finalEvents = events
                  .whereType<SpeechToTextFinalEvent>()
                  .toList();

              expect(
                completion.state,
                equals(SpeechToTextCompletionState.completed),
              );
              expect(
                partialEvents.any((p) => p.text.trim().isNotEmpty),
                isTrue,
                reason: 'Expected at least one non-empty partial transcript',
              );
              expect(
                finalEvents,
                hasLength(1),
                reason: 'Expected exactly one final event',
              );
              final result = completion.result;
              if (result == null) {
                throw StateError('row2 completed without a final result.');
              }
              expectExactNormalizedTranscript(
                actual: result.text,
                expected: config.liteRtAsrExpectedTranscript,
                label: 'row2.final',
              );
              expectExactNormalizedTranscript(
                actual: finalEvents.single.result.text,
                expected: config.liteRtAsrExpectedTranscript,
                label: 'row2.finalEvent',
              );
            },
            cleanup: () async {
              if (!sessionSettled) {
                await awaitBounded(
                  session.cancel(),
                  _cleanupTimeout,
                  'row2.session.cleanupCancel',
                );
                await awaitBounded(
                  eventsFuture,
                  _cleanupTimeout,
                  'row2.session.cleanupEventsClosed',
                );
              }
            },
          );

          final cancelSession = await awaitBounded(
            liteRtEngine.startStream(),
            _streamTimeout,
            'row2.cancel.start',
          );
          final cancelEventsFuture = collectSpeechEvents(cancelSession.events);
          var cancelSessionSettled = false;
          await runWithSpeechCleanup(
            body: () async {
              await awaitBounded(
                cancelSession.addPcm(
                  chunkPcmSamples(floatSamples, _pcmChunkSamples).first,
                ),
                _streamTimeout,
                'row2.cancel.addPcm',
              );
              await requireStillActiveBeforeCancellation(
                cancelSession.done,
                _activeCancellationObservation,
                'row2.cancel',
              );
              await awaitBounded(
                cancelSession.cancel(),
                _cancelTimeout,
                'row2.cancel.cancel',
              );
              final cancelCompletion = await awaitBounded(
                cancelSession.done,
                _cancelTimeout,
                'row2.cancel.done',
              );
              final cancelEvents = await awaitBounded(
                cancelEventsFuture,
                _cancelTimeout,
                'row2.cancel.eventsClosed',
              );
              cancelSessionSettled = true;
              expect(
                verifySttCancellation(cancelCompletion),
                isTrue,
                reason:
                    'Cancelled stream session must reach the cancelled state',
              );
              expect(
                cancelEvents.whereType<SpeechToTextFinalEvent>(),
                isEmpty,
                reason: 'Cancelled stream session must not emit a final result',
              );
            },
            cleanup: () async {
              if (!cancelSessionSettled) {
                await awaitBounded(
                  cancelSession.cancel(),
                  _cleanupTimeout,
                  'row2.cancel.cleanupCancel',
                );
                await awaitBounded(
                  cancelEventsFuture,
                  _cleanupTimeout,
                  'row2.cancel.cleanupEventsClosed',
                );
              }
            },
          );

          // Fresh recognizer and session over the same pinned files.
          final reloadEngine = SpeechToTextEngine.liteRtLm(runtimeConfig);
          final reloadSession = await awaitBounded(
            reloadEngine.startStream(),
            _streamTimeout,
            'row2.reload.start',
          );
          final reloadEventsFuture = collectSpeechEvents(reloadSession.events);
          var reloadSettled = false;
          await runWithSpeechCleanup(
            body: () async {
              await _pushBoundedPcm(reloadSession, floatSamples, 'row2.reload');
              await awaitBounded(
                reloadSession.finish(),
                _streamTimeout,
                'row2.reload.finish',
              );
              final reloadCompletion = await awaitBounded(
                reloadSession.done,
                _streamTimeout,
                'row2.reload.done',
              );
              final reloadEvents = await awaitBounded(
                reloadEventsFuture,
                _streamTimeout,
                'row2.reload.eventsClosed',
              );
              reloadSettled = true;
              expect(
                reloadCompletion.state,
                equals(SpeechToTextCompletionState.completed),
              );
              expect(
                reloadEvents.whereType<SpeechToTextFinalEvent>(),
                hasLength(1),
              );
              final reloadResult = reloadCompletion.result;
              if (reloadResult == null) {
                throw StateError(
                  'row2 reload completed without a final result.',
                );
              }
              expectExactNormalizedTranscript(
                actual: reloadResult.text,
                expected: config.liteRtAsrExpectedTranscript,
                label: 'row2.reload.final',
              );
              final reloadFinalEvent = reloadEvents
                  .whereType<SpeechToTextFinalEvent>()
                  .single;
              expectExactNormalizedTranscript(
                actual: reloadFinalEvent.result.text,
                expected: config.liteRtAsrExpectedTranscript,
                label: 'row2.reload.finalEvent',
              );
            },
            cleanup: () async {
              if (!reloadSettled) {
                await awaitBounded(
                  reloadSession.cancel(),
                  _cleanupTimeout,
                  'row2.reload.cleanupCancel',
                );
                await awaitBounded(
                  reloadEventsFuture,
                  _cleanupTimeout,
                  'row2.reload.cleanupEventsClosed',
                );
              }
            },
          );

          return SpeechE2ERowResult(
            id: 'litert_lm_streaming_asr',
            status: SpeechE2ERowStatus.pass,
            backend: backendName,
            duration: elapsed.elapsed,
            digestIdentifiers: {
              'model': config.liteRtAsrModelSha256.substring(0, 8),
              'tokenizer': config.liteRtAsrTokenizerSha256.substring(0, 8),
              'fixture': config.liteRtAsrAudioSha256.substring(0, 8),
            },
            assertionSummary:
                'dedicated backend caps verified, bounded PCM chunks streamed, '
                'nonempty partial observed, exactly one final event, exact final '
                'transcript, deterministic cancellation, bounded-chunk reload',
          );
        },
      );
    }

    // =====================================================================
    // ROW 3: llama.cpp Qwen3-TTS
    // =====================================================================
    if (selectedRowIds.contains('llama_cpp_qwen3_tts')) {
      await _recordRow(
        id: 'llama_cpp_qwen3_tts',
        results: rowResults,
        body: (elapsed) async {
          requireValidSpeechArtifacts(artifactFailures, _row3ArtifactLabels);
          final outFile = File(config.ttsOutputPath);
          var ownsOutputFile = false;
          String? backendName;
          await runWithSpeechCleanup(
            body: () async {
              final engine = await _loadCpuEngine(
                config.qwen3TtsModelPath,
                config.qwen3TtsMmprojPath,
                'row3.engine',
              );
              await runWithSpeechCleanup(
                body: () async {
                  final synthesizer = TextToSpeechEngine(
                    engine,
                    modelProfile: TextToSpeechModelProfile.qwen3Tts,
                  );
                  final caps = await awaitBounded(
                    synthesizer.capabilities,
                    _cleanupTimeout,
                    'row3.capabilities',
                  );
                  expect(
                    caps.isSupported,
                    isTrue,
                    reason:
                        caps.unsupportedReason ??
                        'Qwen3-TTS should be supported',
                  );
                  expect(
                    caps.implementation,
                    equals(TextToSpeechImplementation.nativeAudioGeneration),
                  );
                  expect(caps.sampleRateHz, equals(24000));
                  expect(caps.channelCount, equals(1));
                  expect(caps.supportsCancellation, isTrue);
                  final reportedBackend = caps.backendName;
                  final String resolvedBackend;
                  if (reportedBackend case final String value) {
                    resolvedBackend = value;
                  } else {
                    resolvedBackend = await awaitBounded(
                      engine.getBackendName(),
                      _cleanupTimeout,
                      'row3.getBackendName',
                    );
                  }
                  backendName = requireSpeechBackendIdentity(
                    resolvedBackend,
                    SpeechE2EBackendKind.llamaCppCpu,
                  );

                  final synthTask = await awaitBounded(
                    synthesizer.synthesize(
                      TextToSpeechRequest(
                        text: config.ttsText,
                        maxFrames: _ttsMaxCodecFrames,
                        seed: 1,
                      ),
                    ),
                    _synthesizeTimeout,
                    'row3.synthesis.start',
                  );
                  final synthEventsFuture = collectSpeechEvents(
                    synthTask.events,
                  );
                  await runWithSpeechCleanup(
                    body: () async {
                      final completion = await awaitBounded(
                        synthTask.done,
                        _synthesizeTimeout,
                        'row3.synthesis.done',
                      );
                      final synthEvents = await awaitBounded(
                        synthEventsFuture,
                        _synthesizeTimeout,
                        'row3.synthesis.eventsClosed',
                      );
                      expect(
                        completion.state,
                        equals(TextToSpeechCompletionState.completed),
                      );
                      final progressEvents = synthEvents
                          .whereType<TextToSpeechProgressEvent>()
                          .toList();
                      final finalEvents = synthEvents
                          .whereType<TextToSpeechFinalEvent>()
                          .toList();
                      expect(
                        progressEvents,
                        isNotEmpty,
                        reason: 'Expected progress events during synthesis',
                      );
                      expect(
                        finalEvents,
                        hasLength(1),
                        reason: 'Expected exactly one final event',
                      );
                      final synthResult = completion.result;
                      if (synthResult == null) {
                        throw StateError(
                          'row3 completed without synthesized PCM.',
                        );
                      }
                      expect(finalEvents.single.result, same(synthResult));

                      expect(synthResult.samples, isNotEmpty);
                      expect(synthResult.sampleRateHz, equals(24000));
                      expect(synthResult.channelCount, equals(1));
                      expect(
                        synthResult.samples.every((s) => s.isFinite),
                        isTrue,
                        reason: 'Synthesized PCM must be finite',
                      );
                      expect(
                        synthResult.truncated,
                        isFalse,
                        reason:
                            'Exact round-trip validation requires complete speech',
                      );
                      validateTtsResultPlausibility(
                        framesGenerated: synthResult.framesGenerated,
                        maxFrames: _ttsMaxCodecFrames,
                        sampleFrames:
                            synthResult.samples.length ~/
                            synthResult.channelCount,
                        sampleRateHz: synthResult.sampleRateHz,
                        channelCount: synthResult.channelCount,
                        duration: synthResult.duration,
                        label: 'row3.synthesis',
                      );

                      // Export and re-read from disk: never played back.
                      final wavBytes = synthResult.toWavBytes();
                      await awaitBounded(
                        writePhysicalIosSpeechOutputExclusive(config, wavBytes),
                        _cleanupTimeout,
                        'row3.output.writeExclusive',
                      );
                      ownsOutputFile = true;
                      final wavInfo = validatePcm16Wav(
                        await awaitBounded(
                          outFile.readAsBytes(),
                          _cleanupTimeout,
                          'row3.output.read',
                        ),
                        expectedSampleRate: 24000,
                        expectedChannels: 1,
                        requireNonSilent: true,
                      );
                      expect(
                        wavInfo.sampleFrames,
                        equals(
                          synthResult.samples.length ~/
                              synthResult.channelCount,
                        ),
                        reason:
                            'WAV export must preserve every synthesized PCM frame',
                      );
                      expect(wavInfo.peakAmplitude, greaterThan(0));
                      validateTtsResultPlausibility(
                        framesGenerated: synthResult.framesGenerated,
                        maxFrames: _ttsMaxCodecFrames,
                        sampleFrames: wavInfo.sampleFrames,
                        sampleRateHz: wavInfo.sampleRate,
                        channelCount: wavInfo.channels,
                        duration: Duration(
                          microseconds:
                              (wavInfo.durationSeconds *
                                      Duration.microsecondsPerSecond)
                                  .round(),
                        ),
                        label: 'row3.exportedWav',
                      );
                    },
                    cleanup: () => _settleSpeechTask(
                      cancel: synthTask.cancel,
                      done: synthTask.done,
                      eventsClosed: synthEventsFuture,
                      label: 'row3.synthesis',
                    ),
                  );

                  // Cancel only after real audio frames exist.
                  final cancelTask = await awaitBounded(
                    synthesizer.synthesize(
                      TextToSpeechRequest(
                        text: config.ttsText,
                        maxFrames: _ttsCancelMaxCodecFrames,
                        seed: 1,
                      ),
                    ),
                    _synthesizeTimeout,
                    'row3.cancel.start',
                  );
                  final cancellationTriggered = Completer<void>();
                  final cancelEventsFuture = collectSpeechEvents(
                    cancelTask.events.map((event) {
                      if (event is TextToSpeechProgressEvent &&
                          shouldCancelOnTtsProgress(event) &&
                          !cancellationTriggered.isCompleted) {
                        cancellationTriggered.complete();
                        cancelTask.cancel();
                      }
                      return event;
                    }),
                  );
                  await runWithSpeechCleanup(
                    body: () async {
                      await awaitBounded(
                        Future.any<void>(<Future<void>>[
                          cancellationTriggered.future,
                          cancelTask.done.then<void>((_) {
                            if (!cancellationTriggered.isCompleted) {
                              throw StateError(
                                'row3 synthesis settled before it emitted a '
                                'positive generated-frame progress event.',
                              );
                            }
                          }),
                        ]),
                        _synthesizeTimeout,
                        'row3.cancel.firstGeneratedFrame',
                      );
                      final cancelCompletion = await awaitBounded(
                        cancelTask.done,
                        _cancelTimeout,
                        'row3.cancel.done',
                      );
                      final cancelEvents = await awaitBounded(
                        cancelEventsFuture,
                        _cancelTimeout,
                        'row3.cancel.eventsClosed',
                      );
                      expect(
                        cancellationTriggered.isCompleted,
                        isTrue,
                        reason:
                            'Cancellation must follow real generation progress',
                      );
                      expect(
                        verifyTtsCancellation(cancelCompletion),
                        isTrue,
                        reason:
                            'Cancelled synthesis must reach the cancelled state',
                      );
                      expect(
                        cancelEvents.whereType<TextToSpeechFinalEvent>(),
                        isEmpty,
                        reason: 'Cancelled synthesis must not emit final PCM',
                      );
                    },
                    cleanup: () => _settleSpeechTask(
                      cancel: cancelTask.cancel,
                      done: cancelTask.done,
                      eventsClosed: cancelEventsFuture,
                      label: 'row3.cancel',
                    ),
                  );
                },
                cleanup: () => _disposeEngine(engine, 'row3.engine'),
              );

              // Fresh TTS engine on the same immutable paths.
              final reloadEngine = await _loadCpuEngine(
                config.qwen3TtsModelPath,
                config.qwen3TtsMmprojPath,
                'row3.reload',
              );
              await runWithSpeechCleanup(
                body: () async {
                  final reloadTask = await awaitBounded(
                    TextToSpeechEngine(
                      reloadEngine,
                      modelProfile: TextToSpeechModelProfile.qwen3Tts,
                    ).synthesize(
                      TextToSpeechRequest(
                        text: config.ttsText,
                        maxFrames: _ttsReloadMaxCodecFrames,
                        seed: 1,
                      ),
                    ),
                    _synthesizeTimeout,
                    'row3.reload.start',
                  );
                  final reloadEventsFuture = collectSpeechEvents(
                    reloadTask.events,
                  );
                  await runWithSpeechCleanup(
                    body: () async {
                      final reloadCompletion = await awaitBounded(
                        reloadTask.done,
                        _synthesizeTimeout,
                        'row3.reload.done',
                      );
                      final reloadEvents = await awaitBounded(
                        reloadEventsFuture,
                        _synthesizeTimeout,
                        'row3.reload.eventsClosed',
                      );
                      expect(
                        reloadCompletion.state,
                        equals(TextToSpeechCompletionState.completed),
                      );
                      expect(
                        reloadEvents.whereType<TextToSpeechFinalEvent>(),
                        hasLength(1),
                      );
                      final reloadResult = reloadCompletion.result;
                      if (reloadResult == null) {
                        throw StateError('row3 reload completed without PCM.');
                      }
                      expect(
                        reloadEvents
                            .whereType<TextToSpeechFinalEvent>()
                            .single
                            .result,
                        same(reloadResult),
                      );
                      expect(reloadResult.samples, isNotEmpty);
                      expect(reloadResult.sampleRateHz, 24000);
                      expect(reloadResult.channelCount, 1);
                      expect(
                        reloadResult.samples.every((sample) => sample.isFinite),
                        isTrue,
                      );
                      validateTtsResultPlausibility(
                        framesGenerated: reloadResult.framesGenerated,
                        maxFrames: _ttsReloadMaxCodecFrames,
                        sampleFrames:
                            reloadResult.samples.length ~/
                            reloadResult.channelCount,
                        sampleRateHz: reloadResult.sampleRateHz,
                        channelCount: reloadResult.channelCount,
                        duration: reloadResult.duration,
                        label: 'row3.reload',
                      );
                    },
                    cleanup: () => _settleSpeechTask(
                      cancel: reloadTask.cancel,
                      done: reloadTask.done,
                      eventsClosed: reloadEventsFuture,
                      label: 'row3.reload',
                    ),
                  );
                },
                cleanup: () => _disposeEngine(reloadEngine, 'row3.reload'),
              );

              // Non-audible intelligibility: transcribe the exported WAV.
              final asrEngine = await _loadCpuEngine(
                config.qwen3AsrModelPath,
                config.qwen3AsrMmprojPath,
                'row3.roundTrip',
              );
              await runWithSpeechCleanup(
                body: () => _transcribeExact(
                  recognizer: SpeechToTextEngine(
                    asrEngine,
                    modelProfile: SpeechToTextModelProfile.qwen3Asr,
                  ),
                  audioPath: config.ttsOutputPath,
                  expectedTranscript: config.ttsExpectedTranscript,
                  label: 'row3.roundTrip',
                ),
                cleanup: () => _disposeEngine(asrEngine, 'row3.roundTrip'),
              );
            },
            cleanup: () async {
              if (ownsOutputFile) {
                await awaitBounded(
                  deletePhysicalIosSpeechOutput(config),
                  _cleanupTimeout,
                  'row3.output.delete',
                );
              }
            },
          );

          final validatedBackendName = backendName;
          if (validatedBackendName == null) {
            throw StateError('row3 did not resolve its runtime backend.');
          }
          return SpeechE2ERowResult(
            id: 'llama_cpp_qwen3_tts',
            status: SpeechE2ERowStatus.pass,
            backend: validatedBackendName,
            duration: elapsed.elapsed,
            digestIdentifiers: {
              'model': config.qwen3TtsModelSha256.substring(0, 8),
              'mmproj': config.qwen3TtsMmprojSha256.substring(0, 8),
              'roundTripAsrModel': config.qwen3AsrModelSha256.substring(0, 8),
              'roundTripAsrMmproj': config.qwen3AsrMmprojSha256.substring(0, 8),
            },
            assertionSummary:
                'llama.cpp CPU TTS with 0 GPU layers, native 24 kHz mono caps, '
                'progress and exactly one final event, finite nonempty PCM within '
                'codec-frame cap, strict exported WAV read-back with non-silence, '
                'cancellation after real frames, fresh CPU reload, non-audible '
                'exact llama.cpp CPU ASR round-trip with 0 GPU layers, exported '
                'WAV removed',
          );
        },
      );
    }

    // =====================================================================
    // ROW 4: LiteRT-LM TTS (expected unsupported)
    // =====================================================================
    if (selectedRowIds.contains('litert_lm_tts')) {
      await _recordRow(
        id: 'litert_lm_tts',
        results: rowResults,
        body: (elapsed) async {
          requireValidSpeechArtifacts(artifactFailures, _row4ArtifactLabels);
          // The real LiteRT-LM backend, not the llama.cpp router: routing a
          // .litertlm model through LlamaBackend() would prove nothing about the
          // LiteRT-LM synthesis path.
          final engine = LlamaEngine(LiteRtLmBackend());
          String? backendName;
          await runWithSpeechCleanup(
            body: () async {
              await awaitBounded(
                engine.loadModel(
                  config.liteRtLmModelPath,
                  modelParams: const ModelParams(contextSize: 2048),
                ),
                _modelLoadTimeout,
                'row4.loadModel',
              );
              expect(engine.isReady, isTrue);
              backendName = requireSpeechBackendIdentity(
                await awaitBounded(
                  engine.getBackendName(),
                  _cleanupTimeout,
                  'row4.getBackendName',
                ),
                SpeechE2EBackendKind.liteRtLm,
              );

              final synthesizer = TextToSpeechEngine(
                engine,
                modelProfile: TextToSpeechModelProfile.qwen3Tts,
              );
              final caps = await awaitBounded(
                synthesizer.capabilities,
                _cleanupTimeout,
                'row4.capabilities',
              );
              expect(
                classifyLiteRtLmTtsSupport(caps),
                equals(SpeechE2ERowStatus.unsupported),
              );
              expect(caps.unsupportedReason?.trim(), isNotEmpty);
              expect(
                requireSpeechBackendIdentity(
                  caps.backendName ?? '',
                  SpeechE2EBackendKind.liteRtLm,
                ),
                backendName,
              );

              Object? thrown;
              TextToSpeechTask? unexpectedTask;
              try {
                unexpectedTask = await awaitBounded(
                  synthesizer.synthesize(
                    TextToSpeechRequest(text: config.ttsText, maxFrames: 64),
                  ),
                  _cancelTimeout,
                  'row4.synthesize',
                );
              } catch (error) {
                thrown = error;
              }
              final task = unexpectedTask;
              if (task != null) {
                final unexpectedEvents = collectSpeechEvents(task.events);
                await runWithSpeechCleanup(
                  body: () async {
                    throw StateError(
                      'LiteRT-LM synthesize returned a task instead of throwing '
                      'LlamaUnsupportedException.',
                    );
                  },
                  cleanup: () => _settleSpeechTask(
                    cancel: task.cancel,
                    done: task.done,
                    eventsClosed: unexpectedEvents,
                    label: 'row4.unexpectedTask',
                  ),
                );
              }
              if (thrown == null) {
                throw StateError(
                  'LiteRT-LM synthesize reached no observable terminal state.',
                );
              }
              expect(verifyLiteRtLmTtsSynthesisError(thrown), isTrue);
            },
            cleanup: () => _disposeEngine(engine, 'row4.engine'),
          );

          final validatedBackendName = backendName;
          if (validatedBackendName == null) {
            throw StateError('row4 did not resolve its runtime backend.');
          }
          return SpeechE2ERowResult(
            id: 'litert_lm_tts',
            status: SpeechE2ERowStatus.unsupported,
            backend: validatedBackendName,
            duration: elapsed.elapsed,
            digestIdentifiers: {
              'model': config.liteRtLmModelSha256.substring(0, 8),
            },
            assertionSummary:
                'real LiteRT-LM model and backend identity loaded, typed '
                'capabilities report isSupported=false with an actionable '
                'reason, synthesize throws typed LlamaUnsupportedException',
          );
        },
      );
    }

    // =====================================================================
    // Reporting: always emitted, even when a row failed or was unavailable.
    // =====================================================================
    _emitAndValidateResults(rowResults, expectedIds: expectedRowIds);
  });
}
