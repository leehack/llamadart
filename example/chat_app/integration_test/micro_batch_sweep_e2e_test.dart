@Tags(['local-only', 'e2e'])
@Timeout(Duration(minutes: 25))
/// Local-only E2E that runs history, long-history and tool prompts at several
/// micro-batch sizes (`ModelParams.microBatchSize`, llama.cpp `n_ubatch`) in
/// one process, and records what the library decided about the Android Vulkan
/// text prompt cap (https://github.com/leehack/llamadart/issues/948).
///
/// Each attempt loads the locked model of a validation profile on a new
/// engine, generates the `C03.raw`, `C04.hello`, `C04.arithmetic`,
/// `C06.history`, `X01.long_history`, `C07.tools.auto` and
/// `C07.tools.required` requests through the validation engine, and disposes
/// the engine. Attempts go round-robin over the micro-batch sizes, so every
/// size is tried in each repeat of the same process.
///
/// Size `0` is the library default and the only one the test judges: after
/// every attempt has run, it fails when a default attempt did not load, did
/// not answer `C06.history` or `X01.long_history` with the expected code, or
/// did not end a tool request as the `get_weather` call. On Android Vulkan
/// that is the capped path wherever the library applies the cap.
///
/// Every other size is a control and is only recorded. An explicit size, even
/// one equal to the default `n_ubatch` (512), makes the library leave the cap
/// off, so `0,512` compares the capped default with the same context
/// uncapped. That control is expected to answer wrongly on a Vulkan device
/// with the small matmul tile defect (a Pixel 9 Pro's Mali-G715, subgroup size
/// 16, answered `8888...`); a correct control there says the cap is no longer
/// needed. A control sends the tool requests only in the last repeat: a
/// grammar over such logits is what aborted the process before native
/// exceptions were typed, and a death there must not cost the earlier
/// repeats.
///
/// Records go to `micro_batch_sweep/journal.jsonl` (app external files on
/// Android, the temporary directory elsewhere) and, shortened, to the log as
/// `MICRO_BATCH_SWEEP {json}` lines. An `attempt_started` and a
/// `case_started` record precede each step, so a run that dies names the step
/// it died in.
///
/// - `log`: every `LlamaLogger` record at `debug` and above, among them the
///   warning of a load that fell back to the CPU.
/// - `prompt_cap`: the cap decision of an attempt, from the library's debug
///   line: `capped` with the token count or `not_capped`, and the Vulkan
///   devices it was made from (name, driver and loader API version, subgroup
///   size). `not_logged` when the library made no decision: off Android, on
///   the CPU and at an explicit size.
/// - `load_refused`: a typed exception from a load, such as the refusal of a
///   Vulkan driver below 1.2.
/// - `load`, `case`, `case_error`, `summary`: backend and batch sizes, each
///   answer with its timings, a typed exception from a request, and the
///   correct answers by size.
///
/// A `case` record times the prompt twice. `native_prompt_ms` is the llama.cpp
/// worker's own clock around prompt ingestion, valid at every micro-batch
/// size, and `prompt_tps` is `prompt_tokens` over it. `native_prompt_tokens`
/// is llama.cpp's counter, which leaves the prompt out at micro-batch size 1.
/// `ttfa_ms` is this isolate's clock from the request to the first streamed
/// text: it adds templating, the isolate hops and the first stream batch.
///
/// Native llama.cpp output goes to standard error, which Android discards;
/// this test points standard error at `micro_batch_sweep/native_stderr.log`
/// and copies the `ggml_vulkan:` device lines and the context's `n_batch` and
/// `n_ubatch` from it into the records. The device lines need `debug`.
///
/// ```bash
/// cd example/chat_app
/// flutter test --run-skipped -t local-only \
///   integration_test/micro_batch_sweep_e2e_test.dart -d <device> \
///   --dart-define=MICRO_BATCH_SWEEP_ARMS=0,512 \
///   --dart-define=MICRO_BATCH_SWEEP_REPEATS=3
/// ```
///
/// `MICRO_BATCH_SWEEP_ARMS` lists the sizes. `MICRO_BATCH_SWEEP_REPEATS`
/// counts the rounds. `MICRO_BATCH_SWEEP_BUDGET_SECONDS` stops the sweep, and
/// fails the test, instead of starting an attempt later than that many
/// seconds into the test. `MICRO_BATCH_SWEEP_PROFILE` names the validation
/// profile (default `chat-gguf-vulkan`), `MICRO_BATCH_SWEEP_NATIVE_LOG` the
/// native log level (`info` or `debug`, default `info`) and
/// `MICRO_BATCH_SWEEP_MODEL` a local copy of the profile's model.
/// `MICRO_BATCH_SWEEP_DEVICE=gpu` asks each load for `ComputeDevice.gpu`
/// first, records a typed refusal and then loads as the profile does
/// (`ComputeDevice.auto`), so one run shows both what a required GPU and what
/// the default do on the device. A blank value keeps the default.
///
/// Under Android instrumentation (Firebase Test Lab or `adb shell am
/// instrument`), `MainActivityTest` forwards the arguments `microBatchArms`
/// (`+`-separated), `microBatchRepeats`, `microBatchBudgetSeconds`,
/// `microBatchProfile`, `microBatchNativeLog` and `microBatchDevice`, and with
/// any of them saves `cmd gpu vkjson` (the Vulkan driver's properties, among
/// them the API version and the subgroup size) and the installed app APK's
/// SHA-256 next to the journal before Flutter starts.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_validation/io.dart';
import 'package:llamadart_validation/llamadart_validation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'support/micro_batch_sweep_support.dart';
import 'support/process_memory_snapshot.dart';

