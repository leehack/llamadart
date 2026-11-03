@Tags(['local-only', 'e2e'])
@Timeout(Duration(minutes: 20))
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_validation/android_qualification.dart';
import 'package:llamadart_validation/android_qualification_io.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('paired Android native/public diagnostic', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Text('Android diagnostic')),
    );
    if (!Platform.isAndroid) {
      throw UnsupportedError('Android instrumentation required');
    }
    final cache = await getTemporaryDirectory();
    final config =
        jsonDecode(
              File(
                '${cache.path}/android_qualification_args.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    if (config['pid'] != pid) {
      throw StateError('Stale instrumentation arguments');
    }
    final scenario = AndroidQualificationScenario.values.byName(
      config['scenario'] as String,
    );
    final plan = AndroidQualificationPlan(scenario);
    final binding = readAndroidQualificationBinding(
      jsonEncode(config['binding']),
      plan,
    );
    final executionBinding = androidQualificationExecutionHash(binding);
    final output = Directory(config['output'] as String);
    final journal = File('${output.path}/diagnostic.jsonl');
    void record(Map<String, dynamic> value) => journal.writeAsStringSync(
      '${jsonEncode(value)}\n',
      mode: FileMode.append,
      flush: true,
    );
    final cases = <String, Map<String, dynamic>>{};
    String? activeCase;
    record({
      'event': 'manifest',
      'schema': 1,
      'plan': plan.wire,
      'binding': binding,
      'execution_binding': executionBinding,
      'device': {
        for (final key in [
          'device_model',
          'device_manufacturer',
          'device_build',
          'android_api',
          'soc_model',
        ])
          key: config[key],
      },
      'qualified': false,
      'public_process_scope': 'serialized_complete_engine_lifetimes',
    });
    final watchdog = File('${cache.path}/android_qualification_watchdog.json');
    var step = 0;
    Future<T> guarded<T>(String name, Future<T> Function() run) async {
      final temporary = File('${watchdog.path}.partial');
      temporary.writeAsStringSync(
        jsonEncode({
          'nonce': config['nonce'],
          'pid': pid,
          'step': '${step++}-$name',
          'timeout_ms': scenario == AndroidQualificationScenario.a35
              ? 60000
              : 120000,
        }),
        flush: true,
      );
      temporary.renameSync(watchdog.path);
      try {
        return await run();
      } finally {
        if (watchdog.existsSync()) watchdog.deleteSync();
      }
    }

    Object? failure;
    try {
      final model = File('${cache.path}/firebase-model.gguf');
      await guarded('prepare', () async {
        await verifyAndroidQualificationFile(model, plan.model);
        final device = (config['device_model'] as String).toLowerCase();
        if ((scenario == AndroidQualificationScenario.a35 &&
                (!device.startsWith('sm-a356') ||
                    config['android_api'] != 35)) ||
            (scenario == AndroidQualificationScenario.pixel8a &&
                (!device.contains('pixel 8a') ||
                    config['android_api'] != 34))) {
          throw StateError('Wrong diagnostic device or OS');
        }
        final directory = Directory(config['native_directory'] as String);
        for (final entry in (binding['libraries'] as Map).entries) {
          await verifyAndroidQualificationFile(
            File('${directory.path}/${entry.key}'),
            entry.value as Map,
          );
        }
      });
      final directory = Directory(config['native_directory'] as String);
      final executable =
          '${directory.path}/libllamadart_android_qualification.so';
      Future<List<Map<String, dynamic>>> native(
        String backend, {
        bool probe = false,
        bool launch = false,
      }) async {
        final id = '${scenario.name}.native.$backend${probe ? '-probe' : ''}';
        activeCase = launch ? null : id;
        record({
          'event': 'case_started',
          'case_id': id,
          'model_free_launch': launch,
        });
        final captured = await captureAndroidNativeChild(
          executable: executable,
          arguments: [
            launch
                ? 'probe'
                : probe
                ? 'pixel8a-probe'
                : scenario.name,
            backend,
            model.path,
            directory.path,
            executionBinding,
            id,
            scenario == AndroidQualificationScenario.a35 ? '60' : '120',
          ],
          output: Directory('${output.path}/${launch ? 'launch' : id}'),
          binding: executionBinding,
          caseId: id,
          timeout: Duration(
            seconds: scenario == AndroidQualificationScenario.a35 ? 60 : 120,
          ),
          environment: {'LD_LIBRARY_PATH': directory.path},
        );
        record({
          'event': 'native_capture',
          'case_id': id,
          'model_free_launch': launch,
          'capture': captured,
        });
        if (captured['exit_code'] != 0 ||
            captured['protocol_complete'] != true) {
          throw StateError('Native child failed; raw evidence retained');
        }
        final records = (captured['records'] as List)
            .cast<Map<String, dynamic>>();
        final maps = records.singleWhere((value) => value['event'] == 'maps');
        await verifyAndroidQualificationMaps(
          _unhex(maps['maps_hex'] as String),
          directory,
          binding,
          vulkan: !launch && backend.startsWith('vulkan'),
        );
        if (!launch) {
          cases[id] = {
            'status': 'OBSERVED',
            'records': records,
            'placement_status': 'REQUIRES_INDEPENDENT_ASSESSMENT',
          };
        }
        return records;
      }

      // Launch proof is explicit and model-free; it is not inferred from ELF inspection.
      await native('cpu', launch: true);
      final nativeValues = <String, List<Map<String, dynamic>>>{};
      if (scenario == AndroidQualificationScenario.pixel8a) {
        for (final backend in plan.nativeBackends) {
          final values = await native(backend, probe: true);
          nativeValues['$backend-probe'] = values;
          if (!assessAndroidEmbeddingRecords(
            values,
            backend == 'cpu' ? values : nativeValues['cpu-probe']!,
            probeOnly: true,
          )) {
            throw StateError(
              'Native probe correctness failed; timings NOT_RUN',
            );
          }
          cases[activeCase]!['status'] = 'PASS';
        }
      }
      for (final backend in plan.nativeBackends) {
        final values = await native(backend);
        nativeValues[backend] = values;
        if (scenario == AndroidQualificationScenario.pixel8a) {
          if (!assessAndroidEmbeddingRecords(
            values,
            nativeValues['cpu-probe']!,
            probeOnly: false,
          )) {
            throw StateError(
              'Native timing vectors failed; timings unadmitted',
            );
          }
          cases[activeCase]!['status'] = 'PASS';
          cases[activeCase]!['warm_medians'] = androidEmbeddingWarmMedians(
            values,
            timingField: 'operation_ms',
          );
        } else {
          if (!assessAndroidGenerationRecords(values)) {
            throw StateError('Invalid native generation control');
          }
          cases[activeCase]!['status'] = 'PASS';
        }
      }
      await LlamaLogging.configure(
        level: LlamaLogLevel.debug,
        nativeLevel: LlamaLogLevel.info,
      );
      List<Map<String, dynamic>>? publicCpu;
      for (final backend in [
        'cpu',
        'vulkan',
        if (scenario == AndroidQualificationScenario.a35) 'vulkan-reload',
      ]) {
        final actual = backend == 'vulkan-reload' ? 'vulkan' : backend;
        final id = '${scenario.name}.public.$backend';
        activeCase = id;
        record({'event': 'case_started', 'case_id': id});
        final values = <Map<String, dynamic>>[];
        await guarded(id, () async {
          final stderr = AndroidQualificationStderr.capture(
            File('${output.path}/$id.stderr.log'),
          );
          final engine = LlamaEngine(LlamaBackend());
          try {
            await engine.setModel(
              LlamaModel(ModelSource.path(model.path)),
              params: plan.params(actual),
            );
            final diagnosticBytes = File(
              '${output.path}/$id.stderr.log',
            ).readAsBytesSync();
            record({
              'event': 'public_geometry_stderr_snapshot',
              'case_id': id,
              'bytes': diagnosticBytes.length,
              'sha256': sha256.convert(diagnosticBytes).toString(),
              'text_view': 'utf8_allow_malformed',
            });
            if (!matchesAndroidQualificationGeometry(
              androidQualificationDiagnosticText(diagnosticBytes),
              plan,
            )) {
              throw StateError(
                'Public effective context geometry missing or mismatched',
              );
            }
            record({
              'event': 'public_loaded',
              'case_id': id,
              'backend': await engine.getBackendName(),
              'gpu_layers': await engine.getResolvedGpuLayers(),
            });
            if (scenario == AndroidQualificationScenario.a35) {
              final chunks = <String>[];
              await for (final chunk in engine.generate(
                plan.prompts.single,
                params: const GenerationParams(
                  maxTokens: 24,
                  temp: 0,
                  seed: 1,
                  penalty: 1,
                  reusePromptPrefix: false,
                ),
              )) {
                chunks.add(chunk);
                record({
                  'event': 'public_delta',
                  'case_id': id,
                  'content': chunk,
                });
              }
              final text = chunks.join();
              values.add({'event': 'generation', 'output': text});
              record({'event': 'public_output', 'case_id': id, 'output': text});
              final reference = nativeValues[actual]!.singleWhere(
                (value) => value['event'] == 'generation',
              );
              if (text != _unhex(reference['output_hex'] as String)) {
                throw StateError('Public/native text mismatch');
              }
            } else {
              for (var input = 0; input < 2; input++) {
                final tokenIds = await androidQualificationEmbeddingTokens(
                  engine,
                  plan.prompts[input],
                );
                record({
                  'event': 'public_embedding_tokenization',
                  'case_id': id,
                  'input': input,
                  'add_special': true,
                  'token_ids': tokenIds,
                });
                if (tokenIds.length != (input == 0 ? 9 : 46)) {
                  throw StateError('Public token count mismatch');
                }
                for (final phase
                    in plan.configuration['timing_phases'] as List<String>) {
                  final clock = Stopwatch()..start();
                  final vector = await engine.embed(
                    plan.prompts[input],
                    normalize: true,
                  );
                  clock.stop();
                  final value = {
                    'event': 'embedding',
                    'input': input,
                    'phase': phase,
                    'tokens': tokenIds.length,
                    'sdk_wall_ms': clock.elapsedMicroseconds / 1000,
                    'vector': [
                      for (final value in vector) value.isFinite ? value : null,
                    ],
                    'vector_f64_le_base64': androidQualificationVectorBytes(
                      vector,
                    ),
                  };
                  values.add(value);
                  record({'event': 'public_vector', 'case_id': id, ...value});
                  final reference = nativeValues['cpu-probe']!.singleWhere(
                    (value) =>
                        value['event'] == 'embedding' &&
                        value['input'] == input,
                  );
                  if (assessAndroidEmbedding(
                        vector,
                        _vector(reference),
                      )['passed'] !=
                      true) {
                    throw StateError(
                      'Public/native embedding correctness failed; later timings NOT_RUN',
                    );
                  }
                  if (actual == 'vulkan') {
                    final cpu = publicCpu!.firstWhere(
                      (value) => value['input'] == input,
                    );
                    if (assessAndroidEmbedding(
                          vector,
                          _vector(cpu),
                        )['passed'] !=
                        true) {
                      throw StateError('Public CPU/Vulkan correctness failed');
                    }
                  }
                }
              }
            }
            final maps = File('/proc/self/maps').readAsStringSync();
            File(
              '${output.path}/$id.maps',
            ).writeAsStringSync(maps, flush: true);
            await verifyAndroidQualificationMaps(
              maps,
              directory,
              binding,
              vulkan: actual == 'vulkan',
            );
          } finally {
            try {
              await engine.dispose();
            } finally {
              stderr.close();
              final bytes = File(
                '${output.path}/$id.stderr.log',
              ).readAsBytesSync();
              record({
                'event': 'public_stderr_capture',
                'case_id': id,
                'bytes': bytes.length,
                'sha256': sha256.convert(bytes).toString(),
              });
            }
          }
        });
        cases[id] = {
          'status': 'PASS',
          'records': values,
          'placement_status': 'REQUIRES_INDEPENDENT_ASSESSMENT',
          if (scenario == AndroidQualificationScenario.pixel8a)
            'warm_medians': androidEmbeddingWarmMedians(
              values,
              timingField: 'sdk_wall_ms',
            ),
        };
        record({'event': 'public_disposed', 'case_id': id});
        if (actual == 'cpu') publicCpu = values;
      }
      if (scenario == AndroidQualificationScenario.a35) {
        final cpu = _unhex(
          nativeValues['cpu']!.singleWhere(
                (value) => value['event'] == 'generation',
              )['output_hex']
              as String,
        );
        final gpu = _unhex(
          nativeValues['vulkan']!.singleWhere(
                (value) => value['event'] == 'generation',
              )['output_hex']
              as String,
        );
        record({
          'event': 'cpu_gpu_parity',
          'passed': cpu == gpu,
          'cpu': cpu,
          'gpu': gpu,
        });
        if (cpu != gpu) throw StateError('Strict CPU/GPU text parity failed');
      }
    } on Object catch (error) {
      failure = error;
      if (activeCase != null) cases[activeCase!] = {'status': 'ERROR'};
      record({
        'event': 'failure',
        'type': error.runtimeType.toString(),
        'reason': error is StateError
            ? error.message
            : 'Diagnostic failed; raw files retained',
      });
    } finally {
      record({
        'event': 'summary',
        'qualified': false,
        'functional_assertions_passed': failure == null,
        'placement_status': 'REQUIRES_INDEPENDENT_ASSESSMENT',
        'case_inventory': {
          for (final id in plan.caseIds) id: cases[id] ?? {'status': 'NOT_RUN'},
        },
        'limits': [
          'public cells share a process',
          'cache/thermal/order effects uncontrolled',
          'original semantic/issue failures are not waived',
          'provider cleanup assessed externally',
        ],
      });
      File(
        '${output.path}/watchdog.done',
      ).writeAsStringSync(config['nonce'] as String, flush: true);
    }
    expect(
      failure,
      isNull,
      reason: 'Diagnostic assertions failed; original evidence retained.',
    );
  }, timeout: const Timeout(Duration(minutes: 20)));
}

String _unhex(String text) {
  if (text.length.isOdd || !RegExp(r'^[a-f0-9]*$').hasMatch(text)) {
    throw const FormatException('Invalid native byte capture');
  }
  return utf8.decode([
    for (var i = 0; i < text.length; i += 2)
      int.parse(text.substring(i, i + 2), radix: 16),
  ]);
}

List<double> _vector(Map value) => (value['vector'] as List)
    .map((value) => (value as num).toDouble())
    .toList();
