@Tags(['local-only', 'e2e'])
@Timeout(Duration(minutes: 18))
/// Local-only E2E that measures what a LiteRT-LM engine leaves behind when it
/// is deleted (https://github.com/leehack/litert-lm-native/issues/59).
///
/// Each variant creates an engine, generates, deletes it and repeats in one
/// process. Every step logs `LITERT_RELOAD_MEMORY {json}` lines with the
/// process memory counters and appends them to
/// `litert_reload_memory/journal.jsonl` (app external files on Android, the
/// temporary directory elsewhere), next to the raw `dumpsys` text of each
/// step, so the records survive the process being killed. The test fails when
/// the memory left after a delete keeps growing from one reload to the next;
/// the first reload is not counted, because a runtime may fill caches then
/// that it reuses afterwards. A run of fewer than three iterations records
/// the steps without that check.
///
/// A `step_started` record precedes every step, so a run that dies names the
/// step it died in: when the low-memory killer or a native crash ends the app,
/// the runner reports that the test failed to run, and the journal is the
/// result. Each `generate` step records the generated text (first
/// 400 characters) with its length and three signals of a broken decode; the
/// `cpu` variant is the reference for the same prompt and sampler
/// (https://github.com/leehack/litert-lm-native/issues/51).
///
/// Variants are `cpu` or `gpu`, optionally with one suffix:
/// `-create-only` (no generation), `-reuse` (one engine, repeated
/// generations) or `-settle` (a 15 s wait after each delete). The model is the
/// locked `chat-litert-*` validation model, downloaded and hash-checked unless
/// `LITERT_RELOAD_MODEL` names a local copy.
///
/// ```bash
/// cd example/chat_app
/// flutter test --run-skipped -t local-only \
///   integration_test/litert_lm_reload_memory_e2e_test.dart -d <device> \
///   --dart-define=LITERT_RELOAD_VARIANTS=cpu,gpu \
///   --dart-define=LITERT_RELOAD_ITERATIONS=4
/// ```
///
/// `LITERT_RELOAD_PROMPTS` replaces the profile prompt with one or more
/// prompts separated by `|`, `LITERT_RELOAD_CHAT=true` sends them through the
/// chat template with thinking off instead of as raw text, and
/// `LITERT_RELOAD_TEMPERATURE` and `LITERT_RELOAD_SEED` override the profile's
/// greedy sampler (temperature 0, seed 1). A blank value keeps the default.
///
/// Under Android instrumentation (Firebase Test Lab or `adb shell am
/// instrument`), `MainActivityTest` forwards the arguments
/// `litertReloadVariants` (`+`-separated), `litertReloadIterations`,
/// `litertReloadPrompts`, `litertReloadChat`, `litertReloadTemperature`,
/// `litertReloadSeed` and `memorySnapshots=true`. The last one adds
/// `dumpsys meminfo` and `dumpsys gpu --gpumem` to every step, which is the
/// only counter here that includes driver-owned graphics memory per process,
/// and saves `cmd gpu vkjson` (the Vulkan driver's limits) and the installed
/// app APK's SHA-256 once.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

import 'support/process_memory_snapshot.dart';