const _logTag = 'MICRO_BATCH_SWEEP';
const _profileAssets = 'packages/llamadart_validation/assets/profiles/';
const _argumentsFile = 'micro_batch_sweep_args.json';
const _maxLoggedText = 160;
const _defaultArm = 0;
const _historyCase = 'C06.history';
const _longCase = 'X01.long_history';
// The locked Q4_0 model answers this prompt with `42` on CPU and Metal too;
// only the Q4_K_M quantization repeats the whole `maple42`.
const _longExpected = '42';
const _longMaxTokens = 12;
const _toolMaxTokens = 128;
const _toolCases = {
  'C07.tools.auto': ToolChoice.auto,
  'C07.tools.required': ToolChoice.required,
};

/// A history of about 300 prompt tokens whose first turn holds the code. The
/// filler spells its numbers out, so a digit in the answer comes from the code.
const _longHistory = <(LlamaChatRole, String)>[
  (
    LlamaChatRole.system,
    'You are a careful assistant. Remember the access code exactly.',
  ),
  (LlamaChatRole.user, 'The access code is maple42.'),
  (LlamaChatRole.assistant, 'I will remember the access code.'),
  (
    LlamaChatRole.user,
    'Before we continue, here is a note about the warehouse. The north '
        'shelves hold garden tools, the south shelves hold paint, and the '
        'loading dock opens at seven each morning.',
  ),
  (
    LlamaChatRole.assistant,
    'Noted: garden tools north, paint south, and the dock opens at seven.',
  ),
  (
    LlamaChatRole.user,
    'Another note. The delivery van is blue, it needs new tires before '
        'winter, and the driver prefers the coastal road because it has fewer '
        'traffic lights.',
  ),
  (
    LlamaChatRole.assistant,
    'Noted: the blue van needs tires, and the driver likes the coastal road.',
  ),
  (
    LlamaChatRole.user,
    'One more. The office plants are watered on Mondays, the printer on the '
        'second floor jams when the paper is damp, and the spare keys are '
        'kept in the grey cabinet.',
  ),
  (
    LlamaChatRole.assistant,
    'Noted: plants on Mondays, a moody printer, and keys in the grey cabinet.',
  ),
  (
    LlamaChatRole.user,
    'Last note. The team lunch is on Thursday at noon, the bakery across the '
        'street closes early on Fridays, and the meeting room projector needs '
        'a new cable.',
  ),
  (
    LlamaChatRole.assistant,
    'Noted: lunch on Thursday at noon, the bakery closes early on Fridays, '
        'and the projector needs a cable.',
  ),
  (LlamaChatRole.user, 'What is the access code? Reply with only the code.'),
];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the default micro-batch answers history and tool prompts', (
    tester,
  ) async {
    final elapsed = Stopwatch()..start();
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Text('Running micro-batch sweep E2E')),
      ),
    );
    final temporary = await getTemporaryDirectory();
    final config = _Config.resolve(temporary);
    final output = Directory(
      p.join(
        ((Platform.isAndroid ? await getExternalStorageDirectory() : null) ??
                temporary)
            .path,
        'micro_batch_sweep',
      ),
    )..createSync(recursive: true);
    final journal = _Journal(File(p.join(output.path, 'journal.jsonl')));
    final nativeLog = _NativeLog.capture(
      File(p.join(output.path, 'native_stderr.log')),
    );
    addTearDown(nativeLog.restore);
    journal.log({
      'event': 'config',
      'profile': config.profile,
      'arms': config.arms,
      'repeats': config.repeats,
      'budget_seconds': config.budget?.inSeconds,
      'native_log': config.nativeLevel.name,
      'device': config.device?.name,
      'source': config.source,
      'native_stderr_captured': nativeLog.captured,
      'pid': pid,
      'os': Platform.operatingSystem,
      'os_version': Platform.operatingSystemVersion,
    });
    final logs = _LibraryLog(journal);
    // Set once, before the first engine starts its worker: ggml-vulkan prints
    // its device lines only when the process first initializes the backend.
    await LlamaLogging.configure(
      level: LlamaLogLevel.debug,
      nativeLevel: config.nativeLevel,
      handler: logs.record,
    );
    addTearDown(LlamaLogging.configure);

    final profile = await _loadProfile(config.profile);
    final modelPath = await _prepareModel(profile, config.model, journal);
    final expected = {
      _historyCase: profile.fixtureText('history', 'expected'),
      _longCase: _longExpected,
    };
    final caseIds = [...expected.keys, ..._toolCases.keys];
    final failures = <String>[];
    final correct = {
      for (final id in caseIds) id: {for (final arm in config.arms) arm: 0},
    };
    final capDecisions = {for (final arm in config.arms) arm: <String>{}};
    final budget = config.budget;
    sweep:
    for (var repeat = 1; repeat <= config.repeats; repeat++) {
      for (final arm in config.arms) {
        final labels = {'repeat': repeat, 'micro_batch': arm};
        final judged = arm == _defaultArm;
        if (budget != null && elapsed.elapsed > budget) {
          journal.log({
            'event': 'budget_exhausted',
            ...labels,
            'elapsed_seconds': elapsed.elapsed.inSeconds,
          });
          failures.add(
            'stopped before micro-batch $arm repeat $repeat: over the '
            '${budget.inSeconds} s budget',
          );
          break sweep;
        }
        logs.labels = labels;
        try {
          final results = await _attempt(
            profile,
            modelPath,
            labels,
            arm,
            config.device,
            withTools: judged || repeat == config.repeats,
            journal: journal,
            nativeLog: nativeLog,
          );
          for (final id in caseIds) {
            final result = results[id];
            if (result == null) continue;
            final passed = switch (result) {
              _Answer(:final content) when expected.containsKey(id) =>
                content.toLowerCase().contains(expected[id]!.toLowerCase()),
              _Answer(:final toolCallMatches) => toolCallMatches,
              _Failure() => false,
            };
            if (passed) {
              correct[id]![arm] = correct[id]![arm]! + 1;
            } else if (judged) {
              failures.add(
                'default micro-batch repeat $repeat $id: ${result.describe()}',
              );
            }
          }
        } on LlamaException catch (error) {
          journal.log({
            'event': 'attempt_error',
            ...labels,
            'error_type': '${error.runtimeType}',
            'error': '$error',
          });
          if (judged) {
            failures.add('default micro-batch repeat $repeat failed: $error');
          }
        }
        final decision = logs.takeCapDecision();
        capDecisions[arm]!.add(decision);
        if (decision == 'not_logged') {
          journal.log({'event': 'prompt_cap', ...labels, 'decision': decision});
        }
      }
    }
    logs.labels = const {};
    journal.log({
      'event': 'summary',
      'expected': expected,
      'repeats': config.repeats,
      'judged_micro_batch': _defaultArm,
      'correct': {
        for (final MapEntry(key: id, value: arms) in correct.entries)
          id: {
            for (final MapEntry(:key, :value) in arms.entries) '$key': value,
          },
      },
      'prompt_cap': {
        for (final MapEntry(:key, :value) in capDecisions.entries)
          '$key': value.toList(),
      },
      'failures': failures,
    });
    expect(failures, isEmpty, reason: failures.join('\n'));
  }, timeout: const Timeout(Duration(minutes: 25)));
}

