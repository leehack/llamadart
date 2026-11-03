@Tags(['local-only', 'e2e'])
@Timeout(Duration(minutes: 20))
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_validation/android_consumer_profile.dart';
import 'package:llamadart_validation/android_qualification.dart';
import 'package:llamadart_validation/android_qualification_io.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Android consumer CPU full/compact release smoke', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: Text('CPU release smoke')));
    if (!Platform.isAndroid || !kReleaseMode) {
      throw UnsupportedError('Android release instrumentation required');
    }
    final plan = AndroidConsumerProfilePlan(
      const String.fromEnvironment('LLAMADART_ANDROID_CPU_PROFILE'),
    );
    final cache = await getTemporaryDirectory();
    final config =
        jsonDecode(
              File(
                '${cache.path}/android_qualification_args.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    if (config['pid'] != pid ||
        config['scenario'] != 'consumer-cpu' ||
        !const ['old', 'modern'].contains(config['consumer_device_class'])) {
      throw StateError('Missing or stale consumer instrumentation arguments');
    }
    final binding = readAndroidQualificationBinding(
      jsonEncode(config['binding']),
      plan.fixture,
      consumerCpuProfile: plan.profile,
      consumerPlanHash: plan.hash,
    );
    if (binding['source_commit'] !=
            const String.fromEnvironment('LLAMADART_SOURCE_COMMIT') ||
        binding['source_tree'] !=
            const String.fromEnvironment('LLAMADART_SOURCE_TREE')) {
      throw StateError(
        'Compiled source identity differs from admitted profile',
      );
    }
    final output = Directory(config['output'] as String);
    final journal = File('${output.path}/diagnostic.jsonl');
    void record(Map<String, Object?> value) => journal.writeAsStringSync(
      '${jsonEncode(value)}\n',
      mode: FileMode.append,
      flush: true,
    );
    final watchdog = File('${cache.path}/android_qualification_watchdog.json');
    var step = 0;
    Future<T> guarded<T>(String name, Future<T> Function() action) async {
      final partial = File('${watchdog.path}.partial');
      partial.writeAsStringSync(
        jsonEncode({
          'nonce': config['nonce'],
          'pid': pid,
          'step': '${step++}-$name',
          'timeout_ms': 120000,
        }),
        flush: true,
      );
      partial.renameSync(watchdog.path);
      try {
        return await action();
      } finally {
        if (watchdog.existsSync()) watchdog.deleteSync();
      }
    }

    final raw = <String>{'app_apk.sha256', 'vkjson.json'};
    final cases = <String, String>{};
    Object? failure;
    String? active;
    String? firstOutput;
    record({
      'event': 'manifest',
      'schema': 1,
      'plan': plan.wire,
      'binding': binding,
      'execution_binding': androidQualificationExecutionHash(binding),
      'pid': pid,
      'device_class': config['consumer_device_class'],
      'device_model': config['device_model'],
      'android_api': config['android_api'],
      'device_build': config['device_build'],
      'soc_model': config['soc_model'],
      'qualified': false,
    });
    try {
      final model = File('${cache.path}/firebase-model.gguf');
      final directory = Directory(config['native_directory'] as String);
      await guarded('verify', () async {
        await verifyAndroidQualificationFile(model, plan.fixture.model);
        for (final entry in (binding['libraries'] as Map).entries) {
          await verifyAndroidQualificationFile(
            File('${directory.path}/${entry.key}'),
            entry.value as Map,
          );
        }
        final cpuInfo = File('/proc/cpuinfo').readAsStringSync();
        File(
          '${output.path}/cpuinfo.txt',
        ).writeAsStringSync(cpuInfo, flush: true);
        raw.add('cpuinfo.txt');
      });
      await LlamaLogging.configure(
        level: LlamaLogLevel.debug,
        nativeLevel: LlamaLogLevel.info,
      );
      for (final id in plan.caseIds) {
        active = id;
        record({'event': 'case_started', 'case_id': id});
        raw.addAll(['$id.stderr.log', '$id.maps']);
        await guarded(id, () async {
          final capture = AndroidQualificationStderr.capture(
            File('${output.path}/$id.stderr.log'),
          );
          final engine = LlamaEngine(LlamaBackend());
          try {
            final loadClock = Stopwatch()..start();
            await engine.setModel(
              LlamaModel(ModelSource.path(model.path)),
              params: plan.params,
            );
            loadClock.stop();
            final identity = await engine.stateIdentity();
            record({
              'event': 'runtime_identity',
              'case_id': id,
              'runtime_build': identity.runtimeBuild,
              'session_format_version': identity.sessionFormatVersion,
              'allocated_context_size': identity.contextSize,
              'context_configuration_digest': identity.contextConfigDigest,
            });
            final backend = await engine.getBackendName();
            final gpuLayers = await engine.getResolvedGpuLayers();
            record({
              'event': 'public_loaded',
              'case_id': id,
              'backend': backend,
              'gpu_layers': gpuLayers,
              'load_ms': loadClock.elapsedMicroseconds / 1000,
            });
            if (backend.toLowerCase() != 'cpu' || gpuLayers != 0) {
              throw StateError('Public CPU placement mismatch');
            }
            final geometryBytes = File(
              '${output.path}/$id.stderr.log',
            ).readAsBytesSync();
            record({
              'event': 'public_geometry_stderr_snapshot',
              'case_id': id,
              'bytes': geometryBytes.length,
              'sha256': sha256.convert(geometryBytes).toString(),
            });
            if (!matchesAndroidQualificationGeometry(
              androidQualificationDiagnosticText(geometryBytes),
              plan.fixture,
            )) {
              throw StateError(
                'Public effective geometry missing or mismatched',
              );
            }
            final chunks = <String>[];
            final generateClock = Stopwatch()..start();
            await for (final chunk in engine.generate(
              plan.fixture.prompts.single,
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
            generateClock.stop();
            final text = chunks.join();
            record({
              'event': 'public_output',
              'case_id': id,
              'output': text,
              'generation_ms': generateClock.elapsedMicroseconds / 1000,
              'nonempty_chunks': chunks.where((s) => s.isNotEmpty).length,
            });
            if (chunks.every((s) => s.isEmpty) ||
                !androidConsumerOutputPasses(text) ||
                (firstOutput != null && text != firstOutput)) {
              throw StateError('Paris fixture or exact reload output mismatch');
            }
            firstOutput ??= text;
            final maps = File('/proc/self/maps').readAsStringSync();
            File(
              '${output.path}/$id.maps',
            ).writeAsStringSync(maps, flush: true);
            await verifyAndroidQualificationMaps(
              maps,
              directory,
              binding,
              vulkan: false,
            );
            if (!maps.contains('/libggml-cpu-android_')) {
              throw StateError('No installed Android CPU module mapped');
            }
          } finally {
            try {
              await engine.dispose();
            } finally {
              capture.close();
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
        cases[id] = 'PASS';
        record({'event': 'public_disposed', 'case_id': id});
      }
    } on Object catch (error) {
      failure = error;
      if (active != null) cases[active] = 'ERROR';
      record({
        'event': 'failure',
        'type': error.runtimeType.toString(),
        'reason': error is StateError
            ? error.message
            : 'Consumer smoke failed; raw evidence retained',
      });
    } finally {
      final complete = exportAndroidQualificationRaw(output, raw, record);
      if (!complete) failure ??= StateError('Raw export incomplete');
      record({
        'event': 'summary',
        'qualified': false,
        'functional_assertions_passed': failure == null,
        'raw_export_complete': complete,
        'case_inventory': {
          for (final id in plan.caseIds) id: {'status': cases[id] ?? 'NOT_RUN'},
        },
        'crash_assessment':
            'requires process-scoped provider logcat and terminal state',
      });
      File(
        '${output.path}/watchdog.done',
      ).writeAsStringSync(config['nonce'] as String, flush: true);
    }
    expect(
      failure,
      isNull,
      reason: 'Consumer smoke failed; retain original evidence',
    );
  }, timeout: const Timeout(Duration(minutes: 20)));
}
