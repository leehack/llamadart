import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:llamadart/llamadart.dart';

import 'live_asr_pcm.dart';

const micSampleRate = 16000;
const micCaptureSeconds = 20;
const micCancelAfter = Duration(seconds: 8);
const micPhrase =
    'The red bicycle is beside the station. '
    'After the rain stops, we will take the long road past the river. '
    'At the end of the trail, look for the yellow lantern by the wooden gate.';

typedef MicDevice = ({int index, String name});

List<MicDevice> parseMicDevices(String diagnostics) {
  const audioHeader = 'AVFoundation audio devices:';
  final start = diagnostics.indexOf(audioHeader);
  if (start < 0) return [];
  return [
    for (final line in const LineSplitter().convert(
      diagnostics.substring(start + audioHeader.length),
    ))
      if (RegExp(
            r'^\[AVFoundation[^\]]*\]\s+\[(\d+)\]\s+(.+)$',
          ).firstMatch(line)
          case final match?)
        (index: int.parse(match[1]!), name: match[2]!.trim()),
  ];
}

List<String> _words(String text) => RegExp(
  r'[a-z0-9]+',
).allMatches(text.toLowerCase()).map((m) => m[0]!).toList();

double micWordErrorRate(String reference, String transcript) {
  final expected = _words(reference);
  final actual = _words(transcript);
  if (expected.isEmpty) throw ArgumentError('Expected English words.');
  final costs = List<int>.generate(actual.length + 1, (i) => i);
  for (var i = 0; i < expected.length; i++) {
    var diagonal = costs[0]++;
    for (var j = 0; j < actual.length; j++) {
      final above = costs[j + 1];
      costs[j + 1] = min(
        diagonal + (expected[i] == actual[j] ? 0 : 1),
        1 + min(costs[j], above),
      );
      diagonal = above;
    }
  }
  return costs.last / expected.length;
}

class MicCycleReceipt {
  MicCycleReceipt(this.phase);

  final String phase;
  final errors = <String>[];
  final captureWarnings = <String>[];
  int samples = 0;
  int? firstPartialMs;
  bool partialWhileCapturing = false;
  int finalEvents = 0;
  int? finalAfterFinishMs;
  int? recognizerAudioDurationMs;
  int? captureExitCode;
  String? captureStopReason;
  String? captureInputFormat;
  String? transcript;
  String? completion;

  Map<String, Object?> toJson(String reference) => {
    'phase': phase,
    'samples': samples,
    'audio_duration_ms': samples * 1000 ~/ micSampleRate,
    'first_partial_ms': firstPartialMs,
    'partial_while_capturing': partialWhileCapturing,
    'final_event_count': finalEvents,
    'final_after_finish_ms': finalAfterFinishMs,
    'recognizer_audio_duration_ms': recognizerAudioDurationMs,
    'capture_exit_code': captureExitCode,
    'capture_stop_reason': captureStopReason,
    'capture_input_format': captureInputFormat,
    'capture_warnings': captureWarnings,
    'completion': completion,
    'transcript': transcript,
    'word_error_rate': transcript == null
        ? null
        : micWordErrorRate(reference, transcript!),
    'errors': errors,
  };
}

List<String> evaluateMicCycle(
  MicCycleReceipt receipt, {
  required bool cancelExpected,
  required int expectedSamples,
}) {
  if (cancelExpected) {
    return [
      if (receipt.samples == 0) 'Cancellation did not follow a PCM push.',
      if (receipt.completion != 'cancelled') 'Cancellation did not complete.',
      if (receipt.finalEvents != 0) 'A final event escaped cancellation.',
    ];
  }
  return [
    if (receipt.samples != expectedSamples)
      'Expected $expectedSamples PCM samples, received ${receipt.samples}.',
    if (!receipt.partialWhileCapturing) 'No nonempty partial during capture.',
    if (receipt.completion != 'completed' ||
        receipt.finalEvents != 1 ||
        (receipt.transcript?.trim().isEmpty ?? true))
      'Expected one nonempty final after stopping capture.',
    if (receipt.finalAfterFinishMs == null)
      'No final after the finish request.',
  ];
}

