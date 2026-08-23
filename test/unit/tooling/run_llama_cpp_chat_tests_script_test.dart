@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  group('run_llama_cpp_chat_tests.sh', () {
    late String script;

    setUpAll(() {
      script = File(
        'tool/testing/run_llama_cpp_chat_tests.sh',
      ).readAsStringSync();
    });

    test('supports renamed upstream chat parser target', () {
      expect(script, contains('test-chat-auto-parser'));
      expect(script, contains('test-chat-parser'));
      expect(script, contains('resolve_target'));
      expect(script, contains(r'(:|$|[[:space:]])'));
    });

    test(
      'runs built llama.cpp test binaries with their build library path',
      () {
        expect(script, contains('DYLD_LIBRARY_PATH'));
        expect(script, contains('LD_LIBRARY_PATH'));
        expect(script, contains('bin/test-chat'));
      },
    );

    test(
      'builds full upstream chat suite without patching prepared source',
      () {
        expect(script, contains('build_tools=ON'));
        expect(script, contains('build_server=ON'));
        expect(script, contains(r'-I${src_dir}/tools/mtmd'));
        expect(script, contains('CMAKE_CXX_FLAGS'));
        expect(
          script,
          contains('instead of patching the prepared upstream source'),
        );
      },
    );

    test('bounds build parallelism by default and supports an override', () {
      expect(
        script,
        contains(r'build_jobs="${LLAMA_CPP_CHAT_TEST_BUILD_JOBS:-2}"'),
      );
      expect(script, contains(r'--parallel "${build_jobs}"'));
      expect(script, isNot(contains('setsid')));
      for (final workflowPath in const [
        '.github/workflows/ci.yml',
        '.github/workflows/trusted_high_risk_regression_gate.yml',
      ]) {
        expect(
          File(workflowPath).readAsStringSync(),
          contains('LLAMA_CPP_CHAT_TEST_BUILD_JOBS=2'),
          reason: workflowPath,
        );
      }
    });

    test('rejects an invalid build-jobs override before preparation', () async {
      final result = await Process.run(
        'bash',
        const ['tool/testing/run_llama_cpp_chat_tests.sh'],
        environment: const {'LLAMA_CPP_CHAT_TEST_BUILD_JOBS': '0'},
        includeParentEnvironment: true,
      );
      expect(result.exitCode, isNot(0));
      final output = '${result.stdout}\n${result.stderr}';
      expect(
        output,
        contains('LLAMA_CPP_CHAT_TEST_BUILD_JOBS must be a positive integer.'),
      );
    });

    test(
      'full-suite process adds its flag and inherits ref/source inputs',
      () async {
        final e2eSource = File(
          'test/e2e/template/llama_cpp_chat_tests_e2e_test.dart',
        ).readAsStringSync();
        expect(e2eSource, contains('includeParentEnvironment: true'));

        final directory = await Directory.systemTemp.createTemp(
          'llamadart-full-chat-environment-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final environmentReader = File(
          '${directory.path}/environment_reader.dart',
        );
        await environmentReader.writeAsString('''
import 'dart:convert';
import 'dart:io';
void main() {
  stdout.write(jsonEncode({
    'LLAMA_CPP_REF': Platform.environment['LLAMA_CPP_REF'],
    'LLAMA_CPP_SOURCE_DIR': Platform.environment['LLAMA_CPP_SOURCE_DIR'],
    'LLAMA_CPP_CHAT_TEST_INCLUDE_FULL':
        Platform.environment['LLAMA_CPP_CHAT_TEST_INCLUDE_FULL'],
  }));
}
''');
        final probe = File('${directory.path}/probe.dart');
        await probe.writeAsString('''
import 'dart:io';
Future<void> main(List<String> args) async {
  final result = await Process.run(
    Platform.resolvedExecutable,
    [args.single],
    environment: const <String, String>{
      'LLAMA_CPP_CHAT_TEST_INCLUDE_FULL': '1',
    },
    includeParentEnvironment: true,
  );
  if (result.exitCode != 0) {
    stderr.write(result.stderr);
    exitCode = result.exitCode;
    return;
  }
  stdout.write(result.stdout);
}
''');
        final result = await Process.run(
          Platform.resolvedExecutable,
          [probe.path, environmentReader.path],
          environment: {
            'LLAMA_CPP_REF': 'ref-sentinel',
            'LLAMA_CPP_SOURCE_DIR': directory.path,
          },
          includeParentEnvironment: true,
        );
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
        final environment = jsonDecode(result.stdout as String);
        expect(environment, isA<Map<String, dynamic>>());
        final values = environment as Map<String, dynamic>;
        expect(values['LLAMA_CPP_REF'], 'ref-sentinel');
        expect(values['LLAMA_CPP_SOURCE_DIR'], directory.path);
        expect(values['LLAMA_CPP_CHAT_TEST_INCLUDE_FULL'], '1');
      },
    );
  });
}