const _logTag = 'LITERT_RELOAD_MEMORY';
const _profileAssets = 'packages/llamadart_validation/assets/profiles/';
const _argumentsFile = 'litert_reload_memory_args.json';
const _requestFile = 'litert_reload_memory.request';
const _responseFile = 'litert_reload_memory.response';
const _stepTimeout = Duration(minutes: 3);
const _growthFloorKb = 64 * 1024;
const _maxLogLine = 600;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('LiteRT-LM engine deletes do not accumulate memory', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Text('Running LiteRT-LM reload memory E2E')),
      ),
    );
    final temporary = await getTemporaryDirectory();
    final config = _Config.resolve(temporary);
    final output = Directory(
      p.join(
        ((Platform.isAndroid ? await getExternalStorageDirectory() : null) ??
                temporary)
            .path,
        'litert_reload_memory',
      ),
    )..createSync(recursive: true);
    final recorder = _Recorder(
      temporary,
      File(p.join(output.path, 'journal.jsonl')),
      dumpsys: config.snapshots,
    );
    recorder.log({
      'event': 'config',
      'variants': [for (final variant in config.variants) variant.name],
      'iterations': config.iterations,
      'prompts': config.prompts,
      'chat': config.chat,
      'temperature': config.temperature,
      'seed': config.seed,
      'dumpsys': config.snapshots,
      'source': config.source,
      'pid': pid,
      'os': Platform.operatingSystem,
      'os_version': Platform.operatingSystemVersion,
    });
    await LlamaLogging.configure(nativeLevel: LlamaLogLevel.debug);

    final failures = <String>[];
    String? modelPath;
    for (final variant in config.variants) {
      final profile = await _loadProfile(variant.backend);
      modelPath ??= await _prepareModel(profile, recorder);
      recorder.modelPathFragments = [p.basename(modelPath)];
      final summary = await _runVariant(
        variant,
        profile,
        modelPath,
        config,
        recorder,
      );
      if (summary == null) {
        recorder.log({
          'event': 'summary',
          'variant': variant.name,
          'skipped': 'memory growth needs at least three iterations',
        });
        continue;
      }
      recorder.log({'event': 'summary', ...summary.toJson()});
      if (summary.growthPerReloadKb > summary.thresholdKb) {
        failures.add(
          '${variant.name}: memory after delete grew by '
          '${summary.growthPerReloadKb} kB per reload over '
          '${summary.readings} readings (limit ${summary.thresholdKb} kB, '
          'one engine costs ${summary.engineCostKb} kB, counter '
          '${summary.source})',
        );
      }
    }
    expect(failures, isEmpty, reason: failures.join('\n'));
  });
}

class _Variant {
  _Variant(this.name)
    : backend = name.split('-').first,
      mode = name.contains('-') ? name.substring(name.indexOf('-') + 1) : '' {
    if (!const {'cpu', 'gpu'}.contains(backend) ||
        !const {'', 'create-only', 'reuse', 'settle'}.contains(mode)) {
      throw ArgumentError.value(
        name,
        'variant',
        'Expected cpu or gpu, optionally with -create-only, -reuse or -settle',
      );
    }
  }

  final String name;
  final String backend;
  final String mode;

  bool get generates => mode != 'create-only';
  bool get reusesEngine => mode == 'reuse';
  Duration get settle => Duration(seconds: mode == 'settle' ? 15 : 2);
}

class _Config {
  _Config(
    this.variants,
    this.iterations,
    this.snapshots,
    this.source, {
    required this.prompts,
    required this.chat,
    required this.temperature,
    required this.seed,
  });

