@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:llamadart/llamadart.dart';
import 'package:test/test.dart';

import '../../../support/decision_fixture.dart';

const _headHandle = 7;
const _headPath = 'laya-head.safetensors';

void main() {
  final fixture = DecisionFixture.load();
  final cases = <String, List<DecisionFixtureRow>>{};
  for (final row in fixture.rows) {
    (cases[row.caseId] ??= []).add(row);
  }

  DecisionRequest requestOf(List<DecisionFixtureRow> rows) => DecisionRequest(
    state: rows.first.state,
    questions: {
      for (final row in rows)
        row.questionId: DecisionQuestion.fromJson(row.question),
    },
  );

  late _DecisionBackend backend;
  late LlamaEngine engine;

  setUp(() {
    backend = _DecisionBackend(fixture);
    engine = LlamaEngine(backend);
  });

  tearDown(() => engine.dispose());

  Future<DecisionEngine> loadDecisions() async {
    await engine.loadModel('laya-Q8_0.gguf');
    return DecisionEngine.load(engine, headPath: _headPath);
  }

  group('end to end on the Laya reference fixture', () {
    test('answers all 24 rows in one backend call', () async {
      final decisions = await loadDecisions();
      final caseRows = cases.values.toList();

      final results = await decisions.systemOneBatch([
        for (final rows in caseRows) requestOf(rows),
      ]);

      final sent = backend.runs.single;
      final expectedRows = caseRows.expand((rows) => rows).toList();
      expect(sent, hasLength(24));
      for (var i = 0; i < sent.length; i++) {
        final row = expectedRows[i];
        final question = DecisionQuestion.fromJson(row.question);
        expect(sent[i].tokens, row.ids, reason: row.id);
        expect(sent[i].markers, row.markers, reason: row.id);
        expect(sent[i].questionType, question.type, reason: row.id);
      }
      expect(backend.runHandles, [_headHandle]);
      expect(results, hasLength(caseRows.length));
      for (var c = 0; c < caseRows.length; c++) {
        final rows = caseRows[c];
        final result = results[c];
        expect(result.model, 'laya-rl-agent');
        expect(result.answers.keys, [for (final row in rows) row.questionId]);
        for (final row in rows) {
          expectDecisionJsonClose(
            result.answers[row.questionId]!.toJson(),
            row.answer,
            row.id,
          );
        }
        expect(
          result.usage.inputTokens,
          rows.fold<int>(0, (total, row) => total + row.ids.length),
        );
        expect(result.usage.outputTokens, 0);
      }
    });

    test('tokenizes each distinct text once without special tokens', () async {
      final decisions = await loadDecisions();

      await decisions.systemOneBatch([
        requestOf(cases['readme']!),
        requestOf(cases['readme']!),
      ]);

      expect(backend.tokenized, isNotEmpty);
      expect(backend.tokenized.toSet(), hasLength(backend.tokenized.length));
      expect(backend.addSpecialFlags, everyElement(isFalse));
      expect(backend.runs.single, hasLength(8));
    });

    test('systemOne answers one request in the Laya response shape', () async {
      final decisions = await loadDecisions();
      final rows = cases['readme']!;

      final result = await decisions.systemOne(
        state: rows.first.state,
        questions: requestOf(rows).questions,
      );

      expect(result.choices['department']!.choice, 'billing');
      final json = result.toJson();
      expect(json['model'], 'laya-rl-agent');
      expect(json['usage'], {
        'input_tokens': rows.fold<int>(
          0,
          (total, row) => total + row.ids.length,
        ),
        'output_tokens': 0,
      });
      for (final row in rows) {
        expectDecisionJsonClose(
          (json['answers'] as Map)[row.questionId],
          row.answer,
          row.id,
        );
      }
    });
  });

  group('load', () {
    test('passes the head and config paths and reports model info', () async {
      backend.config = {'max_len': 256, 'head_max_len': 96};
      await engine.loadModel('laya-Q8_0.gguf');

      final decisions = await DecisionEngine.load(
        engine,
        headPath: 'model.safetensors',
        configPath: 'rl_agent_config.json',
      );

      expect(backend.headLoads, [
        (engine.modelHandle, 'model.safetensors', 'rl_agent_config.json'),
      ]);
      expect(decisions.info.hiddenSize, 1024);
      expect(decisions.info.maxTokens, 256);
      expect(decisions.info.headMaxTokens, 96);
      expect(decisions.info.deviceName, 'Metal');
      expect(decisions.isDisposed, isFalse);
    });

    test('limits sequences to the head config max_len', () async {
      backend.config = {'max_len': 64, 'head_max_len': 32};
      final decisions = await loadDecisions();

      await decisions.systemOne(
        state: 'x' * 500,
        questions: {'q': DecisionQuestion.noul('Is it long?')},
      );

      expect(backend.runs.single.single.tokens, hasLength(64));
    });

    test('limits options to the head config head_max_len', () async {
      backend.config = {'max_len': 512, 'head_max_len': 40};
      final decisions = await loadDecisions();
      final request = DecisionRequest(
        state: 'A long ticket about a duplicate charge.',
        questions: {
          'pick': DecisionQuestion.choice(
            'Which option fits best?',
            criteria: {
              for (var i = 0; i < 8; i++)
                'option $i': 'a long description of option number $i',
            },
          ),
        },
      );

      await decisions.systemOneBatch([request]);

      final markers = backend.runs.single.single.markers;
      expect(markers, hasLength(8));
      expect([
        for (var i = 1; i < markers.length; i++) markers[i] - markers[i - 1],
      ], everyElement(4));
    });

    test('strips the head mask text from every tokenized text', () async {
      backend.maskText = '<mask>';
      final decisions = await loadDecisions();

      await decisions.systemOne(
        state: 'a <mask> b',
        questions: {
          'q': DecisionQuestion.choice(
            'Is <mask> here?',
            criteria: {'x<mask>y': 'the <mask> case', 'other': null},
          ),
        },
      );

      expect(backend.tokenized, isNotEmpty);
      expect(backend.tokenized, everyElement(isNot(contains('<mask>'))));
      expect(backend.tokenized, contains('a   b'));
    });

    test('frees a head that reports no mask text', () async {
      backend.maskText = '';
      await engine.loadModel('laya-Q8_0.gguf');

      await expectLater(
        DecisionEngine.load(engine, headPath: _headPath),
        throwsA(
          isA<LlamaDecisionException>().having(
            (error) => error.message,
            'message',
            contains('empty mask token text'),
          ),
        ),
      );
      expect(backend.freed, [_headHandle]);
    });

    test('rejects an unloaded engine without probing the backend', () async {
      await expectLater(
        DecisionEngine.load(engine, headPath: _headPath),
        throwsA(
          isA<LlamaUnsupportedException>().having(
            (error) => error.message,
            'message',
            'Load a model first.',
          ),
        ),
      );
      expect(backend.probedModels, isEmpty);
      expect(backend.headLoads, isEmpty);
    });

    test('rejects an unsupported model with the backend reason', () async {
      backend.capabilities = const BackendDecisionCapabilities(
        isSupported: false,
        unsupportedReason: 'The loaded model is not a modern-bert encoder.',
      );
      await engine.loadModel('gemma.gguf');

      await expectLater(
        DecisionEngine.load(engine, headPath: _headPath),
        throwsA(
          isA<LlamaUnsupportedException>().having(
            (error) => error.message,
            'message',
            'The loaded model is not a modern-bert encoder.',
          ),
        ),
      );
      expect(backend.probedModels, [engine.modelHandle]);
      expect(backend.headLoads, isEmpty);
    });

    for (final (name, configJson, message) in [
      ('invalid JSON', 'not json', 'not valid JSON'),
      ('a non-object', '[512]', 'not a JSON object'),
      ('invalid fields', '{"max_len": 0}', '"max_len" must be a positive'),
    ]) {
      test('frees the head when the config is $name', () async {
        backend.configJson = configJson;
        await engine.loadModel('laya-Q8_0.gguf');

        await expectLater(
          DecisionEngine.load(engine, headPath: _headPath),
          throwsA(
            isA<LlamaDecisionException>().having(
              (error) => error.message,
              'message',
              contains(message),
            ),
          ),
        );
        expect(backend.freed, [_headHandle]);
      });
    }

    test('frees a head whose model was unloaded while it loaded', () async {
      await engine.loadModel('laya-Q8_0.gguf');
      final gate = backend.headLoadGate = Completer<void>();

      final loading = DecisionEngine.load(engine, headPath: _headPath);
      await backend.headLoadStarted.future;
      await engine.unloadModel();
      gate.complete();

      await expectLater(
        loading,
        throwsA(
          isA<LlamaStateException>().having(
            (error) => error.message,
            'message',
            contains('unloaded while its decision head was loading'),
          ),
        ),
      );
      expect(backend.freed, [_headHandle]);
    });

    test(
      'reports an unload during the capability probe as a state error',
      () async {
        await engine.loadModel('laya-Q8_0.gguf');
        final gate = backend.capabilityGate = Completer<void>();

        final loading = DecisionEngine.load(engine, headPath: _headPath);
        await backend.capabilityStarted.future;
        await engine.unloadModel();
        gate.complete();

        await expectLater(
          loading,
          throwsA(
            isA<LlamaStateException>().having(
              (error) => error.message,
              'message',
              contains('unloaded while the DecisionEngine was loading'),
            ),
          ),
        );
        expect(backend.headLoads, isEmpty);
      },
    );
  });

  group('capabilitiesFor', () {
    test('reports an unloaded engine as unsupported', () async {
      final capabilities = await DecisionEngine.capabilitiesFor(engine);

      expect(capabilities.isSupported, isFalse);
      expect(capabilities.unsupportedReason, 'Load a model first.');
      expect(capabilities.backendName, 'Metal');
      expect(backend.probedModels, isEmpty);
    });

    test('reports the backend probe for the loaded model', () async {
      await engine.loadModel('laya-Q8_0.gguf');

      final capabilities = await DecisionEngine.capabilitiesFor(engine);

      expect(capabilities.isSupported, isTrue);
      expect(capabilities.unsupportedReason, isNull);
      expect(backend.probedModels, [engine.modelHandle]);
    });

    test('reports a failed probe as unsupported', () async {
      backend.capabilityError = LlamaModelException('probe crashed');
      await engine.loadModel('laya-Q8_0.gguf');

      final capabilities = await DecisionEngine.capabilitiesFor(engine);

      expect(capabilities.isSupported, isFalse);
      expect(
        capabilities.unsupportedReason,
        allOf(contains('probe failed'), contains('probe crashed')),
      );
    });

    test(
      'reports no backend name when the backend cannot name itself',
      () async {
        backend.backendNameError = StateError('no name');
        await engine.loadModel('laya-Q8_0.gguf');

        final capabilities = await DecisionEngine.capabilitiesFor(engine);

        expect(capabilities.isSupported, isTrue);
        expect(capabilities.backendName, isNull);
      },
    );
  });

  group('backend without decision support', () {
    test('reports unsupported before model readiness', () async {
      final plainEngine = LlamaEngine(_PlainBackend());
      addTearDown(plainEngine.dispose);

      final capabilities = await DecisionEngine.capabilitiesFor(plainEngine);

      expect(capabilities.isSupported, isFalse);
      expect(
        capabilities.unsupportedReason,
        'The active backend does not expose decision models.',
      );
    });

    test('load throws without calling the backend', () async {
      final plain = _PlainBackend();
      final plainEngine = LlamaEngine(plain);
      addTearDown(plainEngine.dispose);
      await plainEngine.loadModel('gemma.gguf');
      plain.calls.clear();

      await expectLater(
        DecisionEngine.load(plainEngine, headPath: _headPath),
        throwsA(
          isA<LlamaUnsupportedException>().having(
            (error) => error.message,
            'message',
            'The active backend does not expose decision models.',
          ),
        ),
      );
      await expectLater(
        plainEngine.loadDecisionHeadBackend(_headPath),
        throwsA(isA<LlamaUnsupportedException>()),
      );
      expect(plain.calls, isEmpty);
    });
  });

  group('validation', () {
    test('rejects an empty question id before tokenizing', () async {
      final decisions = await loadDecisions();

      await expectLater(
        decisions.systemOne(
          state: 'hi',
          questions: {'': DecisionQuestion.noul('Is it?')},
        ),
        throwsA(
          isA<LlamaDecisionException>().having(
            (error) => error.message,
            'message',
            contains('non-empty'),
          ),
        ),
      );
      expect(backend.tokenized, isEmpty);
      expect(backend.runs, isEmpty);
    });

    test('rejects a request without questions before tokenizing', () async {
      final decisions = await loadDecisions();

      await expectLater(
        decisions.systemOne(state: 'hi', questions: const {}),
        throwsA(isA<LlamaDecisionException>()),
      );
      expect(backend.tokenized, isEmpty);
      expect(backend.runs, isEmpty);
    });

    test(
      'rejects options that do not fit before running any request',
      () async {
        final decisions = await loadDecisions();

        await expectLater(
          decisions.systemOneBatch([
            requestOf(cases['readme']!),
            DecisionRequest(
              state: 'hi',
              questions: {
                'many': DecisionQuestion.choice(
                  'Pick one.',
                  criteria: {for (var i = 0; i < 200; i++) 'option $i': null},
                ),
              },
            ),
          ]),
          throwsA(
            isA<LlamaDecisionException>().having(
              (error) => error.message,
              'message',
              contains('"many" options exceed'),
            ),
          ),
        );
        expect(backend.runs, isEmpty);
      },
    );

    for (final (name, request) in [
      (
        'state',
        DecisionRequest(
          state: 'Status report\u0000 Please refund the charge.',
          questions: {'refund': DecisionQuestion.noul('Is a refund asked?')},
        ),
      ),
      (
        'instructions',
        DecisionRequest(
          state: 'Please refund the charge.',
          questions: {'refund': DecisionQuestion.noul('Refund?\u0000 Yes?')},
        ),
      ),
      (
        'choice label',
        DecisionRequest(
          state: 'Please refund the charge.',
          questions: {
            'dept': DecisionQuestion.choice(
              'Which department?',
              criteria: {'bill\u0000ing': null, 'other': null},
            ),
          },
        ),
      ),
    ]) {
      test('rejects U+0000 in the $name before running', () async {
        final decisions = await loadDecisions();

        await expectLater(
          decisions.systemOneBatch([request]),
          throwsA(
            isA<LlamaDecisionException>().having(
              (error) => error.message,
              'message',
              contains('U+0000'),
            ),
          ),
        );
        expect(backend.tokenized, everyElement(isNot(contains('\u0000'))));
        expect(backend.runs, isEmpty);
      });
    }

    test('escapes U+0000 inside a JSON state', () async {
      final decisions = await loadDecisions();

      await decisions.systemOne(
        state: {'body': 'Status report\u0000 Please refund.'},
        questions: {'refund': DecisionQuestion.noul('Is a refund asked?')},
      );

      expect(backend.tokenized, contains(contains(r'\u0000')));
      expect(backend.runs, hasLength(1));
    });

    test('answers an empty batch without calling the backend', () async {
      final decisions = await loadDecisions();

      expect(await decisions.systemOneBatch(const []), isEmpty);
      expect(backend.tokenized, isEmpty);
      expect(backend.runs, isEmpty);
    });

    test('rejects a backend output count that does not match', () async {
      backend.dropOutputs = 1;
      final decisions = await loadDecisions();

      await expectLater(
        decisions.systemOneBatch([requestOf(cases['readme']!)]),
        throwsA(
          isA<LlamaDecisionException>().having(
            (error) => error.message,
            'message',
            contains('3 outputs for 4 sequences'),
          ),
        ),
      );
    });
  });

  group('lifecycle', () {
    test('dispose is idempotent and frees the head once', () async {
      final decisions = await loadDecisions();

      final first = decisions.dispose();
      final second = decisions.dispose();
      await Future.wait([first, second]);
      await decisions.dispose();

      expect(decisions.isDisposed, isTrue);
      expect(backend.freed, [_headHandle]);
      expect(engine.isReady, isTrue);
    });

    test('calls after dispose throw LlamaStateException', () async {
      final decisions = await loadDecisions();
      await decisions.dispose();

      await expectLater(
        decisions.systemOne(
          state: 'hi',
          questions: {'q': DecisionQuestion.noul('Is it?')},
        ),
        throwsA(isA<LlamaStateException>()),
      );
      await expectLater(
        decisions.systemOneBatch(const []),
        throwsA(isA<LlamaStateException>()),
      );
      expect(backend.tokenized, isEmpty);
      expect(backend.runs, isEmpty);
    });

    test('dispose waits for in-flight calls before freeing', () async {
      final decisions = await loadDecisions();
      final gate = backend.runGate = Completer<void>();
      final rows = cases['readme']!;

      final call = decisions.systemOneBatch([requestOf(rows)]);
      await backend.runStarted.future;
      final disposal = decisions.dispose();
      await pumpEventQueue();

      expect(decisions.isDisposed, isTrue);
      expect(backend.freed, isEmpty);
      gate.complete();
      final results = await call;
      await disposal;

      expect(results.single.answers, hasLength(rows.length));
      expect(backend.freed, [_headHandle]);
    });

    test('dispose called twice during a call completes both futures', () async {
      final decisions = await loadDecisions();
      final gate = backend.runGate = Completer<void>();

      final call = decisions.systemOneBatch([requestOf(cases['readme']!)]);
      await backend.runStarted.future;
      final first = decisions.dispose();
      final second = decisions.dispose();
      gate.complete();
      await call;

      await Future.wait([first, second]).timeout(const Duration(seconds: 5));
      expect(backend.freed, [_headHandle]);
    });

    test('dispose waits for every in-flight call', () async {
      final decisions = await loadDecisions();
      final firstGate = Completer<void>();
      final secondGate = Completer<void>();
      backend.runGateQueue.addAll([firstGate, secondGate]);

      final firstCall = decisions.systemOneBatch([requestOf(cases['readme']!)]);
      final secondCall = decisions.systemOneBatch([
        requestOf(cases['readme']!),
      ]);
      for (var i = 0; i < 10 && backend.runs.length < 2; i++) {
        await pumpEventQueue();
      }
      expect(backend.runs, hasLength(2));
      final disposal = decisions.dispose();
      firstGate.complete();
      await firstCall;
      await pumpEventQueue();

      expect(backend.freed, isEmpty);
      secondGate.complete();
      await secondCall;
      await disposal;
      expect(backend.freed, [_headHandle]);
    });

    test('concurrent calls all complete', () async {
      final decisions = await loadDecisions();
      final caseRows = cases.values.toList();

      final results = await Future.wait([
        for (final rows in caseRows)
          decisions.systemOne(
            state: rows.first.state,
            questions: requestOf(rows).questions,
          ),
      ]);

      expect(backend.runs, hasLength(caseRows.length));
      for (var c = 0; c < caseRows.length; c++) {
        for (final row in caseRows[c]) {
          expectDecisionJsonClose(
            results[c].answers[row.questionId]!.toJson(),
            row.answer,
            row.id,
          );
        }
      }
    });

    test('engine unload makes calls throw LlamaStateException', () async {
      final decisions = await loadDecisions();
      await engine.unloadModel();

      await expectLater(
        decisions.systemOne(
          state: 'hi',
          questions: {'q': DecisionQuestion.noul('Is it?')},
        ),
        throwsA(
          isA<LlamaStateException>().having(
            (error) => error.message,
            'message',
            contains('Load the DecisionEngine again'),
          ),
        ),
      );
      expect(backend.runs, isEmpty);
    });

    test('an unload during tokenization throws LlamaStateException', () async {
      final decisions = await loadDecisions();
      final gate = backend.tokenizeGate = Completer<void>();

      final call = decisions.systemOne(
        state: 'hi',
        questions: {'q': DecisionQuestion.noul('Is it?')},
      );
      await backend.tokenizeStarted.future;
      await engine.unloadModel();
      gate.complete();

      await expectLater(
        call,
        throwsA(
          isA<LlamaStateException>().having(
            (error) => error.message,
            'message',
            contains('Load the DecisionEngine again'),
          ),
        ),
      );
      expect(backend.runs, isEmpty);
    });

    test('a run error while the model is loaded passes through', () async {
      final decisions = await loadDecisions();
      backend.runError = LlamaInferenceException('head compute failed');

      await expectLater(
        decisions.systemOne(
          state: 'hi',
          questions: {'q': DecisionQuestion.noul('Is it?')},
        ),
        throwsA(
          isA<LlamaInferenceException>().having(
            (error) => error.message,
            'message',
            'head compute failed',
          ),
        ),
      );
      expect(backend.runs, hasLength(1));
    });

    test('a model reloaded under a new handle is not tokenized', () async {
      final decisions = await loadDecisions();
      final loadedHandle = engine.modelHandle;
      await engine.unloadModel();
      await engine.loadModel('laya-Q8_0.gguf');
      expect(engine.modelHandle, isNot(loadedHandle));

      await expectLater(
        decisions.systemOne(
          state: 'hi',
          questions: {'q': DecisionQuestion.noul('Is it?')},
        ),
        throwsA(isA<LlamaStateException>()),
      );
      expect(backend.tokenized, isEmpty);
      expect(backend.runs, isEmpty);
    });

    test(
      'a stale engine cannot reach a head that reuses its handles',
      () async {
        backend.reuseModelHandle = true;
        final stale = await loadDecisions();
        await engine.unloadModel();
        await engine.loadModel('laya-Q8_0.gguf');
        final current = await DecisionEngine.load(engine, headPath: _headPath);
        expect(backend.headLoads.map((load) => load.$1), [1, 1]);

        await expectLater(
          stale.systemOne(
            state: 'hi',
            questions: {'q': DecisionQuestion.noul('Is it?')},
          ),
          throwsA(
            isA<LlamaStateException>().having(
              (error) => error.message,
              'message',
              contains('Load the DecisionEngine again'),
            ),
          ),
        );
        await stale.dispose();

        expect(backend.freed, isEmpty);
        expect(backend.runs, isEmpty);
        final result = await current.systemOne(
          state: 'hi',
          questions: {'q': DecisionQuestion.noul('Is it?')},
        );
        expect(result.nouls['q'], isNotNull);
        expect(backend.runHandles, [_headHandle]);
        await current.dispose();
        expect(backend.freed, [_headHandle]);
      },
    );

    test('dispose after engine unload does not call the backend', () async {
      final decisions = await loadDecisions();
      await engine.unloadModel();

      await decisions.dispose();

      expect(decisions.isDisposed, isTrue);
      expect(backend.freed, isEmpty);
    });

    test('dispose after engine dispose does not call the backend', () async {
      final decisions = await loadDecisions();
      await engine.dispose();

      await decisions.dispose();

      expect(backend.freed, isEmpty);
    });
  });

  group('engine hooks', () {
    test('loadDecisionHeadBackend needs a loaded model', () async {
      await expectLater(
        engine.loadDecisionHeadBackend(_headPath),
        throwsA(isA<LlamaContextException>()),
      );
      expect(backend.headLoads, isEmpty);
    });

    test('hand out engine handles that are never reused', () async {
      backend.reuseModelHandle = true;
      await engine.loadModel('laya-Q8_0.gguf');
      final first = await engine.loadDecisionHeadBackend(_headPath);
      await engine.unloadModel();
      await engine.loadModel('laya-Q8_0.gguf');
      final second = await engine.loadDecisionHeadBackend(_headPath);

      expect(second.handle, isNot(first.handle));
      expect(second.maskText, '[MASK]');
      await engine.runDecisionBackend(second.handle, const []);
      expect(backend.runHandles, [_headHandle]);
    });

    test('freeDecisionHeadBackend forgets the handle', () async {
      await engine.loadModel('laya-Q8_0.gguf');
      final head = await engine.loadDecisionHeadBackend(_headPath);

      await engine.freeDecisionHeadBackend(head.handle);
      await engine.freeDecisionHeadBackend(head.handle);

      await expectLater(
        engine.runDecisionBackend(head.handle, const []),
        throwsA(isA<LlamaStateException>()),
      );
      expect(backend.freed, [_headHandle]);
      expect(backend.runs, isEmpty);
    });
  });
}

