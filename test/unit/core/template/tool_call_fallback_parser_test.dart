import 'dart:convert';

import 'package:llamadart/src/core/template/tool_call_fallback_parser.dart';
import 'package:test/test.dart';

void main() {
  group('tool_call_fallback_parser', () {
    test('parses JSON array payload', () {
      final parsed = parseToolCallsFromLooseText(
        '[{"name":"get_weather","arguments":{"city":"Seoul"}}]',
      );

      expect(parsed.toolCalls, hasLength(1));
      expect(parsed.toolCalls.first.function?.name, equals('get_weather'));
      expect(
        jsonDecode(parsed.toolCalls.first.function!.arguments!),
        containsPair('city', 'Seoul'),
      );
      expect(parsed.content, isEmpty);
    });

    test('parses loose JSON object with unquoted name', () {
      final parsed = parseToolCallsFromLooseText(
        '{"name": get_weather, "arguments": {"city": "Seoul"}}',
      );

      expect(parsed.toolCalls, hasLength(1));
      expect(parsed.toolCalls.first.function?.name, equals('get_weather'));
      expect(
        jsonDecode(parsed.toolCalls.first.function!.arguments!),
        containsPair('city', 'Seoul'),
      );
    });

    test('parses function syntax and preserves location argument key', () {
      final parsed = parseToolCallsFromLooseText(
        'weather_tool.get_weather_and_local_time(location="Seoul")',
      );

      expect(parsed.toolCalls, hasLength(1));
      expect(
        parsed.toolCalls.first.function?.name,
        equals('weather_tool.get_weather_and_local_time'),
      );
      expect(
        jsonDecode(parsed.toolCalls.first.function!.arguments!),
        containsPair('location', 'Seoul'),
      );
    });

    test('keeps commas inside quoted function argument values', () {
      final parsed = parseToolCallsFromLooseText(
        "send_note(to='Alice', body='hello, world')",
      );

      expect(parsed.toolCalls, hasLength(1));
      final args = jsonDecode(parsed.toolCalls.first.function!.arguments!);
      expect(args, containsPair('to', 'Alice'));
      expect(args, containsPair('body', 'hello, world'));
    });

    test('keeps a lone quote as the argument value', () {
      for (final quote in ["'", '"']) {
        final parsed = parseToolCallsFromLooseText('f(x=$quote)');
        expect(
          parsed.toolCalls.single.function?.arguments,
          jsonEncode({'x': quote}),
        );
      }
    });

    test('does not coerce bare weather-like alias', () {
      final parsed = parseToolCallsFromLooseText('weatherlookup');

      expect(parsed.toolCalls, isEmpty);
      expect(parsed.content, equals('weatherlookup'));
    });

    test('preserves explicit location key from json arguments', () {
      final parsed = parseToolCallsFromLooseText(
        '{"name":"weather_lookup","arguments":{"location":"Seoul"}}',
      );

      expect(parsed.toolCalls, hasLength(1));
      expect(parsed.toolCalls.first.function?.name, equals('weather_lookup'));
      expect(
        jsonDecode(parsed.toolCalls.first.function!.arguments!),
        containsPair('location', 'Seoul'),
      );
    });

    test('parses semicolon-separated JSON tool objects', () {
      final parsed = parseToolCallsFromLooseText(
        '{"type":"function","function":"get_weather","parameters":{"city":"Seoul"}}; '
        '{"type":"function","function":"get_time","parameters":{"city":"Seoul"}}',
      );

      expect(parsed.toolCalls, hasLength(2));
      expect(parsed.toolCalls.first.function?.name, equals('get_weather'));
      expect(parsed.toolCalls.last.function?.name, equals('get_time'));
    });

    test('parses nested function.parameters object', () {
      final parsed = parseToolCallsFromLooseText(
        '{"type":"function","function":{"name":"get_weather","parameters":{"city":"Seoul"}}}',
      );

      expect(parsed.toolCalls, hasLength(1));
      expect(parsed.toolCalls.first.function?.name, equals('get_weather'));
      expect(
        jsonDecode(parsed.toolCalls.first.function!.arguments!),
        containsPair('city', 'Seoul'),
      );
    });

    test('parses first JSON object when trailing junk exists', () {
      final parsed = parseToolCallsFromLooseText(
        '{"name":"get_time","arguments":{"city":"Seoul"}}\n\n  }',
      );

      expect(parsed.toolCalls, hasLength(1));
      expect(parsed.toolCalls.first.function?.name, equals('get_time'));
      expect(
        jsonDecode(parsed.toolCalls.first.function!.arguments!),
        containsPair('city', 'Seoul'),
      );
    });

    test('decodeToolArgumentsObject extracts first object from mixed text', () {
      final decoded = decodeToolArgumentsObject(
        'before {"city":"Seoul","unit":"celsius"} after',
      );

      expect(decoded, containsPair('city', 'Seoul'));
      expect(decoded, containsPair('unit', 'celsius'));
    });

    test('normalizeFallbackToolArguments unwraps argument containers', () {
      final normalized = normalizeFallbackToolArguments(<String, dynamic>{
        'arguments': <String, dynamic>{'city': 'Seoul'},
      });

      expect(normalized, equals(<String, dynamic>{'city': 'Seoul'}));
    });

    test('parses top-level tool_call object with explicit id', () {
      final parsed = parseToolCallsFromLooseText(
        '{"id":"call_7","tool_call":{"name":"get_weather","arguments":{"city":"Seoul"}}}',
      );

      expect(parsed.toolCalls, hasLength(1));
      expect(parsed.toolCalls.single.id, 'call_7');
      expect(parsed.toolCalls.single.function?.name, 'get_weather');
      expect(
        jsonDecode(parsed.toolCalls.single.function!.arguments!),
        containsPair('city', 'Seoul'),
      );
    });

    test('filters loose JSON calls by allowedToolNames when provided', () {
      const undeclared = '{"name":"other","arguments":{"city":"Seoul"}}';
      const schema =
          '{"type":"object","properties":{"city":{"type":"string"}}}';
      const declared = '{"name":"weather","arguments":{"city":"Seoul"}}';

      final rejectedName = parseToolCallsFromLooseText(
        'Prose $undeclared',
        preserveJsonProse: true,
        allowedToolNames: const {'weather'},
      );
      expect(rejectedName.toolCalls, isEmpty);
      expect(rejectedName.content, 'Prose $undeclared');

      final rejectedSchema = parseToolCallsFromLooseText(
        'Schema: $schema',
        preserveJsonProse: true,
        allowedToolNames: const {'weather'},
      );
      expect(rejectedSchema.toolCalls, isEmpty);
      expect(rejectedSchema.content, 'Schema: $schema');

      final accepted = parseToolCallsFromLooseText(
        'Prose $declared',
        preserveJsonProse: true,
        allowedToolNames: const {'weather'},
      );
      expect(accepted.toolCalls, hasLength(1));
      expect(accepted.toolCalls.single.function?.name, 'weather');
      expect(accepted.content, 'Prose ');
    });

    test('never parses JSON inside Markdown fences or inline backticks', () {
      const jsonCall = '{"name":"weather","arguments":{"city":"Seoul"}}';
      for (final sample in [
        '```json\n$jsonCall\n```',
        '```\n$jsonCall\n```',
        '~~~json\n$jsonCall\n~~~',
        'Run `$jsonCall` now.',
        'Run ``$jsonCall`` now.',
      ]) {
        final direct = parseToolCallsFromLooseText(
          sample,
          allowedToolNames: const {'weather'},
        );
        expect(direct.toolCalls, isEmpty, reason: sample);
        expect(direct.content, sample, reason: sample);

        final prose = parseToolCallsFromLooseText(
          sample,
          preserveJsonProse: true,
          allowedToolNames: const {'weather'},
        );
        expect(prose.toolCalls, isEmpty, reason: sample);
        expect(prose.content, sample, reason: sample);
      }
    });

    test('preserves trailing text after a loose JSON tool call', () {
      final parsed = parseToolCallsFromLooseText(
        'Before. {"name":"weather","arguments":{"city":"Seoul"}} After.',
        preserveJsonProse: true,
        allowedToolNames: const {'weather'},
      );

      expect(parsed.toolCalls, hasLength(1));
      expect(parsed.toolCalls.single.function?.name, 'weather');
      expect(parsed.content, 'Before. After.');
    });

    test('releases partial JSON once name is known not to match', () {
      for (final partial in [
        'Here: {"name":"other"',
        'Here: {"type":"object"',
        'Here: {"name": nope,',
        'Try {"type":"function","function":{"name":"rm"',
      ]) {
        final parsed = parseToolCallsFromLooseText(
          partial,
          preserveJsonProse: true,
          isPartial: true,
          allowedToolNames: const {'weather'},
        );
        expect(parsed.toolCalls, isEmpty, reason: partial);
        expect(parsed.content, partial, reason: partial);
      }
    });

    test('rejects explicit non-tool type even with a declared tool name', () {
      const sample =
          '{"type":"object","name":"weather","arguments":{"city":"Seoul"}}';
      final parsed = parseToolCallsFromLooseText(
        sample,
        preserveJsonProse: true,
        allowedToolNames: const {'weather'},
      );

      expect(parsed.toolCalls, isEmpty);
      expect(parsed.content, sample);
    });

    test('unclosed rejected outer object hides nested declared call', () {
      const sample =
          'Here {"name":"other","x":{"name":"weather","arguments":{}}';
      final parsed = parseToolCallsFromLooseText(
        sample,
        preserveJsonProse: true,
        allowedToolNames: const {'weather'},
      );

      expect(parsed.toolCalls, isEmpty);
      expect(parsed.content, sample);
    });

    test('strips wrapper residue and normalizes junction whitespace', () {
      const call = '{"name":"weather","arguments":{"city":"Seoul"}}';
      for (final (input, expected) in [
        ('$call</tool_call> Done', ' Done'),
        ('Ok $call</tool_call> Done', 'Ok Done'),
        ('Ok $call </tool_call>\nDone', 'Ok \nDone'),
        ('Ok </tool_call> $call', 'Ok </tool_call> '),
        ('Ok $call foo </tool_call>', 'Ok foo </tool_call>'),
        ('$call</tool_', ''),
        ('Ok $call</tool_', 'Ok '),
        ('Ok $call\n</tool_', 'Ok '),
        ('Ok $call</tool_ Done', 'Ok </tool_ Done'),
        ('Ok $call;', 'Ok '),
        ('Ok $call; then done', 'Ok then done'),
        ('$call; then done', 'then done'),
        ('Ok $call;\nDone', 'Ok \nDone'),
        ('Ok $call; $call; bye', 'Ok bye'),
        ('Ok $call\n; then done', 'Ok \n; then done'),
        ('Ok $call\r; then done', 'Ok \r; then done'),
        ('Ok $call;</tool_call> Done', 'Ok Done'),
        ('$call;</tool_call> Done', ' Done'),
        ('Ok $call; </tool_call>\nDone', 'Ok \nDone'),
        ('Ok <tool_call>$call; Done', 'Ok Done'),
        ('Ok <tool_call>$call;</tool_call> Done', 'Ok Done'),
        ('Ok <tool_call>$call</tool_call>; Done', 'Ok ; Done'),
        ('Ok $call  ', 'Ok '),
        ('Ok$call  ', 'Ok '),
        ('  $call  Done', ' Done'),
        ('Ok${call}Done', 'OkDone'),
        ('Ok\n$call\nDone', 'Ok\n\nDone'),
        ('Ok$call Done', 'Ok Done'),
        ('Ok ${call}Done', 'Ok Done'),
        ('Ok\t$call\tDone', 'Ok Done'),
      ]) {
        final parsed = parseToolCallsFromLooseText(
          input,
          preserveJsonProse: true,
          allowedToolNames: const {'weather'},
        );
        expect(parsed.toolCalls, isNotEmpty, reason: input);
        expect(parsed.content, expected, reason: input);
      }

      final wrappedParallel = parseToolCallsFromLooseText(
        'Ok <tool_call>$call; $call Done',
        preserveJsonProse: true,
        allowedToolNames: const {'weather'},
      );
      expect(wrappedParallel.toolCalls, hasLength(2));
      expect(wrappedParallel.content, 'Ok Done');
    });

    test('holds partial closing tag prefix after a bare loose call', () {
      const partial = '{"name":"weather","arguments":{}}</tool_';
      final parsed = parseToolCallsFromLooseText(
        partial,
        preserveJsonProse: true,
        isPartial: true,
        allowedToolNames: const {'weather'},
      );

      expect(parsed.toolCalls, hasLength(1));
      expect(parsed.content, isNot(contains('</tool_')));
    });

    test('gates function-call syntax by allowedToolNames', () {
      for (final undeclared in [
        'rm(path="/")',
        'os.system(cmd="ls")',
        'weather_extra(city="Seoul")',
      ]) {
        for (final preserve in [false, true]) {
          final parsed = parseToolCallsFromLooseText(
            undeclared,
            preserveJsonProse: preserve,
            allowedToolNames: const {'weather'},
          );
          expect(parsed.toolCalls, isEmpty, reason: '$undeclared/$preserve');
          expect(parsed.content, undeclared, reason: '$undeclared/$preserve');
        }
      }

      for (final preserve in [false, true]) {
        final noTools = parseToolCallsFromLooseText(
          'weather(city="Seoul")',
          preserveJsonProse: preserve,
          allowedToolNames: const <String>{},
        );
        expect(noTools.toolCalls, isEmpty, reason: 'noTools/$preserve');
        expect(
          noTools.content,
          'weather(city="Seoul")',
          reason: 'noTools/$preserve',
        );
      }

      final declared = parseToolCallsFromLooseText(
        '  weather(city="Seoul")  ',
        preserveJsonProse: true,
        allowedToolNames: const {'weather'},
      );
      expect(declared.toolCalls, hasLength(1));
      expect(declared.toolCalls.single.function?.name, 'weather');
      expect(jsonDecode(declared.toolCalls.single.function!.arguments!), {
        'city': 'Seoul',
      });
      expect(declared.content, isEmpty);
    });

    test('releases partial function-call syntax once name cannot match', () {
      for (final partial in ['r', 'rm']) {
        final parsed = parseToolCallsFromLooseText(
          partial,
          preserveJsonProse: true,
          isPartial: true,
          allowedToolNames: const {'weather'},
        );
        expect(parsed.toolCalls, isEmpty, reason: partial);
        expect(parsed.content, partial, reason: partial);
      }

      for (final partial in [
        'rm',
        'rm(',
        'rm(path="/"',
        'os.system(cmd="ls"',
        'read_other',
        'read(',
        'weather_extra',
        'weather is sunny',
        '  rm(pa',
      ]) {
        final parsed = parseToolCallsFromLooseText(
          partial,
          preserveJsonProse: true,
          isPartial: true,
          allowedToolNames: const {'weather', 'read_file'},
        );
        expect(parsed.toolCalls, isEmpty, reason: partial);
        expect(parsed.content, partial, reason: partial);
      }

      final noToolsPartial = parseToolCallsFromLooseText(
        'weather(city="Se',
        preserveJsonProse: true,
        isPartial: true,
        allowedToolNames: const <String>{},
      );
      expect(noToolsPartial.toolCalls, isEmpty);
      expect(noToolsPartial.content, 'weather(city="Se');

      for (final held in [
        'w',
        'wea',
        'weather',
        'weather ',
        'weather(',
        'weather(city="Seoul"',
        '  r',
        '  read',
        '  read_file(',
      ]) {
        final parsed = parseToolCallsFromLooseText(
          held,
          preserveJsonProse: true,
          isPartial: true,
          allowedToolNames: const {'weather', 'read_file'},
        );
        expect(parsed.toolCalls, isEmpty, reason: held);
        expect(parsed.content, isEmpty, reason: held);
      }
    });
  });
}