Future<ProcessResult> runFfmpegQuery(List<String> arguments) async {
  final process = await Process.start('ffmpeg', arguments);
  const decoder = Utf8Decoder(allowMalformed: true);
  final output = process.stdout.transform(decoder).join();
  final errors = process.stderr.transform(decoder).join();
  final exit = await process.exitCode.timeout(
    const Duration(seconds: 5),
    onTimeout: () async {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
      throw TimeoutException('FFmpeg query timed out.');
    },
  );
  return ProcessResult(process.pid, exit, await output, await errors);
}

Future<List<MicDevice>> listMicDevices() async {
  final result = await runFfmpegQuery([
    '-hide_banner',
    '-nostdin',
    '-f',
    'avfoundation',
    '-list_devices',
    'true',
    '-i',
    '',
  ]);
  final devices = parseMicDevices(result.stderr as String);
  if (devices.isEmpty) {
    throw StateError(
      'No AVFoundation audio inputs were listed.\n${result.stderr}',
    );
  }
  return devices;
}

Future<Process> startMicCapture({
  MicDevice? device,
  String? audioPath,
  Future<Process> Function(String, List<String>) startProcess = Process.start,
}) {
  return startProcess('ffmpeg', [
    '-hide_banner',
    '-loglevel',
    'level+info',
    '-nostats',
    '-nostdin',
    '-xerror',
    if (device != null) ...[
      '-f',
      'avfoundation',
      '-analyzeduration',
      '100000',
      '-probesize',
      '32768',
      '-i',
      ':${device.index}',
    ] else ...[
      '-re',
      '-i',
      audioPath!,
    ],
    '-map',
    '0:a:0',
    '-ac',
    '1',
    '-ar',
    '$micSampleRate',
    '-c:a',
    'pcm_f32le',
    '-f',
    'f32le',
    'pipe:1',
  ]);
}