class _DecisionBackend implements LlamaBackend, BackendDecision {
  _DecisionBackend(this.fixture)
    : config = {
        'max_len': 512,
        'head_max_len': 192,
        'temperature': fixture.temperature,
        'temperature_by_options': fixture.temperatureByOptions,
      },
      _rowsByIds = {for (final row in fixture.rows) jsonEncode(row.ids): row};

  final DecisionFixture fixture;
  final Map<String, DecisionFixtureRow> _rowsByIds;
  bool _ready = false;
  int _nextModelHandle = 1;
  bool reuseModelHandle = false;
  BackendDecisionCapabilities capabilities = const BackendDecisionCapabilities(
    isSupported: true,
  );
  Object? capabilityError;
  Object? backendNameError;
  Object? runError;
  Map<String, Object?> config;
  String? configJson;
  String maskText = '[MASK]';
  int dropOutputs = 0;
  Completer<void>? capabilityGate;
  Completer<void>? headLoadGate;
  Completer<void>? tokenizeGate;
  Completer<void>? runGate;
  final List<Completer<void>> runGateQueue = [];
  final Completer<void> capabilityStarted = Completer<void>();
  final Completer<void> headLoadStarted = Completer<void>();
  final Completer<void> tokenizeStarted = Completer<void>();
  final Completer<void> runStarted = Completer<void>();
  final List<int> probedModels = [];
  final List<(int, String, String?)> headLoads = [];
  final List<String> tokenized = [];
  final List<bool> addSpecialFlags = [];
  final List<int> runHandles = [];
  final List<List<BackendDecisionSequence>> runs = [];
  final List<int> freed = [];

