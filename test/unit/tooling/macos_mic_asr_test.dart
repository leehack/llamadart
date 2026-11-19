@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:llamadart/llamadart.dart';
import 'package:test/test.dart';

import '../../../example/basic_app/bin/src/live_asr_pcm.dart';
import '../../../example/basic_app/bin/src/macos_mic_asr.dart';

void main() {
  test('device selection uses the audio indexes and preserves names', () {
    expect(
      parseMicDevices('''
[AVFoundation indev @ 0x01] AVFoundation video devices:
[AVFoundation indev @ 0x01] [0] FaceTime Camera
[AVFoundation indev @ 0x01] AVFoundation audio devices:
[AVFoundation indev @ 0x01] [0] ZoomAudioDevice
[AVFoundation indev @ 0x01] [2] USB Desk Mic
[in#0 @ 0x02] Error opening input: Input/output error
'''),
      [(index: 0, name: 'ZoomAudioDevice'), (index: 2, name: 'USB Desk Mic')],
    );
    expect(parseMicDevices('Unrecognized input format: avfoundation'), isEmpty);
  });

  test(
    'decodes fragmented float32 samples in order and rejects trailing bytes',
    () async {
      final bytes = ByteData(12)
        ..setFloat32(0, 0.25, Endian.little)
        ..setFloat32(4, -0.5, Endian.little)
        ..setFloat32(8, 0.75, Endian.little);
      final pcm = bytes.buffer.asUint8List();
      final fragments = Stream.fromIterable([
        pcm.sublist(0, 1),
        pcm.sublist(1, 4),
        pcm.sublist(4, 10),
        <int>[],
        pcm.sublist(10),
      ]);
      expect(
        await readLiveAsrPcm(fragments).expand((chunk) => chunk).toList(),
        [0.25, -0.5, 0.75],
      );
      await expectLater(
        readLiveAsrPcm(Stream.value(pcm.sublist(0, 5))),
        emitsInOrder([
          orderedEquals([0.25]),
          emitsError(isA<FormatException>()),
        ]),
      );
    },
  );

  test('receipt reports WER, duration and measured latency', () {
    final receipt = MicCycleReceipt('restart')
      ..samples = 32000
      ..transcript = 'A red bike, by the river.'
      ..firstPartialMs = 512
      ..partialWhileCapturing = true
      ..completion = 'completed'
      ..finalEvents = 1
      ..finalAfterFinishMs = 32;
    final json = receipt.toJson('A red bicycle by the river');
    expect(json['word_error_rate'], closeTo(1 / 6, 1e-10));
    expect(json['audio_duration_ms'], 2000);
    expect(json['first_partial_ms'], 512);
    expect(json['final_after_finish_ms'], 32);
    expect(json['partial_while_capturing'], isTrue);
    expect(json['errors'], isEmpty);
    expect(micWordErrorRate('A red bike!', 'a RED bike'), 0);
    expect(micWordErrorRate('a bike', 'a fast bike now'), 1);
    expect(micWordErrorRate('a red bike', 'a bike'), closeTo(1 / 3, 1e-10));
    expect(micWordErrorRate('a bike', ''), 1);
    expect(() => micWordErrorRate('', 'a bike'), throwsArgumentError);
  });

  group('owned producer and ASR session', () {
    late Directory scratch;
    late File script;

    setUp(() async {
      scratch = await Directory.systemTemp.createTemp('mic-test-');
      addTearDown(() => scratch.delete(recursive: true));
      script = await File('${scratch.path}/mic-producer.dart').writeAsString(
        r'''
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
Future<void> main(List<String> args) async {
  if (args.first == 'timestamp-gap') {
    final limited = args.contains('-t');
    final count = limited ? 281242 : 321024;
    final pcm = ByteData(count * 4);
    for (var i = 0; i < count; i++) {
      pcm.setFloat32(i * 4, 0.25, Endian.little);
    }
    stdout.add(pcm.buffer.asUint8List());
    await stdout.flush();
    if (!limited) await Future<void>.delayed(const Duration(seconds: 30));
    return;
  }
  if (args.first == 'warning') {
    stderr.writeln('[warning] dropped input');
    await stderr.flush();
  }
  stdout.add([0, 0, 128, 62]);
  await stdout.flush();
  switch (args.first) {
    case 'error':
      stderr.writeln('[error] device failed');
      exitCode = 7;
    case 'stalled' || 'warning':
      await Future<void>.delayed(const Duration(seconds: 30));
    case 'clean':
      await Future<void>.delayed(const Duration(milliseconds: 150));
  }
}
''',
      );
    });

    Future<MicCycleReceipt> run(
      String source,
      _FakeSession session, {
      String phase = 'finish',
      MicDevice? device,
      Duration? cancelAfter,
      int expectedSamples = 1,
      Duration captureDeadline = const Duration(seconds: 5),
      Duration finishDeadline = const Duration(seconds: 2),
    }) async {
      Process? producer;
      final receipt = await captureMicCycle(
        phase: phase,
        session: session,
        startCapture: () async {
          final capture = await startMicCapture(
            device: device,
            audioPath: 'mic-fixture.wav',
            startProcess: (executable, arguments) {
              expect(executable, 'ffmpeg');
              return Process.start(Platform.resolvedExecutable, [
                script.path,
                source,
                ...arguments,
              ]);
            },
          );
          producer = capture;
          if (source == 'clean') session.waitForCaptureExit = capture.exitCode;
          return capture;
        },
        interrupted: Completer<void>().future,
        report: (_) {},
        redactError: (error) => error.toString(),
        cancelAfter: cancelAfter,
        captureDeadline: captureDeadline,
        finishDeadline: finishDeadline,
        expectedSamples: expectedSamples,
      );
      expect(
        await producer!.exitCode.timeout(const Duration(seconds: 1)),
        receipt.captureExitCode,
      );
      return receipt;
    }

    test(
      'captures the full PCM target despite an input timestamp gap',
      () async {
        const target = micSampleRate * micCaptureSeconds;
        final session = _FakeSession();
        final receipt = await run(
          'timestamp-gap',
          session,
          device: (index: 1, name: 'Fake Microphone'),
          expectedSamples: target,
        );
        expect(receipt.errors, isEmpty);
        expect(receipt.samples, target);
        expect(session.samplesReceived, target);
        expect(receipt.captureExitCode, -ProcessSignal.sigkill.signalNumber);
        expect(
          receipt.toJson('a red bike')['capture_stop_reason'],
          'sample_target',
        );
        expect(receipt.finalEvents, 1);
        expect(receipt.finalAfterFinishMs, isNotNull);
      },
      skip: Platform.isWindows,
    );

    test(
      'captures a live partial and a final, cancels, and restarts',
      () async {
        final initial = await run('clean', _FakeSession());
        expect(initial.errors, isEmpty);
        expect(initial.transcript, 'a red bike');
        final cancelled = await run(
          'stalled',
          _FakeSession(),
          phase: 'cancel',
          cancelAfter: const Duration(milliseconds: 40),
        );
        expect(cancelled.errors, isEmpty);
        expect(cancelled.captureStopReason, 'cancel');
        expect(cancelled.captureExitCode, -ProcessSignal.sigkill.signalNumber);
        expect(cancelled.completion, 'cancelled');
        expect(cancelled.finalEvents, 0);
        expect(cancelled.toJson('a red bike')['word_error_rate'], isNull);
        final restart = await run('clean', _FakeSession(), phase: 'restart');
        expect(restart.errors, isEmpty);
      },
      skip: Platform.isWindows,
    );

    test('failed producer and short clean EOF never call finish', () async {
      final failed = _FakeSession();
      final failure = await run('error', failed, expectedSamples: 2);
      expect(failure.captureExitCode, 7);
      expect(failure.captureWarnings.single, contains('device failed'));
      expect(failure.errors.single, contains('capture failed'));
      expect(failed.finishCalls, 0);
      final short = _FakeSession();
      final earlyEof = await run('clean', short, expectedSamples: 2);
      expect(earlyEof.captureStopReason, 'eof');
      expect(earlyEof.errors.single, contains('ended early'));
      expect(short.finishCalls, 0);
    });

    test('a capture warning still fails after reaching the target', () async {
      final session = _FakeSession();
      final receipt = await run('warning', session);
      expect(receipt.captureStopReason, 'sample_target');
      expect(receipt.captureExitCode, -ProcessSignal.sigkill.signalNumber);
      expect(receipt.captureWarnings.single, contains('dropped input'));
      expect(receipt.errors.single, contains('capture failed'));
      expect(session.finishCalls, 0);
    }, skip: Platform.isWindows);

    test('rejects a partial emitted only at finish', () async {
      final receipt = await run('clean', _FakeSession(latePartial: true));
      expect(receipt.transcript, 'a red bike');
      expect(
        receipt.errors.single,
        contains('No nonempty partial during capture'),
      );
      expect(receipt.partialWhileCapturing, isFalse);
    });

    test('rejects a final emitted during cancellation', () async {
      final receipt = await run(
        'stalled',
        _FakeSession(finalOnCancel: true),
        cancelAfter: const Duration(milliseconds: 40),
      );
      expect(receipt.errors.single, contains('final event escaped'));
    }, skip: Platform.isWindows);

    test(
      'deadlines reap the child and cancel a stalled push or finish',
      () async {
        final blockedPush = _FakeSession(stallPush: true);
        final stalled = await run(
          'stalled',
          blockedPush,
          captureDeadline: const Duration(milliseconds: 1500),
        );
        expect(stalled.errors.single, contains('TimeoutException'));
        expect(blockedPush.cancelled, isTrue);
        final blockedFinish = _FakeSession(stallFinish: true);
        final finishing = await run(
          'clean',
          blockedFinish,
          finishDeadline: const Duration(milliseconds: 60),
        );
        expect(finishing.errors.single, contains('TimeoutException'));
        expect(blockedFinish.cancelled, isTrue);
      },
    );
  });
}