/// Owns one capture process and the session it feeds.
Future<MicCycleReceipt> captureMicCycle({
  required String phase,
  required SpeechToTextStreamingSession session,
  required Future<Process> Function() startCapture,
  required Future<void> interrupted,
  required void Function(String) report,
  required String Function(Object) redactError,
  Duration? cancelAfter,
  Duration captureDeadline = const Duration(seconds: 50),
  Duration finishDeadline = const Duration(seconds: 45),
  int expectedSamples = micSampleRate * micCaptureSeconds,
}) async {
  final receipt = MicCycleReceipt(phase);
  final clock = Stopwatch();
  final cancel = Completer<void>();
  final eventsDone = Completer<void>();
  var acceptingPcm = false;
  var producerExited = false;
  int? finishStartedMs;
  Timer? cancelTimer;
  Process? producer;
  StreamIterator<Float32List>? reader;
  Future<void>? diagnosticsDone;

  final events = session.events.listen(
    (event) {
      switch (event) {
        case SpeechToTextPartialEvent(:final text) when text.trim().isNotEmpty:
          if (clock.isRunning && receipt.firstPartialMs == null) {
            receipt.firstPartialMs = clock.elapsedMilliseconds;
            report('First partial at ${receipt.firstPartialMs} ms: $text');
          }
          receipt.partialWhileCapturing |=
              clock.isRunning && acceptingPcm && !producerExited;
        case SpeechToTextFinalEvent(:final result):
          receipt.finalEvents++;
          receipt.transcript = result.text;
          receipt.recognizerAudioDurationMs =
              result.audioDuration?.inMilliseconds;
          report('Final: ${result.text}');
          if (finishStartedMs case final start?) {
            receipt.finalAfterFinishMs = clock.elapsedMilliseconds - start;
          }
        case SpeechToTextPartialEvent():
          break;
      }
    },
    onError: (Object error) => receipt.errors.add(redactError(error)),
    onDone: eventsDone.complete,
  );

  Future<bool> pump() async {
    while (acceptingPcm && await reader!.moveNext()) {
      if (!acceptingPcm) return false;
      if (!clock.isRunning) {
        clock.start();
        report('Speak now.');
        if (cancelAfter != null) {
          cancelTimer = Timer(cancelAfter, cancel.complete);
        }
      }
      var pcm = reader!.current;
      // Gaps in input timestamps can make FFmpeg's duration limit cut PCM short.
      final remaining = expectedSamples - receipt.samples;
      if (cancelAfter == null && pcm.length > remaining) {
        pcm = Float32List.sublistView(pcm, 0, remaining);
      }
      await session.addPcm(pcm);
      if (!acceptingPcm) return false;
      receipt.samples += pcm.length;
      if (cancelAfter == null && receipt.samples == expectedSamples) {
        return true;
      }
    }
    return false;
  }

  try {
    producer = await startCapture();
    reader = StreamIterator(readLiveAsrPcm(producer.stdout));
    diagnosticsDone = producer.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .forEach((line) {
          if (receipt.captureInputFormat == null &&
              RegExp(r'Stream #0:\d+.*Audio: ').hasMatch(line)) {
            receipt.captureInputFormat = line.split('Audio: ').last.trim();
          }
          // A mono WAV without an explicit channel mask has no dropped PCM.
          if (RegExp(r'\[(warning|error|fatal)\]').hasMatch(line) &&
              !line.endsWith('[warning] Guessed Channel Layout: mono') &&
              receipt.captureWarnings.length < 12) {
            receipt.captureWarnings.add(redactError(line));
          }
        });
    acceptingPcm = true;
    final producerExit = producer.exitCode.then((status) {
      producerExited = true;
      receipt.captureExitCode = status;
    });
    // Buffered stdout is still valid after a clean process exit.
    final captured = () async {
      if (await pump()) return 'sample_target';
      await producerExit;
      await diagnosticsDone;
      return 'eof';
    }();
    final stop = await Future.any([
      captured,
      cancel.future.then((_) => 'cancel'),
      interrupted.then((_) => 'interrupt'),
    ]).timeout(captureDeadline);
    receipt.captureStopReason = stop;
    acceptingPcm = false;
    if (stop == 'interrupt') {
      throw StateError('Operator interrupted capture.');
    }
    // Raw PCM has no trailer, and flushing could block on unread stdout.
    final signalSent =
        stop != 'eof' &&
        !producerExited &&
        producer.kill(ProcessSignal.sigkill);
    if (stop == 'cancel' && signalSent) {
      report('Cancelling capture.');
      await session.cancel().timeout(finishDeadline);
    }
    await producerExit.timeout(const Duration(seconds: 5));
    await diagnosticsDone.timeout(const Duration(seconds: 5));
    final killedByHarness =
        signalSent &&
        receipt.captureExitCode == -ProcessSignal.sigkill.signalNumber;
    if (receipt.captureWarnings.isNotEmpty ||
        (!killedByHarness && receipt.captureExitCode != 0)) {
      throw StateError(
        'FFmpeg capture failed (exit ${receipt.captureExitCode}).',
      );
    }
    if (cancelAfter != null) {
      if (!killedByHarness) {
        throw StateError('Capture ended before the scheduled cancellation.');
      }
    } else {
      if (receipt.samples != expectedSamples) {
        throw StateError(
          'Capture ended early: ${receipt.samples}/$expectedSamples samples.',
        );
      }
      finishStartedMs = clock.elapsedMilliseconds;
      await Future.any<void>([
        session.finish(),
        interrupted.then<void>((_) {
          throw StateError('Operator interrupted finalization.');
        }),
      ]).timeout(finishDeadline);
    }
    final completion = await session.done.timeout(finishDeadline);
    receipt.completion = completion.state.name;
    if (completion.error case final error?) {
      receipt.errors.add(redactError(error));
    }
    await eventsDone.future.timeout(finishDeadline);
    receipt.errors.addAll(
      evaluateMicCycle(
        receipt,
        cancelExpected: cancelAfter != null,
        expectedSamples: expectedSamples,
      ),
    );
  } on Object catch (error) {
    receipt.errors.add(redactError(error));
  } finally {
    cancelTimer?.cancel();
    acceptingPcm = false;
    try {
      if (producer != null) {
        if (!producerExited) producer.kill(ProcessSignal.sigkill);
        await producer.exitCode.timeout(const Duration(seconds: 5));
      }
      await reader?.cancel().timeout(const Duration(seconds: 5));
      await diagnosticsDone?.timeout(const Duration(seconds: 5));
    } on Object catch (error) {
      receipt.errors.add('Capture cleanup: ${redactError(error)}');
    }
    try {
      await session.cancel().timeout(finishDeadline);
    } on Object catch (error) {
      receipt.errors.add('Session cleanup: ${redactError(error)}');
    } finally {
      await events.cancel();
    }
  }
  return receipt;
}
