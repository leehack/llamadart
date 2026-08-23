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
        final probe = File('${directory.path}/probe.dart');
        await probe.writeAsString('''
import 'dart:io';
Future<void> main() async {
  final result = await Process.run(
    '/usr/bin/env',
    const <String>[],
    environment: const <String, String>{
      'LLAMA_CPP_CHAT_TEST_INCLUDE_FULL': '1',
    },
    includeParentEnvironment: true,
  );
  stdout.write(result.stdout);
}
''');
        final result = await Process.run(
          Platform.resolvedExecutable,
          [probe.path],
          environment: const {
            'LLAMA_CPP_REF': 'ref-sentinel',
            'LLAMA_CPP_SOURCE_DIR': '/tmp/source-sentinel',
          },
          includeParentEnvironment: true,
        );
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
        final environment = LineSplitter.split(result.stdout as String).toSet();
        expect(environment, contains('LLAMA_CPP_REF=ref-sentinel'));
        expect(
          environment,
          contains('LLAMA_CPP_SOURCE_DIR=/tmp/source-sentinel'),
        );
        expect(environment, contains('LLAMA_CPP_CHAT_TEST_INCLUDE_FULL=1'));
      },
    );
  });
}
