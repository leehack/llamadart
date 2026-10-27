import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart/backend.dart';
import 'package:llamadart_validation/io.dart';
import 'package:llamadart_validation/llamadart_validation.dart';
import 'package:llamadart_validation/src/state_evidence.dart';
import 'package:test/test.dart';

import 'validation_test.dart' as harness;

ValidationProfile profile([String id = 'state-gguf-cpu']) =>
    ValidationProfile.fromJson(
      jsonDecode(File('assets/profiles/$id.json').readAsStringSync())
          as Map<String, dynamic>,
    );
const cpuDiagnostics = {
  'backend_name': 'CPU',
  'context_size': 256,
  'reported_gpu_layers': 0,
};

class MemoryWorkspace implements StateValidationWorkspace {
  final files = <String, Uint8List>{};
  bool disposed = false;
  @override
  String path(String role) => role;
  @override
  Future<Uint8List> read(String role) async => files[role]!;
  @override
  Future<void> write(String role, List<int> bytes) async {
    files[role] = Uint8List.fromList(bytes);
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    files.clear();
  }
}

class StateEngine extends harness.FakeEngine implements StateValidationEngine {
  StateEngine(this.workspace);
  final MemoryWorkspace Function() workspace;
  String? fault;
  bool supported = true;
  @override
  bool get supportsStatePersistence => supported;
  @override
  bool get supportsNextTokenScoring => true;
  @override
  Future<Map<String, dynamic>> diagnostics() async => {...diagnosticsValue};
  Map<String, dynamic> diagnosticsValue = {...cpuDiagnostics};
  bool restored = false;
  @override
  Future<void> load(String location, ValidationProfile profile) async {
    await super.load(location, profile);
    restored = false;
  }

  @override
  Future<List<int>> tokenizeStatePrompt(String text) async => [
    for (var i = 0; i < (text.endsWith(' the wooden box') ? 62 : 59); i++) i,
  ];
  @override
  Future<Map<String, dynamic>> scoreStatePrompt(
    String text, {
    List<int> candidates = const [],
    int topK = 0,
    required bool reuse,
  }) async {
    final suffix = text == ' the wooden box';
    final full = text.endsWith(' the wooden box') && !suffix;
    final offset = suffix
        ? 10
        : full
        ? 2
        : 1;
    List<Map<String, dynamic>> scores(List<int> ids) => [
      for (final id in ids)
        {
          'token': id,
          'logprob':
              -id.toDouble() -
              (fault == 'token_echo' && restored ? 20 : offset),
        },
    ];
    return {
      'prompt_tokens': suffix
          ? 4
          : full
          ? 62
          : 59,
      'candidates': scores(candidates),
      'top': scores([for (var i = 0; i < topK; i++) i]),
    };
  }

  @override
  Future<bool> saveState(String path, List<int> tokens) async {
    if (!supported) throw LlamaUnsupportedException('State unsupported');
    final bytes = Uint8List(1000)..setAll(0, [110, 115, 103, 103, 11, 0, 0, 0]);
    await workspace().write(path, bytes);
    return fault != 'save_false';
  }

  @override
  Future<List<int>> loadState(String path, int capacity) async {
    if (!supported) throw LlamaUnsupportedException('State unsupported');
    if (capacity <= 0 || capacity > 256) {
      throw LlamaArgumentException('Invalid capacity');
    }
    if (path != 'valid' || capacity < 59) {
      throw LlamaStateException('Invalid state');
    }
    restored = true;
    return [for (var i = 0; i < 59; i++) i];
  }

  @override
  Future<Map<String, dynamic>> generateStatePrompt(
    String text, {
    required bool reuse,
  }) async {
    final count = text.endsWith(' the wooden box') ? 62 : 59;
    final cached = fault == 'recompute'
        ? 0
        : restored && reuse
        ? count == 59
              ? 58
              : 59
        : 0;
    return {
      'output': 'x',
      'observer_present': true,
      'observer_error': null,
      'observer_cancelled': false,
      'finish_reason': 'length',
      'usage': fault == 'no_usage'
          ? null
          : LlamaGenerationUsage(
              promptTokens: count,
              completionTokens: 1,
              cachedPromptTokens: cached,
            ).toJson(),
      'prompt_eval_tokens': count - cached,
    };
  }
}

