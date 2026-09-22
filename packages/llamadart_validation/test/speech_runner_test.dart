import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_validation/llamadart_validation.dart';
import 'package:llamadart_validation/src/speech_edge_fixtures.dart';
import 'package:llamadart_validation/src/speech_runner.dart';
import 'package:test/test.dart';

class FakeSpeech implements SpeechValidationAdapter {
  final calls = <String>[];
  bool ignoreInvalid = false;
  bool wrongWords = false;
  bool failLoad = false;
  bool failCleanup = false;
  Object? invalidError;
  @override
  Future<void> load() async {
    calls.add('load');
    if (failLoad) throw StateError('load failure');
  }

  @override
  Future<void> dispose() async {
    calls.add('dispose');
    if (failCleanup) throw StateError('cleanup failure');
  }

  @override
  Future<Map<String, Object?>> execute({
    bool cancel = false,
    bool invalid = false,
    bool bytesInput = false,
  }) async {
    calls.add(
      cancel
          ? 'cancel'
          : invalid
          ? 'invalid'
          : 'execute',
    );
    if (invalid && !ignoreInvalid) {
      throw invalidError ?? ArgumentError('invalid');
    }
    return {'predicate_passed': !wrongWords, if (cancel) 'cancelled': true};
  }
}

class FakeEdgeSpeech extends FakeSpeech implements SpeechEdgeCaseAdapter {
  FakeEdgeSpeech({this.failEdge});
  final String? failEdge;

  @override
  Future<Map<String, Object?>> executeEdge(SpeechEdgeFixture fixture) async {
    calls.add('edge:${fixture.id}');
    return {'predicate_passed': fixture.id != failEdge};
  }
}

class FakeSpeechEngine implements LlamaEngine {
  FakeSpeechEngine({this.deltas = const <String>[], this.failure});
  final List<String> deltas;
  final Object? failure;
  final loaded = <String>[];
  var generations = 0;
  var disposals = 0;

  @override
  bool get isReady => true;

  @override
  Future<bool> get supportsAudio async => true;

  @override
  Future<String> getBackendName() async => 'cpu';

  @override
  Future<int?> getResolvedGpuLayers() async => 0;

  @override
  Future<void> setLogLevel(LlamaLogLevel level) async {}

  @override
  Future<void> loadModel(
    String path, {
    ModelParams modelParams = const ModelParams(),
  }) async => loaded.add(path);

  @override
  Future<void> loadMultimodalProjector(String mmProjPath) async =>
      loaded.add(mmProjPath);

  @override
  void cancelGeneration() {}

  @override
  Future<void> dispose() async => disposals++;

