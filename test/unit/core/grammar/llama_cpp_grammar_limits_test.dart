import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/core/grammar/llama_cpp_grammar_limits.dart';
import 'package:test/test.dart';

void main() {
  Matcher rejects(String reason) => throwsA(
    isA<LlamaUnsupportedException>().having(
      (error) => error.message,
      'message',
      contains(reason),
    ),
  );

  group('checkTemplateGrammarLimits', () {
    test('accepts grammars llama.cpp loads with every bound kept', () {
      for (final grammar in [
        'root ::= ("a" "b"{0,1998})?',
        'root ::= "a"{0,1999}',
        'root ::= ("a" b){0,999}\nb ::= "b"',
        'root ::= ( "a" # comment ( unbalanced\n  b{ 2 , 3 } )\r\nb ::= [x] | "y"',
        'root ::= "(" ( "a" | "b" )+ ")" | "\\"" [^"\\\\]* "\\""',
      ]) {
        expect(() => checkTemplateGrammarLimits(grammar), returnsNormally);
        expect(llamaCppRepetitionRejection(grammar), isNull, reason: grammar);
      }
    });

    test('rejects grammars over the repetition-symbol limit', () {
      for (final grammar in [
        'root ::= ("a" "b"{0,1999})?',
        'root ::= ("a" b){0,1000}\nb ::= "b"',
        'root ::= "a"{2001}',
        'root ::= # comment\n("a" "b"{0,1999})?',
        'root ::= ( ${[for (var i = 0; i < 2000; i++) 'r$i'].join(' | ')} )+',
      ]) {
        expect(llamaCppRepetitionRejection(grammar), isNotNull);
        expect(
          () => checkTemplateGrammarLimits(grammar),
          rejects('exceeds llama.cpp grammar limits (rule root repeats'),
        );
      }
    });

    test('rejects upper bounds llama.cpp would drop', () {
      for (final grammar in ['root ::= "a"{0,2001}', 'root ::= [a]{3,5000}']) {
        expect(llamaCppRepetitionRejection(grammar), isNull);
        expect(
          () => checkTemplateGrammarLimits(grammar),
          rejects('llama.cpp ignores upper bounds above 2000'),
        );
      }
    });

    test('rejects grammars longer than the length limit', () {
      String padded(int length) {
        const rule = 'root ::= "a"\n';
        return '$rule#${'x' * (length - rule.length - 1)}';
      }

      final atLimit = padded(maxTemplateGrammarLength);
      expect(atLimit.length, maxTemplateGrammarLength);
      expect(() => checkTemplateGrammarLimits(atLimit), returnsNormally);
      expect(
        () => checkTemplateGrammarLimits(padded(maxTemplateGrammarLength + 1)),
        rejects(
          'has ${maxTemplateGrammarLength + 1} characters; the limit is '
          '$maxTemplateGrammarLength',
        ),
      );
    });

    test('leaves syntax it does not model to llama.cpp', () {
      for (final grammar in [
        'root ::= "unterminated',
        'root = "a"',
        'root ::= "a"{x}',
      ]) {
        expect(llamaCppRepetitionRejection(grammar), isNull, reason: grammar);
        expect(() => checkTemplateGrammarLimits(grammar), returnsNormally);
      }
    });
  });
}
