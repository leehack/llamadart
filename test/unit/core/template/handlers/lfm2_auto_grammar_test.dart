import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/core/template/handlers/lfm2_auto_grammar.dart';
import 'package:test/test.dart';

void main() {
  test('no declared tools adds no grammar', () {
    expect(buildLfm2AutoGrammar(null, parallelToolCalls: false), isNull);
    expect(buildLfm2AutoGrammar([], parallelToolCalls: true), isNull);
  });

  test('rejects an empty enum instead of emitting an accepting fallback', () {
    expect(
      () => buildLfm2AutoGrammar([
        ToolDefinition(
          name: 'choose',
          description: '',
          parameters: [
            ToolParam.enumType('choice', values: [], required: true),
          ],
        ),
      ], parallelToolCalls: false),
      throwsA(isA<LlamaUnsupportedException>()),
    );
  });

  test('bounds unique-argument grammar expansion before generation', () {
    expect(
      () => buildLfm2AutoGrammar([
        ToolDefinition(
          name: 'many',
          description: '',
          parameters: [for (var i = 0; i < 13; i++) ToolParam.string('p$i')],
        ),
      ], parallelToolCalls: true),
      throwsA(isA<LlamaUnsupportedException>()),
    );
  });
}
