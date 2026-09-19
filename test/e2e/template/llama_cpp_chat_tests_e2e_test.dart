@TestOn('vm')
@Tags(['local-only', 'e2e'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:llamadart/llamadart.dart';
import 'package:test/test.dart';

import '../../support/qwen_tool_schema_fixture.dart';

void main() {
  test('runs upstream llama.cpp chat test selection', () async {
    const scriptPath = 'tool/testing/run_llama_cpp_chat_tests.sh';
    final script = File(scriptPath);
    expect(script.existsSync(), isTrue, reason: 'Missing $scriptPath');

    final result = await Process.run(script.path, const <String>[]);
    final output = '${result.stdout}\n${result.stderr}';
    expect(
      result.exitCode,
      equals(0),
      reason: 'llama.cpp chat tests failed:\n$output',
    );
  });

  test('runs upstream llama.cpp full chat test suite', () async {
    const scriptPath = 'tool/testing/run_llama_cpp_chat_tests.sh';
    final script = File(scriptPath);
    expect(script.existsSync(), isTrue, reason: 'Missing $scriptPath');

    final result = await Process.run(
      script.path,
      const <String>[],
      environment: const <String, String>{
        'LLAMA_CPP_CHAT_TEST_INCLUDE_FULL': '1',
      },
      includeParentEnvironment: true,
    );
    final output = '${result.stdout}\n${result.stderr}';
    expect(
      result.exitCode,
      equals(0),
      reason: 'llama.cpp full chat tests failed:\n$output',
    );
  });

  test(
    'Qwen schema history matches pinned upstream template rendering',
    () async {
      final build =
          Platform.environment['LLAMA_CPP_CHAT_TEST_BUILD_DIR'] ??
          '${Directory.current.path}/.dart_tool/llama_cpp_chat_tests';
      final binary = File('$build/bin/test-chat-template');
      expect(
        binary.existsSync(),
        isTrue,
        reason: 'Run the upstream selection to build test-chat-template.',
      );
      final temp = Directory.systemTemp.createTempSync(
        'qwen-tool-result-parity-',
      );
      addTearDown(() => temp.deleteSync(recursive: true));
      for (final thinking in [true, false]) {
        // Independent upstream input oracle: the public typed payload is encoded
        // as JSON text, without calling the production normalization helper.
        final messages =
            jsonDecode(
                  jsonEncode(
                    qwenResultHistory().map((m) => m.toJson()).toList(),
                  ),
                )
                as List<dynamic>;
        ((messages[1]['tool_calls'] as List).single['function']
                as Map)['arguments'] =
            qwenResultPayload;
        final input = File('${temp.path}/input.json')
          ..writeAsStringSync(
            jsonEncode({
              'messages': messages,
              'tools': [qwenResultTool.toJson()],
              'bos_token': '<|im_start|>',
              'eos_token': '<|im_end|>',
              'add_generation_prompt': true,
              'enable_thinking': thinking,
            }),
          );
        final output = File('${temp.path}/prompt.txt');
        final result = await Process.run(binary.path, [
          '--no-common',
          '--json',
          input.path,
          '--output',
          output.path,
          File(qwenResultTemplatePath).absolute.path,
        ]);
        expect(
          result.exitCode,
          0,
          reason: 'Upstream Qwen render failed: ${result.stderr}',
        );
        expect(output.existsSync(), isTrue);
        final rendered = renderQwenResultHistory(
          choice: ToolChoice.auto,
          thinking: thinking,
          templateSource: File(qwenResultTemplatePath).readAsStringSync(),
        );
        // Upstream tojson uses spaced separators; Dart emits compact JSON.
        // Canonicalize only the tools declaration, preserving history and the
        // generation/thinking suffix byte-for-byte.
        expect(
          _canonicalToolDeclarations(rendered.prompt),
          _canonicalToolDeclarations(output.readAsStringSync()),
        );
        expect(rendered.prompt, contains(jsonEncode(qwenResultPayload)));
      }
    },
  );
}

String _canonicalToolDeclarations(String prompt) => prompt.replaceFirstMapped(
  RegExp(r'<tools>\n(.*?)\n</tools>', dotAll: true),
  (match) =>
      '<tools>\n${match.group(1)!.split('\n').map((line) => jsonEncode(jsonDecode(line))).join('\n')}\n</tools>',
);
