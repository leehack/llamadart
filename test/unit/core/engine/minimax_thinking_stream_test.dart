import 'package:llamadart/src/core/engine/chat_completion_stream_parser.dart';
import 'package:llamadart/src/core/models/chat/completion_chunk.dart';
import 'package:llamadart/src/core/models/inference/tool_choice.dart';
import 'package:llamadart/src/core/models/tools/tool_definition.dart';
import 'package:llamadart/src/core/models/tools/tool_param.dart';
import 'package:llamadart/src/core/template/chat_format.dart';
import 'package:llamadart/src/core/template/chat_template_engine.dart';
import 'package:test/test.dart';

const _namespace = ']<]minimax[>[';
const _end = '</mm:think>';
const _envelope =
    '$_namespace<tool_call>$_namespace<invoke name="weather">'
    '$_namespace<city>Seoul$_namespace</city>'
    '$_namespace</invoke>$_namespace</tool_call>';
final _tool = ToolDefinition(
  name: 'weather',
  description: 'Get weather',
  handler: (params) async => 'sunny',
  parameters: [ToolParam.string('city', description: 'City', required: true)],
);

Future<List<LlamaCompletionChunk>> _parse(
  List<String> tokens, {
  bool forcedOpen = true,
  bool enableThinking = true,
  ToolChoice toolChoice = ToolChoice.required,
}) {
  final template = ChatTemplateEngine.render(
    // Synthetic routing fixture, not evidence of real MiniMax emissions.
    templateSource:
        '{# $_namespace<tool_call><invoke name= #}'
        '${forcedOpen ? '<mm:think>' : ''}',
    messages: const [],
    metadata: const {},
    tools: [_tool],
    toolChoice: toolChoice,
    enableThinking: true,
  );
  expect(template.format, ChatFormat.minimaxM3.index);
  expect(template.thinkingForcedOpen, forcedOpen);
  return ChatCompletionStreamParser.parse(
    tokenStream: Stream.fromIterable(tokens),
    templateResult: template,
    parseToolCallsEnabled: toolChoice != ToolChoice.none,
    enableThinking: enableThinking,
    modelName: 'synthetic-minimax-m3',
    completionId: 'partial-thinking',
    tools: [_tool],
  ).toList();
}

String _thinking(List<LlamaCompletionChunk> chunks) =>
    chunks.map((chunk) => chunk.choices.single.delta.thinking ?? '').join();
String _content(List<LlamaCompletionChunk> chunks) =>
    chunks.map((chunk) => chunk.choices.single.delta.content ?? '').join();

void main() {
  group('MiniMax M3 thinking stream', () {
    for (final forcedOpen in [true, false]) {
      for (final toolChoice in [ToolChoice.auto, ToolChoice.required]) {
        final prefix = '${forcedOpen ? '' : '<mm:think>'}reason';
        final output = '$prefix$_end$_envelope';
        final partitions = <String, List<String>>{
          'whole': [output],
          'characters': output.split(''),
          for (var split = 1; split < _end.length; split++)
            'closing split $split': [
              '$prefix${_end.substring(0, split)}',
              '${_end.substring(split)}$_envelope',
            ],
        };
        for (final partition in partitions.entries) {
          test(
            'forced=$forcedOpen choice=$toolChoice ${partition.key}',
            () async {
              final chunks = await _parse(
                partition.value,
                forcedOpen: forcedOpen,
                toolChoice: toolChoice,
              );
              expect(_thinking(chunks), 'reason');
              expect(_content(chunks), isEmpty);
              final call = chunks
                  .expand((c) => c.choices.single.delta.toolCalls ?? const [])
                  .single;
              expect(call.function?.name, 'weather');
              expect(call.function?.arguments, '{"city":"Seoul"}');
              expect(chunks.last.choices.single.finishReason, 'tool_calls');
            },
          );
        }
      }
    }

    test(
      'malformed final tool envelope rolls back without reasoning leakage',
      () async {
        final malformed = _envelope.replaceFirst(
          'name="weather"',
          'name="unknown"',
        );
        final chunks = await _parse('reason$_end$malformed'.split(''));
        expect(_thinking(chunks), 'reason');
        expect(_content(chunks), malformed);
        expect(
          chunks.expand((c) => c.choices.single.delta.toolCalls ?? const []),
          isEmpty,
        );
        expect(chunks.last.choices.single.finishReason, 'stop');
      },
    );

    for (final suffix in ['<', '</mm:th', '</mm:thX', '<mm:thX']) {
      test(
        'preserves genuine reasoning suffix $suffix at EOF and before close',
        () async {
          for (final ending in ['', '$_end$_envelope']) {
            final output = 'reason$suffix$ending';
            for (final tokens in [
              [output],
              output.split(''),
            ]) {
              final chunks = await _parse(tokens);
              expect(_thinking(chunks), 'reason$suffix');
              expect(_content(chunks), isEmpty);
            }
          }
        },
      );
    }

    test(
      'disabled thinking still suppresses split delimiters and emits tools',
      () async {
        final chunks = await _parse(
          'reason$_end$_envelope'.split(''),
          enableThinking: false,
        );
        expect(_thinking(chunks), isEmpty);
        expect(_content(chunks), isEmpty);
        expect(chunks.last.choices.single.finishReason, 'tool_calls');
      },
    );

    test(
      'tool choice none preserves ordinary answer after split thinking',
      () async {
        final chunks = await _parse(
          'reason${_end}answer'.split(''),
          toolChoice: ToolChoice.none,
        );
        expect(_thinking(chunks), 'reason');
        expect(_content(chunks), 'answer');
        expect(chunks.last.choices.single.finishReason, 'stop');
      },
    );
  });
}
