@Tags(['local-only', 'e2e'])
@Timeout(Duration(minutes: 20))
/// Device qualification of native LiteRT-LM JSON Schema output.
///
/// Run through `run_local_e2e.dart --scenario chat-app-litert-json-schema`,
/// which passes the model path or URL and the backend as defines; serving a
/// URL is up to the caller.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:path_provider/path_provider.dart';

const _families = {
  'c5f39b4191926786c3e6668b62af4d6eb15248dfc7a5348252a9b406f33f2108':
      'qwen3-0.6b',
  '181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c':
      'gemma-4-e2b',
};
const _prompt =
    'Reply with exactly the word BANANA. Do not use JSON, quotes, punctuation, or explanation.';
const _params = GenerationParams(
  maxTokens: 64,
  temp: 0,
  topK: 1,
  topP: 1,
  penalty: 1,
  seed: 42,
);
const _messages = [
  LlamaChatMessage.fromText(role: LlamaChatRole.user, text: _prompt),
];
const _sentinel = {
  'type': 'object',
  'properties': {
    'verdict': {'type': 'string', 'const': 'CEDAR_174'},
  },
  'required': ['verdict'],
  'additionalProperties': false,
};
const _wide = {
  'type': 'object',
  'properties': {
    'code': {'type': 'string', 'pattern': r'^[A-Z]{3}-[0-9]{2}$'},
    'count': {'type': 'integer', 'minimum': 3, 'maximum': 7},
    'tags': {
      'type': 'array',
      'items': {r'$ref': r'#/$defs/tag'},
      'minItems': 1,
      'maxItems': 3,
    },
    'owner': {
      'anyOf': [
        {'type': 'null'},
        {
          'type': 'object',
          'properties': {
            'name': {'type': 'string', 'maxLength': 12},
          },
          'required': ['name'],
          'additionalProperties': false,
        },
      ],
    },
  },
  'required': ['code', 'count', 'tags', 'owner'],
  'additionalProperties': false,
  r'$defs': {
    'tag': {
      'enum': ['red', 'green', 'blue'],
    },
  },
};
const _longString = {
  'type': 'object',
  'properties': {
    'story': {'type': 'string', 'minLength': 400},
  },
  'required': ['story'],
  'additionalProperties': false,
};

Map<String, dynamic> _format(Map<String, dynamic> schema) => {
  'type': 'json_schema',
  'json_schema': {'schema': schema},
};

Future<String> _resolveModel() async {
  const path = String.fromEnvironment('LITERT_LM_MODEL');
  if (path.isNotEmpty) return path;
  const url = String.fromEnvironment('LITERT_LM_MODEL_URL');
  final directory = await getApplicationSupportDirectory();
  final target = File('${directory.path}/${Uri.parse(url).pathSegments.last}');
  if (!target.existsSync()) await Dio().download(url, target.path);
  return target.path;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const configured =
      String.fromEnvironment('LITERT_LM_MODEL') != '' ||
      String.fromEnvironment('LITERT_LM_MODEL_URL') != '';
  const backend = String.fromEnvironment(
    'LITERT_LM_BACKEND',
    defaultValue: 'cpu',
  );

  testWidgets('native JSON Schema enforcement, contract, thinking and cutoff', (
    tester,
  ) async {
    final model = await _resolveModel();
    final digest = (await sha256.bind(File(model).openRead()).first).toString();
    final family = _families[digest];
    expect(family, isNotNull, reason: 'Use a qualified model artifact.');
    final engine = LlamaEngine(LlamaBackend());
    final records = <Map<String, Object?>>[];
    Future<LlamaCompletion> run(
      String name, {
      Map<String, dynamic>? schema,
      bool thinking = false,
      GenerationParams params = _params,
    }) async {
      final completion = await engine
          .create(
            _messages,
            params: params,
            enableThinking: thinking,
            responseFormat: schema == null ? null : _format(schema),
          )
          .collect();
      records.add({
        'case': name,
        'text': completion.text,
        'thinking_chars': completion.thinking.length,
        'finish': completion.finishReason?.name,
      });
      return completion;
    }

    Map<String, dynamic> parse(LlamaCompletion reply, Map schema) =>
        LlamaStructuredOutput<Map<String, dynamic>>.jsonSchema(
          schema: Map<String, dynamic>.from(schema),
          decoder: (json) => json,
        ).parse(reply.text);

    try {
      await engine.setModel(
        LlamaModel(ModelSource.path(model)),
        params: ModelParams(
          device: backend == 'gpu' ? ComputeDevice.gpu : ComputeDevice.cpu,
          contextSize: 2048,
          numberOfThreads: backend == 'gpu' ? 0 : 2,
        ),
      );
      if (!(await engine.capabilities).supportsStructuredOutput) {
        // The engine loads lazily, so the capability probe hides why admission
        // failed; a strict request rethrows the admission error.
        await engine
            .create(
              _messages,
              params: _params,
              responseFormat: _format(_sentinel),
            )
            .drain<void>();
        fail('Native JSON Schema output is unsupported on this device.');
      }
      expect((await run('unconstrained')).text.trim(), isNot(startsWith('{')));
      final sentinel = await run('sentinel', schema: _sentinel);
      expect(jsonDecode(sentinel.text), {'verdict': 'CEDAR_174'});
      expect(sentinel.finishReason, LlamaFinishReason.stop);
      final wide = await run(
        'wide_contract',
        schema: _wide,
        params: _params.copyWith(maxTokens: 192),
      );
      expect(wide.finishReason, LlamaFinishReason.stop);
      parse(wide, _wide);
      await expectLater(
        engine
            .create(
              _messages,
              params: _params,
              enableThinking: false,
              responseFormat: _format(const {
                'type': 'object',
                'properties': {
                  'v': {'type': 'string', 'format': 'time'},
                },
              }),
            )
            .drain<void>(),
        throwsA(isA<LlamaUnsupportedException>()),
      );
      final thinking = run(
        'thinking',
        schema: _sentinel,
        thinking: true,
        params: _params.copyWith(maxTokens: 1024),
      );
      if (family == 'gemma-4-e2b') {
        final reply = await thinking;
        expect(jsonDecode(reply.text), {'verdict': 'CEDAR_174'});
        expect(reply.thinking, isNotEmpty);
      } else {
        await expectLater(thinking, throwsA(isA<LlamaUnsupportedException>()));
      }
      final cutoff = await run(
        'cut_inside_constrained_string',
        schema: _longString,
        params: _params.copyWith(maxTokens: 24),
      );
      expect(cutoff.finishReason, LlamaFinishReason.length);
      expect(
        () => parse(cutoff, _longString),
        throwsA(isA<LlamaInferenceException>()),
      );
    } finally {
      await engine.dispose();
      // ignore: avoid_print
      print(
        'LITERT_JSON_SCHEMA_RESULT ${jsonEncode({'model_sha256': digest, 'family': family, 'backend': '${Platform.operatingSystem}-$backend', 'cases': records})}',
      );
    }
  }, skip: !configured);
}