  @override
  bool get isReady => _ready;

  @override
  bool get supportsUrlLoading => false;

  @override
  Future<void> setLogLevel(LlamaLogLevel level) async {}

  @override
  Future<int> modelLoad(String path, ModelParams params) async {
    _ready = true;
    return reuseModelHandle ? 1 : _nextModelHandle++;
  }

  @override
  Future<int> contextCreate(int modelHandle, ModelParams params) async => 100;

  @override
  Future<void> contextFree(int contextHandle) async {}

  @override
  Future<void> modelFree(int modelHandle) async {
    _ready = false;
  }

  @override
  void cancelGeneration() {}

  @override
  Future<void> dispose() async {}

  @override
  Future<String> getBackendName() async {
    final error = backendNameError;
    if (error != null) throw error;
    return 'Metal';
  }

  @override
  Future<List<int>> tokenize(
    int modelHandle,
    String text, {
    bool addSpecial = true,
  }) async {
    tokenized.add(text);
    addSpecialFlags.add(addSpecial);
    if (!tokenizeStarted.isCompleted) tokenizeStarted.complete();
    await tokenizeGate?.future;
    return fixture.pieces[text] ?? text.codeUnits;
  }

  @override
  Future<BackendDecisionCapabilities> decisionCapabilities(
    int modelHandle,
  ) async {
    probedModels.add(modelHandle);
    if (!capabilityStarted.isCompleted) capabilityStarted.complete();
    await capabilityGate?.future;
    final error = capabilityError;
    if (error != null) throw error;
    return capabilities;
  }