class _Config {
  _Config(
    this.profile,
    this.arms,
    this.repeats,
    this.budget,
    this.nativeLevel,
    this.device,
    this.model,
    this.source,
  );

  factory _Config.resolve(Directory temporary) {
    var profile =
        optionalArgument(
          const String.fromEnvironment('MICRO_BATCH_SWEEP_PROFILE'),
        ) ??
        'chat-gguf-vulkan';
    var arms =
        optionalArgument(
          const String.fromEnvironment('MICRO_BATCH_SWEEP_ARMS'),
        ) ??
        '0,512';
    var repeats = const int.fromEnvironment(
      'MICRO_BATCH_SWEEP_REPEATS',
      defaultValue: 3,
    );
    var budget = const int.fromEnvironment('MICRO_BATCH_SWEEP_BUDGET_SECONDS');
    var nativeLog =
        optionalArgument(
          const String.fromEnvironment('MICRO_BATCH_SWEEP_NATIVE_LOG'),
        ) ??
        'info';
    var device = optionalArgument(
      const String.fromEnvironment('MICRO_BATCH_SWEEP_DEVICE'),
    );
    var source = 'dart-define';
    final file = File(p.join(temporary.path, _argumentsFile));
    if (Platform.isAndroid && file.existsSync()) {
      final arguments = jsonDecode(file.readAsStringSync()) as Map;
      // The file outlives the instrumentation that wrote it.
      if (arguments['pid'] == pid) {
        profile = optionalArgument(arguments['profile']) ?? profile;
        arms = optionalArgument(arguments['arms']) ?? arms;
        final count = optionalArgument(arguments['repeats']);
        if (count != null) repeats = int.parse(count);
        final seconds = optionalArgument(arguments['budget_seconds']);
        if (seconds != null) budget = int.parse(seconds);
        nativeLog = optionalArgument(arguments['native_log']) ?? nativeLog;
        device = optionalArgument(arguments['device']) ?? device;
        source = 'instrumentation';
      }
    }
    final sizes = [
      for (final size in arms.split(RegExp('[,+]')))
        if (size.trim().isNotEmpty) int.parse(size.trim()),
    ];
    if (sizes.isEmpty || sizes.any((size) => size < 0)) {
      throw ArgumentError.value(arms, 'arms', 'needs non-negative sizes');
    }
    if (repeats < 1) {
      throw ArgumentError.value(repeats, 'repeats', 'must be at least 1');
    }
    if (budget < 0) {
      throw ArgumentError.value(budget, 'budget', 'must not be negative');
    }
    if (!const {'info', 'debug'}.contains(nativeLog)) {
      throw ArgumentError.value(nativeLog, 'native log', 'is info or debug');
    }
    if (!const {null, 'auto', 'gpu'}.contains(device)) {
      throw ArgumentError.value(device, 'device', 'is auto or gpu');
    }
    return _Config(
      profile,
      sizes,
      repeats,
      budget == 0 ? null : Duration(seconds: budget),
      LlamaLogLevel.values.byName(nativeLog),
      device == null ? null : ComputeDevice.values.byName(device),
      optionalArgument(const String.fromEnvironment('MICRO_BATCH_SWEEP_MODEL')),
      source,
    );
  }