Future<List<Map<String, dynamic>>> runState({
  String? fault,
  bool workspaceAvailable = true,
  bool spi = true,
  ValidationProfile? selected,
  bool supported = true,
}) async {
  MemoryWorkspace? current;
  final state = StateEngine(() => current!)
    ..fault = fault
    ..supported = supported;
  if ((selected ?? profile()).runtime == 'litert') {
    state.diagnosticsValue = {'backend_name': 'LiteRT-LM CPU'};
  }
  final events = <Map<String, dynamic>>[];
  final target = selected ?? profile();
  await ValidationRunner(
    profile: target,
    engine: spi ? state : harness.FakeEngine(),
    emit: (event) async {
      events.add(event);
    },
    stateWorkspaceFactory: workspaceAvailable
        ? () async {
            current = MemoryWorkspace();
            return current!;
          }
        : null,
  ).run(
    'model.gguf',
    runId: 'state-test',
    environment: {
      'source_commit': 'a' * 40,
      'source_dirty': false,
      'hook_sha256': 'b' * 64,
      'native_tag': 'v0.7.0-2',
    },
    preparation: {
      'verified': true,
      'sha256': target.modelHash,
      'bytes': target.model['bytes'],
    },
  );
  if (current != null) expect(current!.disposed, true);
  return events;
}

Map<String, dynamic> caseRecord(List<Map<String, dynamic>> events, String id) =>
    events.firstWhere((e) => e['case_id'] == id && e['type'] == 'case');
List<Map<String, dynamic>> copyEvents(List<Map<String, dynamic>> events) =>
    (jsonDecode(jsonEncode(events)) as List).cast<Map<String, dynamic>>();
ValidationReport report(List<Map<String, dynamic>> events) =>
    ValidationReport.parse(events.map(jsonEncode).join('\n'));

class CaptureEngine implements LlamaEngine {
  String? prompt;
  bool? special;
  bool? reuse;
  List<int>? candidates;
  String? path;
  int? capacity;
  @override
  bool get supportsStatePersistence => true;
  @override
  bool get supportsNextTokenScoring => true;
  @override
  Future<List<int>> tokenize(String text, {bool addSpecial = true}) async {
    prompt = text;
    special = addSpecial;
    return [9];
  }

  @override
  Future<LlamaNextTokenScores> scoreNextToken(
    String text, {
    List<int> candidates = const [],
    int topK = 0,
    bool reusePromptPrefix = true,
  }) async {
    prompt = text;
    reuse = reusePromptPrefix;
    this.candidates = candidates;
    return LlamaNextTokenScores(candidates: [], top: [], promptTokens: 3);
  }

  @override
  Future<bool> stateSaveFile(String path, {required List<int> tokens}) async {
    this.path = path;
    candidates = tokens;
    return false;
  }