  factory _Config.resolve(Directory temporary) {
    var variants =
        optionalArgument(
          const String.fromEnvironment('LITERT_RELOAD_VARIANTS'),
        ) ??
        'cpu,gpu';
    var iterations = const int.fromEnvironment(
      'LITERT_RELOAD_ITERATIONS',
      defaultValue: 4,
    );
    var prompts = optionalArgument(
      const String.fromEnvironment('LITERT_RELOAD_PROMPTS'),
    );
    var chat = const bool.fromEnvironment('LITERT_RELOAD_CHAT');
    var temperature = optionalArgument(
      const String.fromEnvironment('LITERT_RELOAD_TEMPERATURE'),
    );
    var seed = optionalArgument(
      const String.fromEnvironment('LITERT_RELOAD_SEED'),
    );
    var snapshots = false;
    var source = 'dart-define';
    final file = File(p.join(temporary.path, _argumentsFile));
    if (Platform.isAndroid && file.existsSync()) {
      final arguments = jsonDecode(file.readAsStringSync()) as Map;
      // The file outlives the instrumentation that wrote it; one from an
      // earlier process must not make this run wait for a dead responder.
      if (arguments['pid'] == pid) {
        variants = optionalArgument(arguments['variants']) ?? variants;
        final count = optionalArgument(arguments['iterations']);
        if (count != null) iterations = int.parse(count);
        prompts = optionalArgument(arguments['prompts']) ?? prompts;
        final chatArgument = optionalArgument(arguments['chat']);
        if (chatArgument != null) chat = bool.parse(chatArgument);
        temperature = optionalArgument(arguments['temperature']) ?? temperature;
        seed = optionalArgument(arguments['seed']) ?? seed;
        snapshots = arguments['snapshots'] == true;
        source = 'instrumentation';
      }
    }
    if (iterations < 1) {
      throw ArgumentError.value(iterations, 'iterations', 'must be at least 1');
    }
    final parsed = [
      for (final name in variants.split(RegExp('[,+]')))
        if (name.trim().isNotEmpty) _Variant(name.trim()),
    ];
    if (parsed.isEmpty) {
      throw ArgumentError.value(variants, 'variants', 'names no variant');
    }
    return _Config(
      parsed,
      iterations,
      snapshots,
      source,
      prompts: [
        for (final prompt in (prompts ?? '').split('|'))
          if (prompt.trim().isNotEmpty) prompt.trim(),
      ],
      chat: chat,
      temperature: temperature == null ? null : double.parse(temperature),
      seed: seed == null ? null : int.parse(seed),
    );
  }

  final List<_Variant> variants;
  final int iterations;
  final bool snapshots;
  final String source;

  /// Empty for the profile's own prompt.
  final List<String> prompts;
  final bool chat;

  /// Null for the profile's sampler value.
  final double? temperature;
  final int? seed;
}

class _Summary {
  _Summary({
    required this.variant,
    required this.source,
    required this.engineCostKb,
    required this.growthPerReloadKb,
    required this.retainedAfterFirstKb,
    required this.readings,
    required this.openFilesGrowth,
  });

  final String variant;
  final String source;
  final int engineCostKb;
  final int growthPerReloadKb;
  final int retainedAfterFirstKb;
  final int readings;

  /// Open descriptors at the last reading minus the second, where `/proc`
  /// lists them: a GPU device that is never destroyed keeps its descriptors.
  final int? openFilesGrowth;

  int get thresholdKb =>
      engineCostKb ~/ 10 > _growthFloorKb ? engineCostKb ~/ 10 : _growthFloorKb;

  Map<String, Object?> toJson() => {
    'variant': variant,
    'counter': source,
    'engine_cost_kb': engineCostKb,
    'growth_per_reload_kb': growthPerReloadKb,
    'retained_after_first_kb': retainedAfterFirstKb,
    'threshold_kb': thresholdKb,
    'readings': readings,
    'open_files_growth': openFilesGrowth,
  };
}

Future<ValidationProfile> _loadProfile(String backend) async {
  final source = await rootBundle.loadString(
    '${_profileAssets}chat-litert-$backend.json',
  );
  final data = jsonDecode(source) as Map<String, dynamic>;
  data['execution_path'] = 'public_api';
  return ValidationProfile.fromJson(data);
}

Future<String> _prepareModel(
  ValidationProfile profile,
  _Recorder recorder,
) async {
  final supplied = optionalArgument(
    const String.fromEnvironment('LITERT_RELOAD_MODEL'),
  );
  final cache = Directory(
    p.join(
      (await getApplicationSupportDirectory()).path,
      'validation',
      'models',
    ),
  );
  final client = http.Client();
  final watch = Stopwatch()..start();
  try {
    final model = await prepareModel(
      profile,
      cache,
      suppliedPath: supplied,
      client: client,
      timeout: const Duration(minutes: 10),
    );
    recorder.log({
      'event': 'model',
      'path': model.path,
      'sha256': profile.modelHash,
      'prepare_ms': watch.elapsedMilliseconds,
    });
    return model.path;
  } finally {
    client.close();
  }
}