  final String profile;

  /// Micro-batch sizes in attempt order; 0 is the library default.
  final List<int> arms;
  final int repeats;

  /// The time into the test after which no attempt starts; null for no limit.
  final Duration? budget;
  final LlamaLogLevel nativeLevel;

  /// The device each load asks for first; null for the profile's own.
  final ComputeDevice? device;
  final String? model;
  final String source;
}

Future<ValidationProfile> _loadProfile(String id) async {
  final source = await rootBundle.loadString('$_profileAssets$id.json');
  final data = jsonDecode(source) as Map<String, dynamic>;
  data['execution_path'] = 'public_api';
  return ValidationProfile.fromJson(data);
}

Future<String> _prepareModel(
  ValidationProfile profile,
  String? supplied,
  _Journal journal,
) async {
  final cache = Directory(
    p.join(
      (await getApplicationSupportDirectory()).path,
      'validation',
      'models',
    ),
  );
  final client = http.Client();
  try {
    final model = await prepareModel(
      profile,
      cache,
      suppliedPath: supplied,
      client: client,
      timeout: const Duration(minutes: 10),
    );
    journal.log({
      'event': 'model',
      'filename': profile.filename,
      'revision': profile.model['revision'],
      ...model.evidence,
    });
    return model.path;
  } finally {
    client.close();
  }
}

