@Tags(['local-only', 'e2e'])
@Timeout(Duration(minutes: 19))
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:llamadart_validation/android_litert_qualification_runner.dart';
import 'package:llamadart_validation/android_litert_qualification.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('S24 frozen LiteRT public/native qualification', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Text('S24 LiteRT qualification')),
    );
    if (!Platform.isAndroid) {
      throw UnsupportedError('Android instrumentation required');
    }
    final cache = await getTemporaryDirectory();
    final config =
        jsonDecode(
              File(
                '${cache.path}/s24_litert_public_args.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    if (config['pid'] != pid) {
      throw StateError('Stale S24 instrumentation arguments');
    }
    final stage = Directory(config['stage'] as String);
    final expectedBinding = config['binding_sha256'];
    const compiledBinding = String.fromEnvironment('S24_LITERT_BINDING_SHA256');
    if (compiledBinding != expectedBinding ||
        (await sha256.bind(File('${stage.path}/binding.json').openRead()).first)
                .toString() !=
            expectedBinding) {
      throw StateError(
        'S24 instrumentation binding was not admitted into this build',
      );
    }
    for (final backend in ['cpu', 'gpu']) {
      final actual = jsonDecode(
        await rootBundle.loadString(
          'packages/llamadart_validation/assets/profiles/chat-litert-$backend.json',
        ),
      );
      final expected = (config['binding'] as Map)['profiles'][backend];
      if (jsonEncode(actual) != jsonEncode(expected)) {
        throw StateError('S24 build changed a maintained profile');
      }
    }
    final journal = File('${config['output']}/s24-litert-public.jsonl');
    if (journal.existsSync()) throw StateError('Fresh S24 journal required');
    Map<String, dynamic>? terminal;
    final completedCases = <String>{};
    final watchdog = File(config['watchdog'] as String);
    void watchdogRecord(Map<String, dynamic> value) {
      final temporary = File('${watchdog.path}.partial');
      temporary.writeAsStringSync(
        jsonEncode({'pid': pid, 'nonce': config['nonce'], ...value}),
        flush: true,
      );
      temporary.renameSync(watchdog.path);
    }

    void record(Map<String, dynamic> value) {
      journal.writeAsStringSync(
        '${jsonEncode(value)}\n',
        mode: FileMode.append,
        flush: true,
      );
      if (value['event'] == 'stage_started') {
        watchdogRecord({
          'step': value['stage_sequence'],
          'timeout_ms': value['deadline_ms'],
        });
      }
      if (value['event'] == 'complete') terminal = value;
      if (value['event'] == 'case_result') {
        completedCases.add(value['case_id'] as String);
      }
    }

    Object? error;
    try {
      await runS24LiteRtQualification(config, record);
    } on Object catch (caught) {
      error = caught;
      record({
        'event': 'execution_failed',
        'error_type': caught.runtimeType.toString(),
        'error': '$caught',
      });
    } finally {
      // A runner retaining unsettled native work never reaches this boundary.
      watchdogRecord({'finished': true});
      final raw = await journal.readAsBytes();
      binding.reportData = {
        'journal_file': 's24-litert-public.jsonl',
        'journal_bytes': raw.length,
        'journal_sha256': sha256.convert(raw).toString(),
        'terminal': terminal,
        'unexecuted_required_cases': s24LiteRtCases
            .where((id) => !completedCases.contains(id))
            .toList(),
        'qualified': false,
        'error_type': error?.runtimeType.toString(),
      };
    }
    expect(
      error,
      isNull,
      reason:
          'Every required gate must complete; legacy semantic failures remain separately visible.',
    );
  });
}