  @override
  Future<BackendDecisionHeadInfo> decisionHeadLoad(
    int modelHandle,
    String headPath, {
    String? configPath,
  }) async {
    headLoads.add((modelHandle, headPath, configPath));
    if (!headLoadStarted.isCompleted) headLoadStarted.complete();
    await headLoadGate?.future;
    return BackendDecisionHeadInfo(
      handle: _headHandle,
      hiddenSize: 1024,
      clsToken: fixture.clsToken,
      sepToken: fixture.sepToken,
      maskToken: fixture.maskToken,
      maskText: maskText,
      configJson: configJson ?? jsonEncode(config),
      deviceName: 'Metal',
    );
  }

  @override
  Future<List<BackendDecisionOutput>> decisionRun(
    int headHandle,
    List<BackendDecisionSequence> sequences,
  ) async {
    runHandles.add(headHandle);
    runs.add(sequences);
    if (!runStarted.isCompleted) runStarted.complete();
    await (runGateQueue.isEmpty ? runGate : runGateQueue.removeAt(0))?.future;
    final error = runError;
    if (error != null) throw error;
    return [
      for (final sequence in sequences.skip(dropOutputs)) _outputFor(sequence),
    ];
  }

  @override
  Future<void> decisionHeadFree(int headHandle) async {
    freed.add(headHandle);
  }

