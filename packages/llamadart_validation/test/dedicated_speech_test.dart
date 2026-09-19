import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart_validation/src/speech_runner.dart';
import 'package:test/test.dart';

class Recognizer implements SpeechToTextEngine {
  final session = Session();
  @override
  Future<SpeechToTextCapabilities> get capabilities async =>
      const SpeechToTextCapabilities(isSupported: true);
  @override
  Future<SpeechToTextStreamingSession> startStream({
    SpeechAudioFormat? format,
  }) async {
    if (format?.sampleRateHz == 8000) throw ArgumentError('unsupported');
    return session;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Session implements SpeechToTextStreamingSession {
  final controller = StreamController<SpeechToTextEvent>();
  final completion = Completer<SpeechToTextCompletion>();
  int samples = 0;
  int largestPush = 0;
  bool omitFinal = false;
  bool emitError = false;
  bool cancelCalled = false;
  @override
  Stream<SpeechToTextEvent> get events => controller.stream;
  @override
  Future<SpeechToTextCompletion> get done => completion.future;
  @override
  Future<void> addPcm(Float32List pcm) async {
    samples += pcm.length;
    if (pcm.length > largestPush) largestPush = pcm.length;
  }

  @override
  Future<void> finish() async {
    const result = SpeechToTextResult(text: 'expected');
    completion.complete(SpeechToTextCompletion.completed(result));
    // Deliberately deliver after completion, testing stream draining.
    scheduleMicrotask(() {
      if (emitError) controller.addError(StateError('stream failure'));
      if (!omitFinal) controller.add(const SpeechToTextFinalEvent(result));
      controller.close();
    });
  }

  @override
  Future<void> cancel() async {
    cancelCalled = true;
    if (!completion.isCompleted) {
      completion.complete(const SpeechToTextCompletion.cancelled());
      await controller.close();
    }
  }
}

void main() {
  PublicDedicatedSpeechAdapter adapter(Recognizer recognizer) =>
      PublicDedicatedSpeechAdapter(
        config: const LiteRtLmAsrRuntimeConfig(
          modelPath: 'fixture',
          tokenizerPath: 'fixture',
          modelPreset: LiteRtLmAsrModelPreset.moonshineTiny,
        ),
        wav: File('assets/speech/jfk.wav').readAsBytesSync(),
        reference: 'expected',
        createRecognizer: (_) => recognizer,
      );
  test(
    'CPU adapter pushes bounded PCM and drains delayed final before passing',
    () async {
      final engine = Recognizer();
      final target = adapter(engine);
      await target.load();
      final result = await target.execute();
      expect(result['predicate_passed'], true);
      expect(engine.session.samples, 176000);
      expect(engine.session.largestPush, 1600);
      expect(engine.session.cancelCalled, true);
      await target.dispose();
    },
  );
  test(
    'missing final and stream errors cannot be masked by completed future',
    () async {
      for (final error in [false, true]) {
        final engine = Recognizer();
        engine.session.omitFinal = !error;
        engine.session.emitError = error;
        final target = adapter(engine);
        await target.load();
        await expectLater(target.execute(), throwsStateError);
        expect(engine.session.cancelCalled, true);
        await target.dispose();
      }
    },
  );
  test(
    'invalid sample-rate is exercised through public streaming contract',
    () async {
      final target = adapter(Recognizer());
      await target.load();
      await expectLater(target.execute(invalid: true), throwsArgumentError);
      await target.dispose();
    },
  );
}