class _FakeSession implements SpeechToTextStreamingSession {
  _FakeSession({
    this.latePartial = false,
    this.finalOnCancel = false,
    this.stallPush = false,
    this.stallFinish = false,
  });

  final bool latePartial;
  final bool finalOnCancel;
  final bool stallPush;
  final bool stallFinish;
  final _events = StreamController<SpeechToTextEvent>();
  final _done = Completer<SpeechToTextCompletion>();
  final _pending = Completer<void>();
  Future<int>? waitForCaptureExit;
  int samplesReceived = 0;
  int finishCalls = 0;
  bool cancelled = false;

  @override
  Stream<SpeechToTextEvent> get events => _events.stream;

  @override
  Future<SpeechToTextCompletion> get done => _done.future;

  @override
  Future<void> addPcm(Float32List samples) async {
    expect(samples.every((sample) => sample == 0.25), isTrue);
    samplesReceived += samples.length;
    if (stallPush) await _pending.future;
    if (!latePartial && !cancelled) {
      _events.add(const SpeechToTextPartialEvent('a red'));
    }
    await waitForCaptureExit;
  }

  @override
  Future<void> finish() async {
    finishCalls++;
    if (stallFinish) {
      await _pending.future;
      return;
    }
    if (latePartial) _events.add(const SpeechToTextPartialEvent('a red'));
    const result = SpeechToTextResult(text: 'a red bike');
    _events.add(const SpeechToTextFinalEvent(result));
    _done.complete(SpeechToTextCompletion.completed(result));
    await _events.close();
  }

  @override
  Future<void> cancel() async {
    if (_done.isCompleted) return;
    cancelled = true;
    if (finalOnCancel) {
      _events.add(
        const SpeechToTextFinalEvent(SpeechToTextResult(text: 'late')),
      );
    }
    _done.complete(const SpeechToTextCompletion.cancelled());
    _pending.complete();
    await _events.close();
  }
}