/// How one request of an attempt ended.
sealed class _Result {
  String describe();
}

class _Answer extends _Result {
  _Answer(this.content, this.finishReasons, {required this.toolCallMatches});

  final String content;
  final Object? finishReasons;

  /// Whether the request ended as the fixture's tool call.
  final bool toolCallMatches;

  @override
  String describe() =>
      'answered ${jsonEncode(_shorten(content))}, finish '
      '${jsonEncode(finishReasons)}';
}

class _Failure extends _Result {
  _Failure(this.error);

  final LlamaException error;

  @override
  String describe() => 'threw ${error.runtimeType}: $error';
}

/// Loads [modelPath] on a new engine with [params].
///
/// With a [first] device other than the one in [params], that device is
/// tried first; a typed refusal is recorded and the load is repeated as
/// [params] has it.
Future<({LlamaEngine engine, ModelParams params})> _load(
  String modelPath,
  ModelParams params,
  ComputeDevice? first,
  Map<String, Object?> labels,
  _Journal journal,
) async {
  final devices = {?first, params.device};
  for (final device in devices) {
    final attempt = params.copyWith(device: device);
    final engine = LlamaEngine(LlamaBackend());
    try {
      await engine.setModel(
        LlamaModel(ModelSource.parse(modelPath)),
        params: attempt,
      );
      return (engine: engine, params: attempt);
    } on LlamaException catch (error) {
      await engine.dispose();
      journal.log({
        'event': 'load_refused',
        ...labels,
        'device': device.name,
        'error_type': '${error.runtimeType}',
        'message': error.message,
        'details': error.details?.toString(),
      });
      if (device == devices.last) rethrow;
    }
  }
  throw StateError('unreachable: the last device rethrows');
}

