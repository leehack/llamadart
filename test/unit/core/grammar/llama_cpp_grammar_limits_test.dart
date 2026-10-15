import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/core/grammar/llama_cpp_grammar_limits.dart';
import 'package:test/test.dart';

void main() {
  List<String> captureWarnings() {
    final logger = LlamaLogger.instance;
    final level = logger.level;
    final logs = <String>[];
    logger
      ..setLevel(LlamaLogLevel.warn)
      ..setHandler((record) => logs.add(record.message));
    addTearDown(() {
      logger
        ..setHandler(null)
        ..setLevel(level);
    });
    return logs;
  }

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

    test('warns about upper bounds llama.cpp drops', () {
      final logs = captureWarnings();
      for (final grammar in ['root ::= "a"{0,2001}', 'root ::= [a]{3,5000}']) {
        expect(llamaCppRepetitionRejection(grammar), isNull);
        expect(() => checkTemplateGrammarLimits(grammar), returnsNormally);
      }
      expect(logs, hasLength(2));
      expect(logs.first, contains('bounds a repetition in rule root at 2001'));
      expect(logs.last, contains('at 5000'));
      checkTemplateGrammarLimits('root ::= "a"{0,1999}');
      expect(logs, hasLength(2));
    });

    test('sets no length limit of its own', () {
      final grammar = 'root ::= "a"\n#${'x' * (12 * 1024 * 1024)}';
      expect(() => checkTemplateGrammarLimits(grammar), returnsNormally);
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
