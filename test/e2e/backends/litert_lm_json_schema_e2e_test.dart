@TestOn('vm')
@Tags(['local-only', 'e2e'])
@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:llamadart/llamadart.dart';
import 'package:test/test.dart';

import '../../support/suite_system_temp.dart';

const _modelSha =
    'c5f39b4191926786c3e6668b62af4d6eb15248dfc7a5348252a9b406f33f2108';
const _prompt =
    'Reply with exactly the word BANANA. Do not use JSON, quotes, punctuation, or explanation.';
const _params = GenerationParams(
  maxTokens: 64,
  temp: 0,
  topK: 1,
  topP: 1,
  penalty: 1,
  seed: 42,
  streamBatchTokenThreshold: 1,
  streamBatchByteThreshold: 1,
);

Map<String, dynamic> _schema(String? sentinel) => {
  'type': 'object',
  'properties': {
    'verdict': {'type': 'string', 'const': ?sentinel},
  },
  'required': ['verdict'],
  'additionalProperties': false,
};

Map<String, dynamic> _format(String? sentinel) => {
  'type': 'json_schema',
  'json_schema': {'schema': _schema(sentinel)},
};

void main() {
  final temp = useSuiteSystemTemp();
  final model = Platform.environment['LITERT_LM_MODEL'];
  test(
    'public native CPU schema enforcement, lifecycle and history',
    () async {
      expect(Platform.isMacOS, isTrue);
      final file = File(model!);
      final digest = (await sha256.bind(file.openRead()).first).toString();
      expect(
        digest,
        _modelSha,
        reason: 'Use the corrected, qualified Qwen3 artifact.',
      );
      final engine = LlamaEngine(LlamaBackend());
      final records = <Map<String, dynamic>>[];
      const messages = [
        LlamaChatMessage.fromText(role: LlamaChatRole.user, text: _prompt),
      ];
      Future<LlamaCompletion> run(
        String name, {
        String? sentinel,
        bool strict = true,
        List<LlamaChatMessage> history = messages,
        GenerationParams params = _params,
        Map<String, dynamic>? formatOverride,
      }) async {
        final completion = await engine
            .create(
              history,
              params: params,
              enableThinking: false,
              responseFormat: strict
                  ? (formatOverride ?? _format(sentinel))
                  : null,
            )
            .collect()
            .timeout(const Duration(seconds: 30));
        expect(completion.usage, isNull);
        records.add({
          'case': name,
          'text': completion.text,
          'finish': completion.finishReason?.name,
          'usage': completion.usage?.toJson(),
        });
        return completion;
      }

      try {
        await engine.loadModel(
          model,
          modelParams: ModelParams(
            device: ComputeDevice.cpu,
            contextSize: 1024,
            numberOfThreads: 4,
            liteRtLmCacheDir: '${temp().path}/cache',
          ),
        );
        final capabilities = await engine.capabilities;
        expect(capabilities.supportsStructuredOutput, isTrue);
        expect(capabilities.supportsGrammar, isFalse);
        expect(capabilities.supportsLazyGrammar, isFalse);
        final control = await run('unconstrained', strict: false);
        expect(
          control.text.trim(),
          'BANANA',
          reason: 'The control must violate the target schema.',
        );
        expect(
          jsonDecode(
            (await run(
              'json_object',
              formatOverride: const {'type': 'json_object'},
            )).text,
          ),
          isA<Map>(),
        );
        final enumReply = await run(
          'enum',
          formatOverride: const {
            'type': 'json_schema',
            'json_schema': {
              'schema': {
                'type': 'object',
                'properties': {
                  'verdict': {
                    'type': 'string',
                    'enum': ['CEDAR_174', 'ORCHID_174'],
                  },
                },
                'required': ['verdict'],
                'additionalProperties': false,
              },
            },
          },
        );
        expect([
          'CEDAR_174',
          'ORCHID_174',
        ], contains(jsonDecode(enumReply.text)['verdict']));
        final scalarReply = await run(
          'scalar_types',
          formatOverride: const {
            'type': 'json_schema',
            'json_schema': {
              'schema': {
                'type': 'object',
                'properties': {
                  'count': {'type': 'integer', 'const': 3},
                  'weight': {'type': 'number', 'const': 1.5},
                  'active': {'type': 'boolean', 'const': true},
                  'empty': {'type': 'null', 'const': null},
                },
                'required': ['count', 'weight', 'active', 'empty'],
                'additionalProperties': false,
              },
            },
          },
        );
        expect(jsonDecode(scalarReply.text), {
          'count': 3,
          'weight': 1.5,
          'active': true,
          'empty': null,
        });
        for (final value in ['CEDAR_174', 'ORCHID_174']) {
          final reply = await run('schema_$value', sentinel: value);
          expect(jsonDecode(reply.text), {'verdict': value});
          expect(reply.finishReason, LlamaFinishReason.stop);
        }
        expect(
          (await run('ordinary_after_schemas', strict: false)).text.trim(),
          'BANANA',
        );
        await expectLater(
          engine
              .create(
                messages,
                params: _params,
                enableThinking: false,
                responseFormat: const {
                  'type': 'json_schema',
                  'json_schema': {
                    'schema': {'type': 'array'},
                  },
                },
              )
              .drain<void>(),
          throwsA(isA<LlamaUnsupportedException>()),
        );
        expect(
          jsonDecode(
            (await run('after_invalid_schema', sentinel: 'CEDAR_174')).text,
          ),
          {'verdict': 'CEDAR_174'},
        );
        final system = await run(
          'system',
          history: const [
            LlamaChatMessage.fromText(
              role: LlamaChatRole.system,
              text:
                  'The secret word is ORCHID. When asked for the secret, put it in verdict.',
            ),
            LlamaChatMessage.fromText(
              role: LlamaChatRole.user,
              text: 'What is the secret word?',
            ),
          ],
        );
        expect(
          (jsonDecode(system.text)['verdict'] as String).toUpperCase(),
          contains('ORCHID'),
        );
        final history = await run(
          'history',
          history: const [
            LlamaChatMessage.fromText(
              role: LlamaChatRole.user,
              text: 'Remember my secret word: CEDAR.',
            ),
            LlamaChatMessage.fromText(
              role: LlamaChatRole.assistant,
              text: 'I remember your secret word.',
            ),
            LlamaChatMessage.fromText(
              role: LlamaChatRole.user,
              text: 'What secret word did I give you? Put it in verdict.',
            ),
          ],
        );
        expect(
          (jsonDecode(history.text)['verdict'] as String).toUpperCase(),
          contains('CEDAR'),
        );
        final session = ChatSession(engine, maxContextTokens: 0);
        final output = LlamaStructuredOutput<Map<String, dynamic>>.jsonSchema(
          schema: _schema('CEDAR_174'),
          decoder: (json) => json,
        );
        final cancelled = session.createStructuredJson(
          [LlamaTextContent(_prompt)],
          output: output,
          params: _params,
          enableThinking: false,
        );
        scheduleMicrotask(engine.cancelGeneration);
        await expectLater(cancelled, throwsA(isA<LlamaStateException>()));
        expect(session.history, isEmpty);
        records.add({
          'case': 'before_content_cancel',
          'history_length': session.history.length,
        });
        var stopped = false;
        final partial = await engine
            .create(
              messages,
              params: _params.copyWith(maxTokens: 256),
              enableThinking: false,
              responseFormat: _format(List.filled(600, 'Z').join()),
            )
            .map((chunk) {
              if (!stopped && chunk.text.isNotEmpty) {
                stopped = true;
                engine.cancelGeneration();
              }
              return chunk;
            })
            .collect()
            .timeout(const Duration(seconds: 30));
        expect(stopped, isTrue);
        expect(partial.text, isNotEmpty);
        expect(partial.text, isNot(contains(List.filled(600, 'Z').join())));
        records.add({
          'case': 'after_content_cancel',
          'text': partial.text,
          'finish': partial.finishReason?.name,
        });
        expect(
          jsonDecode(
            (await run('after_cancel_reuse', sentinel: 'ORCHID_174')).text,
          ),
          {'verdict': 'ORCHID_174'},
        );
        final cutoff = await run(
          'real_short_budget',
          sentinel: 'CEDAR_174',
          params: _params.copyWith(maxTokens: 1),
        );
        expect(cutoff.finishReason, LlamaFinishReason.length);
        expect(
          () => output.parse(cutoff.text),
          throwsA(isA<LlamaInferenceException>()),
        );
      } finally {
        await engine.dispose();
        print(
          jsonEncode({
            'model_sha256': digest,
            'backend': 'macos-arm64-cpu',
            'cases': records,
          }),
        );
      }
    },
    skip: model == null
        ? 'Set LITERT_LM_MODEL to the existing corrected Qwen3 bundle.'
        : false,
  );
}