  @override
  Future<StateLoadResult> stateLoadFile(
    String path, {
    required int tokenCapacity,
  }) async {
    this.path = path;
    capacity = tokenCapacity;
    return StateLoadResult(tokens: [8, 9]);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class UnsupportedBackend implements LlamaBackend {
  @override
  bool get supportsUrlLoading => false;
  @override
  Future<void> setLogLevel(LlamaLogLevel level) async {}
  @override
  Future<int> modelLoad(String path, ModelParams params) async => 1;
  @override
  Future<int> contextCreate(int modelHandle, ModelParams params) async => 1;
  @override
  Future<void> contextFree(int handle) async {}
  @override
  Future<void> modelFree(int handle) async {}
  @override
  Future<void> dispose() async {}
  @override
  void cancelGeneration() {}
  @override
  Future<int> getContextSize(int handle) async => 256;
  @override
  Future<Map<String, String>> modelMetadata(int handle) async => {};
  @override
  Future<String> getBackendName() async => 'Unsupported state test';
  @override
  Stream<List<int>> generate(
    int contextHandle,
    String prompt,
    GenerationParams params, {
    List<LlamaContentPart>? parts,
  }) => Stream.value(utf8.encode('recovered'));
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FalseSupportBackend extends UnsupportedBackend
    implements BackendStatePersistence, BackendStatePersistenceSupport {
  int forwarded = 0;
  @override
  bool get supportsStatePersistence => false;
  @override
  Future<bool> stateSaveFile(int handle, String path, List<int> tokens) async {
    forwarded++;
    return true;
  }

  @override
  Future<StateLoadResult> stateLoadFile(
    int handle,
    String path,
    int capacity,
  ) async {
    forwarded++;
    return const StateLoadResult(tokens: []);
  }
}

void main() {
  test(
    'public engine rejects interface absence and support false without forwarding',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'state-unsupported-test-',
      );
      final file = File('${directory.path}/model.gguf');
      await file.writeAsBytes([1]);
      try {
        for (final backend in [UnsupportedBackend(), FalseSupportBackend()]) {
          final engine = LlamaEngine(backend);
          try {
            await engine.setModel(LlamaModel(ModelSource.path(file.path)));
            expect(engine.supportsStatePersistence, false);
            await expectLater(
              engine.stateSaveFile(
                '${directory.path}/probe.state',
                tokens: [1],
              ),
              throwsA(isA<LlamaUnsupportedException>()),
            );
            await expectLater(
              engine.stateLoadFile(
                '${directory.path}/probe.state',
                tokenCapacity: 1,
              ),
              throwsA(isA<LlamaUnsupportedException>()),
            );
            expect(
              await engine
                  .generate(
                    'recover',
                    params: const GenerationParams(maxTokens: 1),
                  )
                  .join(),
              'recovered',
            );
            if (backend is FalseSupportBackend) expect(backend.forwarded, 0);
            expect(await File('${directory.path}/probe.state').exists(), false);
          } finally {
            await engine.dispose();
          }
        }
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'adapter forwards state public methods and special-token convention',
    () async {
      final capture = CaptureEngine();
      final adapter = PublicValidationEngine(engineFactory: () => capture);
      expect(adapter.supportsStatePersistence, true);
      expect(adapter.supportsNextTokenScoring, true);
      expect(await adapter.tokenizeStatePrompt('prefix'), [9]);
      expect(capture.special, true);
      await adapter.scoreStatePrompt(
        'prefix',
        candidates: [5, 7],
        reuse: false,
      );
      expect(capture.reuse, false);
      expect(capture.candidates, [5, 7]);
      expect(await adapter.saveState('valid', [3, 4]), false);
      expect(capture.path, 'valid');
      expect(capture.candidates, [3, 4]);
      expect(await adapter.loadState('valid', 11), [8, 9]);
      expect(capture.capacity, 11);
    },
  );
  test(
    'complete model-free proof passes and importer reconstructs every P case',
    () async {
      final events = await runState();
      for (final id in [
        'P01.capability',
        'P02.roundtrip',
        'P03.restore_reuse',
        'P04.invalid_recovery',
      ]) {
        expect(caseRecord(events, id)['status'], 'PASS', reason: id);
      }
      expect(report(events).problems, isEmpty);
    },
  );
  test(
    'token-only echo and full recomputation fail distinct causal oracles',
    () async {
      for (final fault in ['token_echo', 'recompute', 'save_false']) {
        final events = await runState(fault: fault);
        expect(
          caseRecord(events, 'P03.restore_reuse')['status'],
          'FAIL',
          reason: fault,
        );
      }
    },
  );
  test(
    'absent optional adapter, workspace and public counters remain incomplete',
    () async {
      for (final events in [
        await runState(spi: false),
        await runState(workspaceAvailable: false),
        await runState(fault: 'no_usage'),
      ]) {
        expect(caseRecord(events, 'P03.restore_reuse')['status'], 'NOT_RUN');
        expect(report(events).assertionsPassed, false);
      }
    },
  );
  test(
    'unknown model/config is not unsupported and known unsupported recovers',
    () async {
      final changed = profile().toJson()..['context_size'] = 512;
      final unknown = await runState(
        selected: ValidationProfile.fromJson(changed),
      );
      expect(caseRecord(unknown, 'P01.capability')['status'], 'NOT_RUN');
      final litert = profile('chat-litert-cpu').toJson()
        ..['selection'] = 'focused'
        ..['focus_features'] = ['state_persistence'];
      final excluded = await runState(
        selected: ValidationProfile.fromJson(litert),
        supported: false,
      );
      expect(caseRecord(excluded, 'P01.capability')['status'], 'PASS');
      final falseClaim = await runState(
        selected: ValidationProfile.fromJson(litert),
        supported: true,
      );
      expect(caseRecord(falseClaim, 'P01.capability')['status'], 'FAIL');
      expect(excluded.any((e) => e['case_id'] == 'P02.roundtrip'), false);
    },
  );
  test(
    'catalog 11 is additive and old catalogs reject state fixtures or focus',
    () {
      final selected = profile();
      for (var v = 1; v <= 10; v++) {
        expect(() => selected.catalogForVersion(v), throwsFormatException);
      }
      final quick = profile('tiny-gguf-cpu');
      for (var v = 1; v <= 10; v++) {
        final catalog = quick.catalogForVersion(v);
        expect(catalog['features'], isNot(contains('state_persistence')));
        expect(catalog['fixtures'], isNot(contains('state_persistence')));
        expect(
          (catalog['cases'] as List).any(
            (c) => '${(c as Map)['id']}'.startsWith('P'),
          ),
          false,
        );
      }
      final override = quick.toJson()
        ..['fixtures'] = {
          'state_persistence': {'max_abs_logprob_delta': 100},
        };
      expect(() => ValidationProfile.fromJson(override), throwsFormatException);
      final native = profile('npu-qualcomm-sm8650').toJson()
        ..['execution_path'] = 'native_c_api'
        ..['enable_thinking'] = true
        ..['selection'] = 'focused'
        ..['focus_features'] = ['state_persistence'];
      expect(
        ValidationProfile.fromJson(
          native,
        ).caseIds.any((id) => id.startsWith('P')),
        false,
      );
    },
  );
  test(
    'independent host oracle rejects provider outcome or missing diagnostics',
    () {
      final selected = profile();
      expect(
        expectedStateCapability(
          selected,
          web: false,
          diagnostics: cpuDiagnostics,
        ),
        true,
      );
      expect(
        expectedStateCapability(selected, web: false, diagnostics: {}),
        null,
      );
      expect(
        expectedStateCapability(
          selected,
          web: true,
          diagnostics: cpuDiagnostics,
        ),
        null,
      );
    },
  );
  test('journal mutations cannot claim state success', () async {
    final events = await runState();
    final mutations = <String, void Function(Map<String, dynamic>)>{
      'no scores': (r) => (r['phases'][3] as Map).remove('score'),
      'recompute': (r) =>
          r['phases'][6]['generation']['prompt_eval_tokens'] = 62,
      'no usage': (r) => (r['phases'][6]['generation'] as Map).remove('usage'),
      'no counters': (r) =>
          (r['phases'][6]['generation'] as Map).remove('prompt_eval_tokens'),
      'fake cache': (r) =>
          r['phases'][6]['generation']['usage']['prompt_tokens_details']['cached_tokens'] =
              58,
      'zero separation': (r) =>
          r['phases'][2]['score'] = r['phases'][1]['score'],
      'not cold': (r) => r['phases'][3]['lifetime'] = 1,
      'not disposed': (r) => r['phases'][0]['disposed'] = false,
      'model swapped': (r) => r['phases'][3]['model_sha256'] = 'c' * 64,
      'config swapped': (r) => r['phases'][3]['config_hash'] = 'd' * 64,
      'snapshot swapped': (r) => r['phases'][3]['snapshot_sha256'] = 'e' * 64,
      'oversized artifact': (r) =>
          r['artifact']['bytes'] = 16 * 1024 * 1024 + 1,
      'source stub': (r) => r['artifact']['bytes'] = 8,
      'tokens echoed': (r) => r['phases'][3]['loaded_tokens'] = [1],
      'phase missing': (r) => (r['phases'] as List).removeAt(2),
      'phase reordered': (r) =>
          (r['phases'] as List).insert(2, (r['phases'] as List).removeAt(3)),
      'candidates duplicate': (r) => r['candidates'][1] = r['candidates'][0],
      'nonfinite': (r) =>
          r['phases'][3]['score']['candidates'][0]['logprob'] = 'NaN',
      'producer threshold widened': (r) {
        r['max_abs_logprob_delta'] = 100;
        r['phases'][3]['score']['candidates'][0]['logprob'] = -99;
      },
      'unsupported success': (r) => r['supported'] = false,
      'web identity': (r) => r['web'] = true,
      'diagnostics swapped': (r) => r['diagnostics']['backend_name'] = 'Metal',
      'workspace leaked': (r) => r['workspace_disposed'] = false,
    };
    for (final entry in mutations.entries) {
      final copy = copyEvents(events);
      entry.value(caseRecord(copy, 'P03.restore_reuse'));
      expect(
        report(copy).problems,
        contains('Invalid state case evidence: P03.restore_reuse'),
        reason: entry.key,
      );
    }
    final negativeMutations = <String, void Function(Map<String, dynamic>)>{
      'generic exception': (r) => r['phases'][9]['rejection'] = 'Exception',
      'capacity widened': (r) => r['phases'][21]['capacity'] = 1,
      'negative bytes swapped': (r) =>
          r['negative_artifacts']['short']['inline_bytes'][0] = 0,
      'version recipe changed': (r) =>
          r['negative_artifacts']['incompatible']['recipe'] = 'none',
      'recovery omitted': (r) => (r['phases'] as List).removeLast(),
      'recovery semantic corrupt': (r) =>
          r['phases'][10]['score']['candidates'][0]['logprob'] = -200,
      'recovery work missing': (r) =>
          r['phases'][11]['generation']['prompt_eval_tokens'] = null,
    };
    for (final entry in negativeMutations.entries) {
      final copy = copyEvents(events);
      entry.value(caseRecord(copy, 'P04.invalid_recovery'));
      expect(
        report(copy).problems,
        contains('Invalid state case evidence: P04.invalid_recovery'),
        reason: entry.key,
      );
    }
  });
  test('original catalog 9 and 10 model-free journals replay unchanged', () {
    final quick = profile('tiny-gguf-cpu');
    expect(
      jsonHash(quick.catalogForVersion(9)),
      'bf29257c5a7f09bc6c57150b0c506901803202968c77cff0fbaa2187ad222ee7',
    );
    expect(
      jsonHash(quick.catalogForVersion(10)),
      '69007a80f3a1f387356c664fc401c4dc87c6d8ad69e064baa1e14423533e069f',
    );
    for (final version in [9, 10]) {
      final legacy = ValidationReport.parse(
        File(
          'test/fixtures/state_catalog_history/catalog_$version.jsonl',
        ).readAsStringSync(),
      );
      expect(legacy.problems, isEmpty);
      expect(legacy.assertionsPassed, true);
      expect(
        legacy.cases.any((row) => '${row['case_id']}'.startsWith('P')),
        false,
      );
    }
  });
  test(
    'IO workspace rejects arbitrary role and deletes all state files',
    () async {
      final workspace = await IoStateValidationWorkspace.create();
      expect(() => workspace.path('../escape'), throwsArgumentError);
      await workspace.write('garbage', [1, 2]);
      final file = File(workspace.path('garbage'));
      expect(await workspace.read('garbage'), [1, 2]);
      final handle = await file.open(mode: FileMode.append);
      try {
        await handle.truncate(16 * 1024 * 1024 + 1);
      } finally {
        await handle.close();
      }
      await expectLater(workspace.read('garbage'), throwsStateError);
      await workspace.dispose();
      expect(await file.exists(), false);
    },
  );
}