/// Runs one load, the requests and the dispose, and returns how each request
/// ended by case.
Future<Map<String, _Result>> _attempt(
  ValidationProfile profile,
  String modelPath,
  Map<String, Object?> labels,
  int microBatchSize,
  ComputeDevice? device, {
  required bool withTools,
  required _Journal journal,
  required _NativeLog nativeLog,
}) async {
  journal.log({'event': 'attempt_started', ...labels});
  final logStart = nativeLog.length;
  final watch = Stopwatch()..start();
  final loaded = await _load(
    modelPath,
    profile.loadParams.copyWith(microBatchSize: microBatchSize),
    device,
    labels,
    journal,
  );
  final engine = loaded.engine;
  // The validation engine sends the requests exactly as the validation suite
  // does; it is handed a loaded engine because its own load has no
  // micro-batch size and resets the log levels.
  final validation = PublicValidationEngine(engineFactory: () => engine);
  try {
    final diagnostics = await validation.diagnostics();
    final loadLog = nativeLog.since(logStart);
    final resolved = resolveModelContextBatchSizes(
      loaded.params,
      profile.contextSize,
    );
    journal.log({
      'event': 'load',
      ...labels,
      'ms': watch.elapsedMilliseconds,
      'device': loaded.params.device.name,
      'resolved_batch': resolved.batchSize,
      'resolved_micro_batch': resolved.microBatchSize,
      'native_n_batch': _contextValue(loadLog, 'n_batch'),
      'native_n_ubatch': _contextValue(loadLog, 'n_ubatch'),
      'backend_name': diagnostics['backend_name'],
      'reported_gpu_layers': diagnostics['reported_gpu_layers'],
      'context_size': diagnostics['context_size'],
      'native_log_bytes': loadLog.length,
    });
    for (final line in loadLog.split('\n')) {
      if (line.startsWith('ggml_vulkan:')) {
        journal.log({'event': 'native_device', ...labels, 'line': line.trim()});
      }
    }

    LlamaChatMessage message(
      LlamaChatRole role,
      String fixture,
      String field,
    ) => LlamaChatMessage.fromText(
      role: role,
      text: profile.fixtureText(fixture, field),
    );
    final cases = <String, List<LlamaChatMessage>?>{
      'C03.raw': null,
      'C04.hello': [message(LlamaChatRole.user, 'hello', 'prompt')],
      'C04.arithmetic': [message(LlamaChatRole.user, 'arithmetic', 'prompt')],
      _historyCase: [
        message(LlamaChatRole.system, 'history', 'system'),
        message(LlamaChatRole.user, 'history', 'user'),
        message(LlamaChatRole.assistant, 'history', 'assistant'),
        message(LlamaChatRole.user, 'history', 'prompt'),
      ],
      _longCase: [
        for (final (role, text) in _longHistory)
          LlamaChatMessage.fromText(role: role, text: text),
      ],
      if (withTools)
        for (final id in _toolCases.keys)
          id: [message(LlamaChatRole.user, 'tools', 'prompt')],
    };
    final toolFixture = profile.fixtures['tools'] as Map;
    final toolFunction = (toolFixture['tool'] as Map)['function'] as Map;
    final tool = ToolDefinition(
      name: toolFunction['name'] as String,
      description: toolFunction['description'] as String,
      parameters: [ToolParam.string('city', required: true)],
    );
    final results = <String, _Result>{};
    for (final MapEntry(key: id, value: messages) in cases.entries) {
      journal.log({'event': 'case_started', ...labels, 'case_id': id});
      final rawPrompt = profile.fixtureText('raw', 'prompt');
      final toolChoice = _toolCases[id];
      final Map<String, dynamic> output;
      try {
        output = messages == null
            ? await validation.generate(rawPrompt, profile, raw: true)
            : toolChoice != null
            ? await validation.generate(
                messages.last.content,
                profile,
                history: messages,
                tools: [tool],
                toolChoice: toolChoice,
                enableThinking: false,
                maxTokens: _toolMaxTokens,
              )
            : await validation.generate(
                messages.last.content,
                profile,
                history: messages,
                maxTokens: id == _longCase ? _longMaxTokens : null,
                streamBatchTokens: id == _longCase ? 1 : null,
              );
      } on LlamaException catch (error) {
        journal.log({
          'event': 'case_error',
          ...labels,
          'case_id': id,
          'error_type': '${error.runtimeType}',
          'message': error.message,
          'details': error.details?.toString(),
        });
        results[id] = _Failure(error);
        continue;
      }
      // llama.cpp counts a decode of one token as generation, so at
      // micro-batch size 1 its prompt counter leaves the prompt out.
      final promptTokens = messages == null
          ? (await engine.tokenize(rawPrompt)).length
          : (await engine.chatTemplate(
              messages,
              enableThinking: toolChoice == null && profile.enableThinking,
              tools: toolChoice == null ? null : [tool],
              toolChoice: toolChoice ?? ToolChoice.auto,
            )).tokenCount;
      final call = reconstructToolCall(output['tool_call_deltas'] as List);
      final toolCallMatches =
          canonicalJson(output['finish_reasons']) ==
              canonicalJson(['tool_calls']) &&
          call.wellFormed &&
          call.name == tool.name &&
          canonicalJson(call.arguments) ==
              canonicalJson(toolFixture['expected_arguments']);
      final metrics = output['metrics'] as Map;
      final promptMs = metrics['native_prompt_ms'] as double?;
      journal.log({
        'event': 'case',
        ...labels,
        'case_id': id,
        'prompt_tokens': promptTokens,
        'native_prompt_tokens': metrics['native_prompt_tokens'],
        'native_decode_tokens': metrics['native_decode_tokens'],
        'finish_reasons': output['finish_reasons'],
        'content': output['content'],
        if (toolChoice != null) ...{
          'tool_choice': toolChoice.name,
          'tool_call_name': call.name,
          'tool_call_arguments': call.arguments,
          'tool_call_matches': toolCallMatches,
        },
        'chunks': output['chunks'],
        'max_tokens': output['max_tokens'],
        'stream_batch_tokens': output['stream_batch_tokens'],
        'wall_ms': metrics['wall_ms'],
        'ttfa_ms': metrics['ttfa_ms'],
        'native_prompt_ms': promptMs,
        'prompt_tps': promptTokens == null || promptMs == null || promptMs <= 0
            ? null
            : promptTokens * 1000 / promptMs,
        'native_decode_ms': metrics['native_decode_ms'],
      });
      results[id] = _Answer(
        output['content'] as String,
        output['finish_reasons'],
        toolCallMatches: toolCallMatches,
      );
    }
    return results;
  } finally {
    await validation.dispose();
  }
}

/// The value llama.cpp logs for [name] when it creates a context
/// (`llama_context: n_ubatch = 512`), or null when the line is missing.
int? _contextValue(String log, String name) {
  final match = RegExp(
    '^llama_context: $name\\s*=\\s*(\\d+)',
    multiLine: true,
  ).firstMatch(log);
  return match == null ? null : int.parse(match[1]!);
}