  BackendDecisionOutput _outputFor(BackendDecisionSequence sequence) {
    final row = _rowsByIds[jsonEncode(sequence.tokens)];
    return BackendDecisionOutput(
      logits: Float32List.fromList(
        row?.rawLogits ?? List.filled(sequence.markers.length, 0.0),
      ),
      actLogits: Float32List.fromList(row?.rawActLogits ?? const [0.0, 0.0]),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _PlainBackend implements LlamaBackend {
  final List<Symbol> calls = [];

  @override
  bool get supportsUrlLoading => false;

  @override
  Future<void> setLogLevel(LlamaLogLevel level) async {
    calls.add(#setLogLevel);
  }

  @override
  Future<int> modelLoad(String path, ModelParams params) async {
    calls.add(#modelLoad);
    return 1;
  }

  @override
  Future<int> contextCreate(int modelHandle, ModelParams params) async {
    calls.add(#contextCreate);
    return 2;
  }

  @override
  Future<void> contextFree(int contextHandle) async {}

  @override
  Future<void> modelFree(int modelHandle) async {}

  @override
  void cancelGeneration() {}

  @override
  Future<void> dispose() async {}

  @override
  Future<String> getBackendName() async => 'CPU';

  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls.add(invocation.memberName);
    return super.noSuchMethod(invocation);
  }
}