  @override
  Stream<LlamaCompletionChunk> create(
    List<LlamaChatMessage> messages, {
    GenerationParams? params,
    List<ToolDefinition>? tools,
    ToolChoice? toolChoice,
    bool parallelToolCalls = false,
    bool enableThinking = true,
    Map<String, dynamic>? responseFormat,
    String? sourceLangCode,
    String? targetLangCode,
    Map<String, dynamic>? chatTemplateKwargs,
    DateTime? templateNow,
  }) async* {
    generations++;
    if (failure != null) throw failure!;
    for (final delta in deltas) {
      yield LlamaCompletionChunk(
        id: 'edge',
        object: 'chat.completion.chunk',
        created: 0,
        model: 'fake',
        choices: [
          LlamaCompletionChunkChoice(
            index: 0,
            delta: LlamaCompletionChunkDelta(content: delta),
          ),
        ],
      );
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'speech input rejection accepts contract errors, not inference failures',
    () async {
      for (final error in [
        LlamaAudioFormatException('Encoded audio bytes must not be empty.'),
        LlamaTextToSpeechException('Text to synthesize must not be empty.'),
        LlamaTextToSpeechException('Synthesis failed.'),
        LlamaInferenceException('Generation failed.'),
      ]) {
        final adapter = FakeSpeech()..invalidError = error;
        final result = await runSpeechValidation(adapter);
        final checks = result['checks'] as List;
        final rejection = checks.singleWhere(
          (item) => item['id'] == 'invalid_input',
        );
        final accepted =
            error is LlamaAudioFormatException ||
            error.message == 'Text to synthesize must not be empty.';
        expect(rejection['status'], accepted ? 'PASS' : 'FAIL');
        expect(result['functional_pass'], accepted);
        expect(result['qualified'], false);
        expect(
          checks.singleWhere((item) => item['id'] == 'after_invalid')['status'],
          'PASS',
        );
        expect(adapter.calls.last, 'dispose');
      }
    },
  );

  test(
    'WER counts substitutions, insertions, deletions and rejects empty oracle',
    () {
      expect(speechWordErrorRate('Hello, WORLD!', 'hello world'), 0);
      expect(speechWordErrorRate('one two', 'one three four'), 1);
      expect(speechWordErrorRate('one two', 'one'), .5);
      expect(speechWordErrorRate('one', 'two three four'), 3);
      expect(speechWordErrorRate('Montréal 한글', 'Montréal 한글'), 0);
      expect(() => speechWordErrorRate(' ', 'hello'), throwsArgumentError);
    },
  );
  TextToSpeechResult audio(List<double> values, {bool truncated = false}) =>
      TextToSpeechResult(
        samples: Float32List.fromList(values),
        sampleRateHz: 24000,
        channelCount: 1,
        framesGenerated: 1,
        truncated: truncated,
      );
  test('nonempty bytes alone cannot qualify invalid or truncated TTS', () {
    for (final result in [
      audio([]),
      audio([0, 0]),
      audio([double.nan]),
      audio([double.infinity]),
      audio([.5], truncated: true),
    ]) {
      expect(() => inspectSpeechAudio(result), throwsStateError);
    }
    final result = inspectSpeechAudio(audio([.25, -.25]));
    expect(result['audio_seconds'], closeTo(2 / 24000, .0000001));
    expect(result['listening_check'], 'NOT_RUN');
  });
  test(
    'locked fixture validates PCM duration and rejects malformed headers',
    () {
      final bytes = File('assets/speech/jfk.wav').readAsBytesSync();
      expect(speechFixtureSeconds(bytes), greaterThan(1));
      for (final bad in [
        Uint8List(0),
        Uint8List.fromList(bytes.sublist(0, 50)),
        Uint8List.fromList(bytes)..[0] = 0,
      ]) {
        expect(() => speechFixtureSeconds(bad), throwsFormatException);
      }
      final lock = jsonDecode(
        File('assets/speech/stt.json').readAsStringSync(),
      );
      expect(sha256.convert(bytes).toString(), lock['fixture']['sha256']);
      expect(bytes.length, lock['fixture']['bytes']);
    },
  );
  test('locks parse as immutable model and projector inputs', () {
    for (final pack in ['stt', 'tts']) {
      final lock = jsonDecode(
        File('assets/speech/$pack.json').readAsStringSync(),
      );
      for (final name in ['model', 'projector']) {
        final profile = ValidationProfile.fromJson({
          'schema_version': 1,
          'id': 'speech-$pack-$name',
          'runtime': 'gguf',
          'backend': 'cpu',
          'model': lock[name],
        });
        profile.requireRunnable();
      }
    }
  });
  test(
    'successful lifecycle includes cancellation, rejection and independent reload',
    () async {
      final adapter = FakeSpeech();
      final result = await runSpeechValidation(adapter);
      expect(result['functional_pass'], true);
      expect(result['qualified'], false);
      expect(adapter.calls, [
        'load',
        'execute',
        'cancel',
        'execute',
        'invalid',
        'execute',
        'dispose',
        'load',
        'execute',
        'dispose',
      ]);
    },
  );
  test('wrong transcript and ignored invalid inputs cannot pass', () async {
    for (final adapter in [
      FakeSpeech()..wrongWords = true,
      FakeSpeech()..ignoreInvalid = true,
    ]) {
      expect((await runSpeechValidation(adapter))['functional_pass'], false);
      expect(adapter.calls.last, 'dispose');
    }
  });
  test('load and cleanup failures remain failures', () async {
    for (final adapter in [
      FakeSpeech()..failLoad = true,
      FakeSpeech()..failCleanup = true,
    ]) {
      expect((await runSpeechValidation(adapter))['functional_pass'], false);
      expect(adapter.calls.last, 'dispose');
    }
  });
  test('edge fixtures describe the inputs they encode', () {
    final source = File('assets/speech/jfk.wav').readAsBytesSync();
    final fixtures = buildSpeechEdgeFixtures(Uint8List.fromList(source));
    expect(fixtures.map((fixture) => fixture.id), [
      'edge_silence',
      'edge_truncated_riff',
      'edge_stereo_44100',
      'edge_long_boundary',
    ]);
    for (final fixture in fixtures) {
      expect(fixture.bytes.length, lessThanOrEqualTo(speechFixtureByteCap));
      expect(String.fromCharCodes(fixture.bytes.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(fixture.bytes.sublist(8, 12)), 'WAVE');
      expect(
        fixture.rejectionMessage != null,
        fixture.contract == SpeechEdgeContract.typedRejection,
      );
    }
    final byId = {for (final fixture in fixtures) fixture.id: fixture};
    expect(
      byId['edge_silence']!.rejectionMessage,
      'Speech recognition produced an empty transcript.',
    );
    expect(
      byId['edge_truncated_riff']!.contract,
      SpeechEdgeContract.unrelatedTranscriptOrFormatRejection,
    );
    expect(
      speechFixtureSeconds(byId['edge_silence']!.bytes),
      byId['edge_silence']!.seconds,
    );
    expect(
      speechFixtureSeconds(byId['edge_long_boundary']!.bytes),
      byId['edge_long_boundary']!.seconds,
    );
    expect(byId['edge_long_boundary']!.seconds, greaterThan(30));
    expect(
      byId['edge_long_boundary']!.referenceRepeats,
      greaterThanOrEqualTo(2),
    );
    for (final id in ['edge_stereo_44100', 'edge_truncated_riff']) {
      expect(
        () => speechFixtureSeconds(byId[id]!.bytes),
        throwsFormatException,
      );
    }
    final silence = byId['edge_silence']!.bytes;
    expect(silence.sublist(44).every((byte) => byte == 0), isTrue);
    final truncated = byId['edge_truncated_riff']!.bytes;
    expect(truncated, source.sublist(0, truncated.length));
    expect(
      ByteData.sublistView(truncated).getUint32(4, Endian.little) + 8,
      greaterThan(truncated.length),
    );
    final stereo = ByteData.sublistView(byId['edge_stereo_44100']!.bytes);
    expect(stereo.getUint16(22, Endian.little), 2);
    expect(stereo.getUint32(24, Endian.little), 44100);
    for (var frame = 0; frame < 2000; frame++) {
      expect(
        stereo.getInt16(44 + frame * 4, Endian.little),
        stereo.getInt16(46 + frame * 4, Endian.little),
      );
    }
  });
  test('edge contracts credit exactly the outcome they name', () {
    SpeechEdgeFixture fixtureFor(
      SpeechEdgeContract contract, {
      String? rejectionMessage,
    }) => SpeechEdgeFixture(
      id: contract.name,
      bytes: Uint8List(0),
      sampleRateHz: 16000,
      channelCount: 1,
      seconds: 1,
      contract: contract,
      referenceRepeats: 1,
      rationale: 'table',
      rejectionMessage: rejectionMessage,
    );
    const expectedMessage = 'Speech recognition produced an empty transcript.';
    final rejecting = fixtureFor(
      SpeechEdgeContract.typedRejection,
      rejectionMessage: expectedMessage,
    );
    final unrelated = fixtureFor(SpeechEdgeContract.unrelatedTranscript);
    final tolerant = fixtureFor(
      SpeechEdgeContract.unrelatedTranscriptOrFormatRejection,
    );
    final repeated = fixtureFor(SpeechEdgeContract.repeatedReference);

    expect(speechEdgeTranscriptHolds(rejecting, 0), isFalse);
    expect(speechEdgeTranscriptHolds(rejecting, 1), isFalse);
    expect(speechEdgeTranscriptHolds(unrelated, 0), isFalse);
    expect(speechEdgeTranscriptHolds(unrelated, 0.25), isTrue);
    expect(speechEdgeTranscriptHolds(tolerant, 0), isFalse);
    expect(speechEdgeTranscriptHolds(tolerant, 0.25), isTrue);
    expect(speechEdgeTranscriptHolds(repeated, 0), isTrue);
    expect(speechEdgeTranscriptHolds(repeated, 0.25), isFalse);

    bool rejectionHolds(
      SpeechEdgeFixture fixture, {
      required String message,
      required bool isAudioFormat,
    }) => speechEdgeRejectionHolds(
      fixture,
      message: message,
      isAudioFormat: isAudioFormat,
    );
    expect(
      rejectionHolds(rejecting, message: expectedMessage, isAudioFormat: false),
      isTrue,
    );
    expect(
      rejectionHolds(
        rejecting,
        message: 'Speech recognition failed.',
        isAudioFormat: false,
      ),
      isFalse,
    );
    expect(
      rejectionHolds(
        rejecting,
        message: 'Speech recognition failed.',
        isAudioFormat: true,
      ),
      isFalse,
    );
    expect(
      rejectionHolds(tolerant, message: 'bad header', isAudioFormat: true),
      isTrue,
    );
    expect(
      rejectionHolds(tolerant, message: 'bad header', isAudioFormat: false),
      isFalse,
    );
    for (final fixture in [unrelated, repeated]) {
      for (final isAudioFormat in [true, false]) {
        expect(
          rejectionHolds(
            fixture,
            message: expectedMessage,
            isAudioFormat: isAudioFormat,
          ),
          isFalse,
        );
      }
    }
  });
  test('edge fixtures are opt-in and deliberately counted', () async {
    final fixtures = buildSpeechEdgeFixtures(
      Uint8List.fromList(File('assets/speech/jfk.wav').readAsBytesSync()),
    );
    final lifecycleOnly = await runSpeechValidation(FakeEdgeSpeech());
    expect(lifecycleOnly['expected_checks'], speechLifecycleCheckCount);
    expect(lifecycleOnly['edge_fixture_ids'], isEmpty);
    expect(lifecycleOnly['functional_pass'], true);
    final adapter = FakeEdgeSpeech();
    final withEdges = await runSpeechValidation(
      adapter,
      checkBytes: true,
      edgeFixtures: fixtures,
    );
    expect(
      withEdges['expected_checks'],
      speechLifecycleCheckCount + 1 + fixtures.length,
    );
    expect(withEdges['functional_pass'], true);
    expect(
      (withEdges['checks'] as List),
      hasLength(withEdges['expected_checks']),
    );
    expect(adapter.calls, [
      'load',
      'execute',
      'execute',
      'cancel',
      'execute',
      'invalid',
      'execute',
      for (final fixture in fixtures) 'edge:${fixture.id}',
      'dispose',
      'load',
      'execute',
      'dispose',
    ]);
  });
  test(
    'a failing edge fixture cannot pass, and unsupported adapters throw',
    () {
      final fixtures = buildSpeechEdgeFixtures(
        Uint8List.fromList(File('assets/speech/jfk.wav').readAsBytesSync()),
      );
      expect(
        () => runSpeechValidation(FakeSpeech(), edgeFixtures: fixtures),
        throwsArgumentError,
      );
      for (final fixture in fixtures) {
        expectLater(
          runSpeechValidation(
            FakeEdgeSpeech(failEdge: fixture.id),
            edgeFixtures: fixtures,
          ).then((result) {
            final checks = result['checks'] as List;
            return [
              result['functional_pass'],
              checks.singleWhere((row) => row['id'] == fixture.id)['status'],
            ];
          }),
          completion([false, 'FAIL']),
        );
      }
    },
  );
  const edgeReference = 'and so my fellow americans';
  Map<String, SpeechEdgeFixture> edgeFixturesById() => {
    for (final fixture in buildSpeechEdgeFixtures(
      Uint8List.fromList(File('assets/speech/jfk.wav').readAsBytesSync()),
    ))
      fixture.id: fixture,
  };
  PublicSpeechValidationAdapter edgeAdapter({
    String pack = 'stt',
    List<String> deltas = const <String>[],
    Object? failure,
  }) => PublicSpeechValidationAdapter(
    model: 'model.gguf',
    projector: 'mmproj.gguf',
    backend: GpuBackend.cpu,
    pack: pack,
    audio: Uint8List(44),
    audioSeconds: 1,
    reference: edgeReference,
    saveAudio: (_) async {},
    createEngine: () => FakeSpeechEngine(deltas: deltas, failure: failure),
  );
  Future<Map<String, Object?>> recognizeEdge(
    SpeechEdgeFixture fixture, {
    List<String> deltas = const <String>[],
    Object? failure,
  }) async {
    final adapter = edgeAdapter(deltas: deltas, failure: failure);
    await adapter.load();
    try {
      return await adapter.executeEdge(fixture);
    } finally {
      await adapter.dispose();
    }
  }

  test('edge recognition scores the repeats the fixture demands', () async {
    final byId = edgeFixturesById();
    final stereo = byId['edge_stereo_44100']!;
    final long = byId['edge_long_boundary']!;
    expect(stereo.referenceRepeats, 1);
    expect(long.referenceRepeats, greaterThanOrEqualTo(2));

    final single = await recognizeEdge(stereo, deltas: [edgeReference]);
    expect(single['predicate_passed'], isTrue);
    expect(single['wer'], 0);
    expect(single['transcript'], edgeReference);
    expect(single['reference_repeats'], 1);

    final wrongWords = await recognizeEdge(stereo, deltas: ['ask not why']);
    expect(wrongWords['predicate_passed'], isFalse);
    expect(wrongWords['wer'], greaterThan(0));

    final repeated = await recognizeEdge(
      long,
      deltas: [List.filled(long.referenceRepeats, edgeReference).join(' ')],
    );
    expect(repeated['predicate_passed'], isTrue);
    expect(repeated['wer'], 0);
    expect(repeated['reference_repeats'], long.referenceRepeats);

    for (final repeats in [1, long.referenceRepeats + 1]) {
      final mismatched = await recognizeEdge(
        long,
        deltas: [List.filled(repeats, edgeReference).join(' ')],
      );
      expect(mismatched['predicate_passed'], isFalse);
      expect(mismatched['wer'], greaterThan(0));
    }
  });

  test('edge rejection credits only the outcome the contract names', () async {
    final byId = edgeFixturesById();
    final silence = byId['edge_silence']!;
    final truncated = byId['edge_truncated_riff']!;

    final empty = await recognizeEdge(silence);
    expect(empty['predicate_passed'], isTrue);
    expect(empty['rejected_with'], 'LlamaSpeechException');
    expect(empty['message'], silence.rejectionMessage);
    expect(empty.containsKey('transcript'), isFalse);
    expect(empty.containsKey('wer'), isFalse);

    final otherFailure = await recognizeEdge(
      silence,
      failure: LlamaSpeechException('Speech recognition failed.'),
    );
    expect(otherFailure['predicate_passed'], isFalse);
    expect(otherFailure['rejected_with'], 'LlamaSpeechException');
    expect(otherFailure['message'], 'Speech recognition failed.');

    final transcribedSilence = await recognizeEdge(
      silence,
      deltas: [edgeReference],
    );
    expect(transcribedSilence['predicate_passed'], isFalse);
    expect(transcribedSilence['transcript'], edgeReference);

    final formatRejection = await recognizeEdge(
      truncated,
      failure: LlamaAudioFormatException('Unsupported RIFF header.'),
    );
    expect(formatRejection['predicate_passed'], isTrue);
    expect(formatRejection['rejected_with'], 'LlamaAudioFormatException');

    final plainRejection = await recognizeEdge(
      truncated,
      failure: LlamaSpeechException('Speech recognition failed.'),
    );
    expect(plainRejection['predicate_passed'], isFalse);

    final unrelated = await recognizeEdge(truncated, deltas: ['Answer.']);
    expect(unrelated['predicate_passed'], isTrue);
    expect(unrelated['wer'], greaterThan(0));

    final reproduced = await recognizeEdge(truncated, deltas: [edgeReference]);
    expect(reproduced['predicate_passed'], isFalse);
    expect(reproduced['wer'], 0);
  });

  test('edge measurement reports the fixture and guards its pack', () async {
    final byId = edgeFixturesById();
    final stereo = byId['edge_stereo_44100']!;
    final measured = await recognizeEdge(stereo, deltas: [edgeReference]);
    expect(measured['contract'], stereo.contract.name);
    expect(measured['rationale'], stereo.rationale);
    expect(measured['fixture_bytes'], stereo.bytes.length);
    expect(measured['sample_rate_hz'], 44100);
    expect(measured['channels'], 2);
    expect(measured['audio_seconds'], stereo.seconds);
    expect(measured['elapsed_ms'], isA<double>());

    await expectLater(
      edgeAdapter().executeEdge(stereo),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'Speech engine is not loaded',
        ),
      ),
    );

    final tts = edgeAdapter(pack: 'tts');
    await tts.load();
    await expectLater(
      tts.executeEdge(stereo),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'Speech edge fixtures require the STT pack',
        ),
      ),
    );
    await tts.dispose();
  });

  test(
    'existing output directory is never modified on CLI rejection',
    () async {
      final directory = Directory.systemTemp.createTempSync('speech-output-');
      try {
        final sentinel = File('${directory.path}/failure.json')
          ..writeAsStringSync('keep');
        final result = await Process.run(Platform.resolvedExecutable, [
          'run',
          'bin/speech.dart',
          '--pack',
          'tts',
          '--out',
          directory.path,
        ]);
        expect(result.exitCode, isNot(0));
        expect(sentinel.readAsStringSync(), 'keep');
        expect(directory.listSync(), hasLength(1));
      } finally {
        directory.deleteSync(recursive: true);
      }
    },
  );
}