Future<_Summary?> _runVariant(
  _Variant variant,
  ValidationProfile profile,
  String modelPath,
  _Config config,
  _Recorder recorder,
) async {
  final iterations = config.iterations;
  final prompts = config.prompts.isEmpty
      ? [profile.fixtureText('hello', 'prompt')]
      : config.prompts;
  final params = profile.generationParams.copyWith(
    temp: config.temperature,
    seed: config.seed,
  );
  recorder.log({
    'event': 'generation',
    'variant': variant.name,
    'chat': config.chat,
    'max_tokens': params.maxTokens,
    'temperature': params.temp,
    'seed': params.seed,
    // The request; LiteRT-LM samples top-k 1 whenever the temperature is 0.
    'top_k': params.topK,
    'top_p': params.topP,
    'penalty': params.penalty,
  });
  final baseline = await recorder.snapshot(variant, 0, 'baseline');
  var peak = baseline.accountedKb;
  final readings = <_Snapshot>[];
  LlamaEngine? engine;

  // [details] is read when the step ends, so [run] can fill it.
  Future<void> timed(
    int iteration,
    String step,
    Future<void> Function() run, {
    Map<String, Object?> details = const {},
  }) async {
    final labels = {
      'variant': variant.name,
      'iteration': iteration,
      'step': step,
    };
    recorder.log({
      'event': 'step_started',
      ...labels,
      'elapsed_ms': recorder.elapsedMs,
    });
    final watch = Stopwatch()..start();
    Object? failure;
    try {
      await run().timeout(_stepTimeout);
    } catch (error) {
      failure = error;
      rethrow;
    } finally {
      recorder.log({
        'event': 'step',
        ...labels,
        'ms': watch.elapsedMilliseconds,
        ...details,
        'error': ?failure?.toString(),
      });
    }
  }

  Future<void> record(int iteration, String step, {bool alive = true}) async {
    final snapshot = await recorder.snapshot(variant, iteration, step);
    if (alive && snapshot.accountedKb > peak) peak = snapshot.accountedKb;
  }

  var failed = false;
  try {
    for (var iteration = 1; iteration <= iterations; iteration++) {
      if (engine == null) {
        final created = engine = LlamaEngine(LlamaBackend());
        await timed(iteration, 'create', () async {
          await created.setModel(
            LlamaModel(ModelSource.parse(modelPath)),
            params: profile.loadParams,
          );
          // LiteRT-LM creates the native engine on first use, not in setModel.
          await created.tokenize(prompts.first);
        });
        await record(iteration, 'after_create');
      }
      if (variant.generates) {
        final current = engine;
        for (final (index, prompt) in prompts.indexed) {
          final details = <String, Object?>{'prompt': index};
          await timed(iteration, 'generate', details: details, () async {
            final text = config.chat
                ? await current
                      .create(
                        [
                          LlamaChatMessage.fromText(
                            role: LlamaChatRole.user,
                            text: prompt,
                          ),
                        ],
                        params: params,
                        enableThinking: false,
                      )
                      .text()
                : await current.generate(prompt, params: params).join();
            details['output'] = describeGeneratedText(text);
            expect(
              text.trim(),
              isNotEmpty,
              reason: '${variant.name} iteration $iteration generated no text',
            );
          });
        }
        await record(iteration, 'after_generate');
      }
      if (variant.reusesEngine) {
        readings.add(recorder.last);
        continue;
      }
      final disposing = engine;
      engine = null;
      await timed(iteration, 'delete', disposing.dispose);
      await record(iteration, 'after_delete', alive: false);
      await Future<void>.delayed(variant.settle);
      await record(iteration, 'after_delete_settled', alive: false);
      readings.add(recorder.last);
    }
  } catch (_) {
    failed = true;
    rethrow;
  } finally {
    try {
      await engine?.dispose();
    } on LlamaException catch (error) {
      recorder.log({
        'event': 'cleanup_error',
        'variant': variant.name,
        'error': '$error',
      });
      // The step that failed is the result; a dispose that fails after it
      // must not replace it.
      if (!failed) rethrow;
    }
  }
  if (variant.reusesEngine) {
    await Future<void>.delayed(variant.settle);
    await record(iterations, 'after_delete_settled', alive: false);
  }
  if (readings.length < 3) return null;
  final counters = {
    baseline.accountedSource,
    for (final reading in readings) reading.accountedSource,
  };
  if (counters.length > 1) {
    final message =
        '${variant.name}: the memory counter changed during the run '
        '(${counters.join(', ')}), so its readings cannot be compared';
    recorder.log({
      'event': 'summary',
      'variant': variant.name,
      'error': message,
    });
    fail(message);
  }
  final accumulation = reloadAccumulation(
    baseline: baseline.accountedKb,
    peak: peak,
    settledAfterDelete: [for (final reading in readings) reading.accountedKb],
  );
  final firstOpenFiles = readings[1].openFiles;
  final lastOpenFiles = readings.last.openFiles;
  return _Summary(
    variant: variant.name,
    source: baseline.accountedSource,
    engineCostKb: accumulation.engineCost,
    growthPerReloadKb: accumulation.growthPerReload,
    retainedAfterFirstKb: accumulation.retainedAfterFirst,
    readings: readings.length,
    openFilesGrowth: firstOpenFiles == null || lastOpenFiles == null
        ? null
        : lastOpenFiles - firstOpenFiles,
  );
}