String _shorten(String text) => text.length <= _maxLoggedText
    ? text
    : '${text.substring(0, _maxLoggedText)}...';

class _Journal {
  _Journal(this._file) {
    _file.writeAsStringSync('', flush: true);
  }

  final File _file;

  void log(Map<String, Object?> event) {
    _file.writeAsStringSync(
      '${jsonEncode(event)}\n',
      mode: FileMode.append,
      flush: true,
    );
    // Android truncates a log line near 1 kB, and debugPrint buffers, which
    // loses the last records when the process dies.
    // ignore: avoid_print
    print(
      '$_logTag ${jsonEncode({for (final MapEntry(:key, :value) in event.entries) key: value is String ? _shorten(value) : value})}',
    );
  }
}

/// Journals the `LlamaLogger` records and reads the prompt cap decision out
/// of them.
class _LibraryLog {
  _LibraryLog(this._journal);

  final _Journal _journal;

  /// The attempt the next records belong to.
  Map<String, Object?> labels = const {};
  String? _capDecision;

  void record(LlamaLogRecord record) {
    _journal.log({
      'event': 'log',
      ...labels,
      'level': record.level.name,
      'message': record.message,
      'error': record.error?.toString(),
    });
    final decision = parsePromptCapDecision(record.message);
    if (decision == null) return;
    _capDecision = decision.capTokens == null ? 'not_capped' : 'capped';
    _journal.log({
      'event': 'prompt_cap',
      ...labels,
      'decision': _capDecision,
      'cap_tokens': decision.capTokens,
      'devices': [
        for (final device in decision.devices)
          {
            'name': device.name,
            'api_version': device.apiVersion,
            'loader_api_version': device.loaderApiVersion,
            'subgroup_size': device.subgroupSize,
          },
      ],
      'detail': decision.detail,
    });
  }

  /// The decision logged since the last call, or `not_logged`.
  String takeCapDecision() {
    final decision = _capDecision ?? 'not_logged';
    _capDecision = null;
    return decision;
  }
}

typedef _CreatNative = Int32 Function(Pointer<Utf8>, Uint32);
typedef _Creat = int Function(Pointer<Utf8>, int);
typedef _DupNative = Int32 Function(Int32);
typedef _Dup = int Function(int);
typedef _Dup2Native = Int32 Function(Int32, Int32);
typedef _Dup2 = int Function(int, int);

/// Standard error of this process, pointed at a file while the test runs.
class _NativeLog {
  _NativeLog._(this._file, this._saved);

  /// Points descriptor 2 at [file]. Where that is not possible, the test
  /// still runs and records that native output was not captured.
  factory _NativeLog.capture(File file) {
    file.writeAsStringSync('', flush: true);
    if (Platform.isWindows) return _NativeLog._(file, null);
    try {
      final process = DynamicLibrary.process();
      final creat = process.lookupFunction<_CreatNative, _Creat>('creat');
      final dup = process.lookupFunction<_DupNative, _Dup>('dup');
      final path = file.path.toNativeUtf8();
      try {
        final descriptor = creat(path, 420);
        if (descriptor < 0) return _NativeLog._(file, null);
        final saved = dup(2);
        final redirected = _dup2(descriptor, 2) == 2;
        _close(descriptor);
        if (!redirected) {
          if (saved >= 0) _close(saved);
          return _NativeLog._(file, null);
        }
        return _NativeLog._(file, saved);
      } finally {
        malloc.free(path);
      }
    } on ArgumentError {
      return _NativeLog._(file, null);
    }
  }

  static final _Dup2 _dup2 = DynamicLibrary.process()
      .lookupFunction<_Dup2Native, _Dup2>('dup2');
  static final _Dup _close = DynamicLibrary.process()
      .lookupFunction<_DupNative, _Dup>('close');

  final File _file;
  final int? _saved;
  bool _restored = false;

  bool get captured => _saved != null;

  int get length => _file.lengthSync();

  /// The output written after byte [offset].
  String since(int offset) => utf8.decode(
    _file.readAsBytesSync().sublist(offset),
    allowMalformed: true,
  );

  void restore() {
    final saved = _saved;
    if (saved == null || _restored) return;
    _restored = true;
    if (saved >= 0) {
      _dup2(saved, 2);
      _close(saved);
    }
  }
}
