import 'package:genkit/genkit.dart' as genkit;
import 'package:llamadart/llamadart.dart' as llama;
import 'package:test/test.dart';

import '../../../../core/runtime/test_support/fake_runtime.dart';
import '../test_support/action_harness.dart';

void main() {
  // A Seed-OSS template that opens no thought, as the stock one, and one that
  // opens it.
  const stock = '{#- <seed:think> -#}assistant\n';
  const opened = 'assistant\n<seed:think>';

  Future<genkit.ModelResponse> generate(
    String templateSource,
    String output, {
    required bool enableThinking,
  }) {
    final runtime = FakeRuntime()
      ..templateResult = llama.ChatTemplateEngine.render(
        templateSource: templateSource,
        messages: const [
          llama.LlamaChatMessage.fromText(
            role: llama.LlamaChatRole.user,
            text: 'Respond with JSON',
          ),
        ],
        metadata: const {},
        responseFormat: const {
          'type': 'json_schema',
          'json_schema': {
            'schema': {'type': 'object'},
          },
        },
        enableThinking: enableThinking,
      )
      ..generatedTokens = [output];
    expect(runtime.templateResult.format, llama.ChatFormat.seedOss.index);
    return testModelAction(runtime: runtime)(
      genkit.ModelRequest(
        messages: [
          genkit.Message(
            role: genkit.Role.user,
            content: [genkit.TextPart(text: 'Respond with JSON')],
          ),
        ],
        output: genkit.OutputConfig(
          format: 'json',
          schema: {
            'type': 'object',
            'properties': {
              'answer': {'type': 'string'},
            },
          },
        ),
      ),
    );
  }

  String? reasoning(genkit.ModelResponse response) => response.message!.content
      .where((part) => part.isReasoning)
      .singleOrNull
      ?.reasoning;

  // Values from llama.cpp 620d2225, as llamadart's engine parses them.
  test('takes a Seed-OSS thought as the render left it', () async {
    for (final (source, enableThinking) in const [
      (opened, false),
      (opened, true),
    ]) {
      final response = await generate(
        source,
        'Plan</seed:think>{"answer":"hi"}',
        enableThinking: enableThinking,
      );
      expect(response.text, '{"answer":"hi"}');
      expect(reasoning(response), 'Plan');
    }

    final leading = await generate(
      stock,
      '<seed:think>Plan</seed:think>{"answer":"hi"}',
      enableThinking: true,
    );
    expect(leading.text, '{"answer":"hi"}');
    expect(reasoning(leading), 'Plan');
  });

  test('parses no tool call from output when no tool is declared', () async {
    for (final (field, output) in const [
      ('response', '{"response":{"answer":"hi"}}'),
      ('tool_call', '{"tool_call":{"name":"lookup","arguments":{"q":"x"}}}'),
    ]) {
      final runtime = FakeRuntime()..generatedTokens = [output];
      final response = await testModelAction(runtime: runtime)(
        genkit.ModelRequest(
          messages: [
            genkit.Message(
              role: genkit.Role.user,
              content: [genkit.TextPart(text: 'Respond with JSON')],
            ),
          ],
          output: genkit.OutputConfig(
            format: 'json',
            schema: {
              'type': 'object',
              'properties': {
                field: {'type': 'object'},
              },
              'required': [field],
            },
          ),
        ),
      );
      expect(response.text, output);
      expect(response.toolRequests, isEmpty);
    }
  });

  test('keeps an end tag the stock template never opened in the content', () {
    expect(
      generate(stock, 'Plan</seed:think>{"answer":"hi"}', enableThinking: true),
      throwsA(
        isA<genkit.GenkitException>().having(
          (error) => error.status,
          'status',
          genkit.StatusCode.failedPrecondition,
        ),
      ),
    );
  });
}