class _Snapshot {
  _Snapshot(this.accountedKb, this.accountedSource, this.openFiles);

  final int accountedKb;
  final String accountedSource;
  final int? openFiles;
}

class _Recorder {
  _Recorder(this._temporary, this._journal, {required bool dumpsys})
    : _dumpsys = dumpsys {
    _journal.writeAsStringSync('', flush: true);
  }

  final Directory _temporary;
  final File _journal;
  final Stopwatch _elapsed = Stopwatch()..start();
  bool _dumpsys;
  List<String> modelPathFragments = const [];
  late _Snapshot last;

  int get elapsedMs => _elapsed.elapsedMilliseconds;

  void log(Map<String, Object?> event) {
    final line = jsonEncode(event);
    _journal.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
    // Android truncates a log line near 1 kB, so nested counters go out as
    // one line each.
    if (line.length <= _maxLogLine) {
      _print(line);
      return;
    }
    final nested = {
      for (final MapEntry(:key, :value) in event.entries)
        if (value is Map) key: value,
    };
    _print(
      jsonEncode({
        for (final MapEntry(:key, :value) in event.entries)
          if (value is! Map) key: value,
      }),
    );
    for (final MapEntry(:key, :value) in nested.entries) {
      _print(
        jsonEncode({
          'event': '${event['event']}_part',
          'variant': event['variant'],
          'iteration': event['iteration'],
          'step': event['step'],
          'part': key,
          'values': value,
        }),
      );
    }
  }

  // debugPrint buffers, which loses the last records when the process is
  // killed for memory.
  // ignore: avoid_print
  void _print(String line) => print('$_logTag $line');

  Future<_Snapshot> snapshot(
    _Variant variant,
    int iteration,
    String step,
  ) async {
    final record = <String, Object?>{
      'event': 'snapshot',
      'variant': variant.name,
      'iteration': iteration,
      'step': step,
      'elapsed_ms': _elapsed.elapsedMilliseconds,
      'rss_kb': ProcessInfo.currentRss ~/ 1024,
    };
    int? systemUsedKb;
    if (Platform.isAndroid || Platform.isLinux) {
      final meminfo = _readKb('/proc/meminfo', const [
        'MemTotal',
        'MemAvailable',
        'MemFree',
        'Cached',
        'SwapTotal',
        'SwapFree',
      ]);
      record['meminfo'] = meminfo;
      final total = meminfo['MemTotal'];
      final available = meminfo['MemAvailable'];
      if (total != null && available != null) {
        systemUsedKb = total - available;
      }
      record['status'] = _readKb('/proc/self/status', const [
        'VmRSS',
        'VmHWM',
        'RssAnon',
        'RssFile',
        'RssShmem',
        'VmSwap',
      ]);
      record['smaps_rollup'] = _readKb('/proc/self/smaps_rollup', const [
        'Rss',
        'Pss',
        'Pss_Anon',
        'Pss_File',
        'Pss_Shmem',
        'Swap',
        'SwapPss',
      ]);
      record['maps'] = _guard(
        () => summarizeMaps(
          File('/proc/self/maps').readAsStringSync(),
          modelPathFragments: modelPathFragments,
        ),
      );
      record['fds'] = _guard(
        () => Directory('/proc/self/fd').listSync().length,
      );
      record['fd_kinds'] = _guard(_readDescriptorKinds);
      record['threads'] = _guard(
        () => Directory('/proc/self/task').listSync().length,
      );
    }
    Map<String, int> dumpsys = const {};
    if (_dumpsys) {
      try {
        final text = await _requestDumpsys('${variant.name}:$iteration:$step');
        File(
          p.join(
            _journal.parent.path,
            'dumpsys_${variant.name}_${iteration}_$step.txt',
          ),
        ).writeAsStringSync(text, flush: true);
        dumpsys = parseDumpsysMeminfo(text);
        record['dumpsys'] = dumpsys;
        record['gpumem'] = parseDumpsysGpuMem(text, pid);
      } on TimeoutException catch (error) {
        _dumpsys = false;
        record['dumpsys_error'] = '$error';
      }
    }
    final totalPss = dumpsys['summary_total_pss_kb'];
    final fds = record['fds'];
    final openFiles = fds is int ? fds : null;
    final result = totalPss != null
        ? _Snapshot(totalPss, 'dumpsys meminfo TOTAL PSS', openFiles)
        : systemUsedKb != null && Platform.isAndroid
        ? _Snapshot(systemUsedKb, 'device MemTotal - MemAvailable', openFiles)
        : _Snapshot(ProcessInfo.currentRss ~/ 1024, 'process RSS', openFiles);
    record['accounted_kb'] = result.accountedKb;
    record['counter'] = result.accountedSource;
    log(record);
    return last = result;
  }

  Map<String, int> _readKb(String path, List<String> keys) {
    try {
      return parseProcKb(File(path).readAsStringSync(), keys);
    } on FileSystemException {
      return const {};
    }
  }

  Object? _guard(Object? Function() read) {
    try {
      return read();
    } on FileSystemException catch (error) {
      return 'unavailable: ${error.osError?.message ?? error.message}';
    }
  }

  Map<String, int> _readDescriptorKinds() {
    final targets = <String>[];
    for (final entry in Directory(
      '/proc/self/fd',
    ).listSync(followLinks: false)) {
      try {
        targets.add(Link(entry.path).targetSync());
      } on FileSystemException {
        // The descriptor closed between the listing and the read.
      }
    }
    return summarizeDescriptorTargets(targets);
  }

  Future<String> _requestDumpsys(String label) async {
    final request = File(p.join(_temporary.path, _requestFile));
    final response = File(p.join(_temporary.path, _responseFile));
    if (response.existsSync()) response.deleteSync();
    request.writeAsStringSync(label, flush: true);
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (!response.existsSync()) {
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException(
          'No dumpsys response for $label; later steps skip dumpsys',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    final text = response.readAsStringSync();
    response.deleteSync();
    return text;
  }
}
