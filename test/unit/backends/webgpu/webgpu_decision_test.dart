@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:llamadart/src/backends/backend.dart';
import 'package:llamadart/src/backends/webgpu/webgpu_decision.dart';
import 'package:llamadart/src/core/decision/decision_question.dart';
import 'package:llamadart/src/core/exceptions.dart';
import 'package:test/test.dart';
import 'package:web/web.dart'
    show Blob, BlobPropertyBag, HTMLBaseElement, URL, document;

import '../../../support/fake_webgpu_decision_bridge.dart';

void main() {
  late FakeDecisionBridge fake;
  late WebGpuDecisionHeads heads;

  setUp(() {
    fake = FakeDecisionBridge();
    heads = WebGpuDecisionHeads();
  });

  BackendDecisionSequence sequence(
    List<int> tokens,
    List<int> markers, [
    DecisionQuestionType questionType = DecisionQuestionType.choice,
  ]) => BackendDecisionSequence(
    tokens: Int32List.fromList(tokens),
    markers: Int32List.fromList(markers),
    questionType: questionType,
  );

  Matcher throwsTyped<T extends LlamaException>(Object? message) =>
      throwsA(isA<T>().having((error) => error.message, 'message', message));

  String blobUrl(String text) => URL.createObjectURL(
    Blob(<JSAny>[text.toJS].toJS, BlobPropertyBag(type: 'application/json')),
  );

  String pageUrl(String path) =>
      Uri.parse(document.baseURI).resolve(path).toString();

  void useBaseHref(String href) {
    final base = document.createElement('base') as HTMLBaseElement..href = href;
    document.head!.append(base);
    addTearDown(() => base.remove());
  }

  group('capabilities', () {
    test('reports supported for decision API version 1', () async {
      final capabilities = await heads.capabilities(fake.bridge);

      expect(capabilities.isSupported, isTrue);
      expect(capabilities.unsupportedReason, isNull);
      expect(fake.calls, ['capabilities']);
    });

    test('names the required assets for bridges without the API', () async {
      final old = FakeDecisionBridge(withDecisionApi: false);
      final partial = FakeDecisionBridge();
      partial.object.delete('freeDecisionHead'.toJS);

      for (final bridge in [old, partial]) {
        final capabilities = await heads.capabilities(bridge.bridge);

        expect(capabilities.isSupported, isFalse);
        expect(
          capabilities.unsupportedReason,
          'Web decision models need llama-web-bridge assets v0.1.47+ with '
          'the decision API (apiVersion 1); the loaded bridge does not expose '
          'it.',
        );
      }
      expect(partial.calls, isEmpty);
    });

    test('reports another decision API version as unsupported', () async {
      fake.capabilitiesApiVersion = 2;
      final skewed = await heads.capabilities(fake.bridge);
      fake.capabilitiesResult = JSObject()
        ..setProperty('supported'.toJS, true.toJS);
      final unversioned = await heads.capabilities(fake.bridge);

      expect(skewed.isSupported, isFalse);
      expect(
        skewed.unsupportedReason,
        'The Web bridge implements decision API version 2; llamadart needs '
        'llama-web-bridge assets v0.1.47+ with the decision API (apiVersion 1).',
      );
      expect(unversioned.isSupported, isFalse);
      expect(unversioned.unsupportedReason, contains('version unknown'));
    });

    test('passes the bridge reason through', () async {
      fake
        ..supported = false
        ..reason = 'Decision heads need a ModernBERT encoder GGUF.';
      final withReason = await heads.capabilities(fake.bridge);
      fake.reason = '';
      final withoutReason = await heads.capabilities(fake.bridge);

      expect(withReason.isSupported, isFalse);
      expect(
        withReason.unsupportedReason,
        'Decision heads need a ModernBERT encoder GGUF.',
      );
      expect(
        withoutReason.unsupportedReason,
        'The loaded Web model does not support decision heads.',
      );
    });

    test('throws LlamaStateException for state rejections', () async {
      for (final message in [
        'Bridge has been disposed.',
        'Decision capability probe was cancelled.',
        'No model loaded. Call loadModelFromUrl first.',
      ]) {
        fake.capabilitiesError = message;

        await expectLater(
          heads.capabilities(fake.bridge),
          throwsTyped<LlamaStateException>(message),
          reason: message,
        );
        await expectLater(
          heads.load(fake.bridge, 'laya-head.safetensors'),
          throwsTyped<LlamaStateException>(message),
          reason: message,
        );
      }
      expect(fake.calls.where((call) => call.startsWith('load')), isEmpty);
    });

    test('reports invalid responses and failed probes', () async {
      fake.capabilitiesResult = 'yes'.toJS;
      final invalid = await heads.capabilities(fake.bridge);
      fake
        ..capabilitiesResult = null
        ..capabilitiesError = 'WebGPU core is not initialized';
      final failed = await heads.capabilities(fake.bridge);

      expect(invalid.isSupported, isFalse);
      expect(
        invalid.unsupportedReason,
        'The Web decision capability response is invalid.',
      );
      expect(failed.isSupported, isFalse);
      expect(
        failed.unsupportedReason,
        'The Web decision capability probe failed: WebGPU core is not '
        'initialized',
      );
    });
  });

  group('load', () {
    test('returns the head under a backend handle', () async {
      final head = await heads.load(fake.bridge, 'laya-head.safetensors');

      expect(head.handle, 1);
      expect(head.hiddenSize, 4);
      expect(head.clsToken, 1);
      expect(head.sepToken, 2);
      expect(head.maskToken, 3);
      expect(head.maskText, '[MASK]');
      expect(head.configJson, '{"max_len": 32, "head_max_len": 16}');
      expect(head.deviceName, 'WebGPU');
      expect(fake.calls, [
        'capabilities',
        'load ${pageUrl('laya-head.safetensors')}',
      ]);
      expect(fake.loadedConfigs, [null]);
      expect(fake.liveHandles, {7});
    });

    test('fetches configPath and passes its text to the bridge', () async {
      const config = '{"max_len": 64, "head_max_len": 24}';
      final url = blobUrl(config);
      addTearDown(() => URL.revokeObjectURL(url));

      final head = await heads.load(
        fake.bridge,
        'model.safetensors',
        configUrl: url,
      );

      expect(fake.loadedConfigs, [config]);
      expect(head.configJson, config);
    });

    test('rejects unsupported models before loading', () async {
      fake
        ..supported = false
        ..reason = 'The loaded model reports architecture "llama".';

      await expectLater(
        heads.load(fake.bridge, 'laya-head.safetensors'),
        throwsTyped<LlamaUnsupportedException>(
          'The loaded model reports architecture "llama".',
        ),
      );
      await expectLater(
        heads.load(
          FakeDecisionBridge(withDecisionApi: false).bridge,
          'laya-head.safetensors',
        ),
        throwsTyped<LlamaUnsupportedException>(
          contains('decision API (apiVersion 1)'),
        ),
      );
      expect(fake.calls, ['capabilities']);
    });

    test('fails with LlamaModelException for unreadable configs', () async {
      final revoked = blobUrl('{}');
      URL.revokeObjectURL(revoked);

      await expectLater(
        heads.load(
          fake.bridge,
          'laya-head.safetensors',
          configUrl: 'missing_decision_config.json?token=secret#frag',
        ),
        throwsA(
          isA<LlamaModelException>()
              .having(
                (error) => error.message,
                'message',
                'Cannot read the decision head config at '
                    '${pageUrl('missing_decision_config.json')}.',
              )
              .having(
                (error) => '${error.details}',
                'details',
                startsWith('HTTP 404'),
              ),
        ),
      );
      await expectLater(
        heads.load(fake.bridge, 'laya-head.safetensors', configUrl: revoked),
        throwsA(
          isA<LlamaModelException>().having(
            (error) => error.message,
            'message',
            startsWith('Cannot read the decision head config at blob:'),
          ),
        ),
      );
      expect(fake.calls.where((call) => call.startsWith('load')), isEmpty);
    });

    test('fails with LlamaModelException when a config body fails', () async {
      final fetch = globalContext.getProperty<JSAny?>('fetch'.toJS);
      addTearDown(() => globalContext.setProperty('fetch'.toJS, fetch));
      globalContext.setProperty(
        'fetch'.toJS,
        ((JSAny? url) => Future<JSAny?>.value(
          JSObject()
            ..setProperty('ok'.toJS, true.toJS)
            ..setProperty('status'.toJS, 200.toJS)
            ..setProperty(
              'text'.toJS,
              (() => rejectWithMessage('network error')).toJS,
            ),
        ).toJS).toJS,
      );

      await expectLater(
        heads.load(
          fake.bridge,
          'laya-head.safetensors',
          configUrl: 'https://example.com/rl_agent_config.json',
        ),
        throwsA(
          isA<LlamaModelException>()
              .having(
                (error) => error.message,
                'message',
                'Cannot read the decision head config at '
                    'https://example.com/rl_agent_config.json.',
              )
              .having((error) => error.details, 'details', 'network error'),
        ),
      );
      expect(fake.calls.where((call) => call.startsWith('load')), isEmpty);
    });

    test('resolves head and config URLs against the document base', () async {
      useBaseHref(pageUrl('decision-base/'));

      await heads.load(fake.bridge, 'models/laya-head.safetensors');
      await expectLater(
        heads.load(
          fake.bridge,
          'models/model.safetensors',
          configUrl: 'models/rl_agent_config.json',
        ),
        throwsTyped<LlamaModelException>(
          'Cannot read the decision head config at '
          '${pageUrl('models/rl_agent_config.json')}.',
        ),
      );
      final blob = blobUrl('{}');
      addTearDown(() => URL.revokeObjectURL(blob));
      await heads.load(fake.bridge, blob);

      expect(document.baseURI, endsWith('/decision-base/'));
      expect(fake.calls.where((call) => call.startsWith('load')), [
        'load ${pageUrl('models/laya-head.safetensors')}',
        'load $blob',
      ]);
    });

    test('keeps credentials and queries out of load errors', () async {
      const secretConfig =
          'https://alice:s3cret@example.com/rl_agent_config.json?sig=xyz#frag';
      const secretHead =
          'https://alice:s3cret@example.com/laya-head.safetensors?sig=xyz';
      Matcher redacted(String message) => throwsA(
        isA<LlamaModelException>()
            .having((error) => error.message, 'message', message)
            .having(
              (error) => '$error',
              'toString',
              allOf(
                isNot(contains('s3cret')),
                isNot(contains('alice')),
                isNot(contains('hunter2')),
                isNot(contains('bob')),
                isNot(contains('sig=')),
                isNot(contains('token=')),
                isNot(contains('frag')),
              ),
            ),
      );

      await expectLater(
        heads.load(
          fake.bridge,
          'laya-head.safetensors',
          configUrl: secretConfig,
        ),
        redacted(
          'Cannot read the decision head config at '
          'https://example.com/rl_agent_config.json.',
        ),
      );
      fake.loadError =
          "Failed to execute 'fetch' on 'Window': Request cannot be "
          'constructed from a URL that includes credentials: $secretHead';
      await expectLater(
        heads.load(fake.bridge, secretHead),
        redacted(
          "Failed to execute 'fetch' on 'Window': Request cannot be "
          'constructed from a URL that includes credentials: '
          'https://example.com/laya-head.safetensors',
        ),
      );
      fake.loadError =
          'Failed to fetch decision head from '
          'https://bob:hunter2@cdn.example.com/head?token=abc (timeout)';
      await expectLater(
        heads.load(fake.bridge, 'laya-head.safetensors'),
        redacted(
          'Failed to fetch decision head from https://cdn.example.com/head '
          '(timeout)',
        ),
      );
      fake.loadError =
          "Failed to execute 'fetch' on 'Window': Failed to parse URL from "
          'https://bob:hunter2@[cdn/head?token=abc';
      await expectLater(
        heads.load(fake.bridge, 'laya-head.safetensors'),
        redacted(
          "Failed to execute 'fetch' on 'Window': Failed to parse URL from "
          'https://[cdn/head',
        ),
      );
    });

    test('names configPath in bridge config errors', () async {
      final config = blobUrl('{"max_len": "long"}');
      addTearDown(() => URL.revokeObjectURL(config));
      fake.loadError =
          'Failed to load decision head: The decision head at '
          '"model.safetensors" has no "laya.config" metadata. Pass configJson '
          "with the head's rl_agent_config.json.";

      await expectLater(
        heads.load(fake.bridge, 'model.safetensors'),
        throwsTyped<LlamaModelException>(
          'The decision head at "model.safetensors" has no "laya.config" '
          "metadata. Pass configPath with the head's rl_agent_config.json.",
        ),
      );
      fake.loadError =
          'Failed to load decision head: The decision head config in '
          'configJson is invalid: Decision head "max_len" must be a positive '
          'integer, got "long".';
      await expectLater(
        heads.load(fake.bridge, 'model.safetensors', configUrl: config),
        throwsTyped<LlamaModelException>(
          'The decision head config in $config is invalid: Decision head '
          '"max_len" must be a positive integer, got "long".',
        ),
      );
    });

    test('maps bridge load failures to typed exceptions', () async {
      final cases = <(String, Matcher)>[
        (
          'Failed to load decision head: The decision head at '
              '"laya-head.safetensors" is 768 wide but the loaded encoder has '
              'hidden size 1024. Use the head trained for this encoder.',
          throwsA(
            isA<LlamaModelException>()
                .having(
                  (error) => error.message,
                  'message',
                  startsWith('The decision head at "laya-head.safetensors"'),
                )
                .having(
                  (error) => error.details,
                  'details',
                  'https://example.com/laya-head.safetensors',
                ),
          ),
        ),
        (
          'Failed to fetch decision head: 404 Not Found',
          throwsTyped<LlamaModelException>(
            'Failed to fetch decision head: 404 Not Found',
          ),
        ),
        (
          'Failed to load decision head: Failed to create the decision '
              'encoder context of 512 tokens.',
          throwsTyped<LlamaContextException>(
            'Failed to create the decision encoder context of 512 tokens.',
          ),
        ),
        (
          'No model loaded. Call loadModelFromUrl first.',
          throwsTyped<LlamaStateException>(
            'No model loaded. Call loadModelFromUrl first.',
          ),
        ),
        (
          'Bridge has been disposed.',
          throwsTyped<LlamaStateException>('Bridge has been disposed.'),
        ),
        (
          'Decision head load was cancelled.',
          throwsTyped<LlamaStateException>('Decision head load was cancelled.'),
        ),
      ];
      for (final (message, matcher) in cases) {
        fake.loadError = message;
        await expectLater(
          heads.load(
            fake.bridge,
            'https://user:pass@example.com/laya-head.safetensors?sig=abc',
          ),
          matcher,
          reason: message,
        );
      }
    });

    test('frees a head that reports another API version', () async {
      fake.headInfoOverrides = {'apiVersion': 2};

      await expectLater(
        heads.load(fake.bridge, 'laya-head.safetensors'),
        throwsTyped<LlamaUnsupportedException>(
          'The Web bridge implements decision API version 2; llamadart needs '
          'llama-web-bridge assets v0.1.47+ with the decision API (apiVersion 1).',
        ),
      );
      expect(fake.calls.last, 'free 7');
      expect(fake.liveHandles, isEmpty);
    });

    test('frees a head with a malformed description', () async {
      for (final field in [
        'maskText',
        'configJson',
        'deviceName',
        'sepToken',
      ]) {
        fake.headInfoOverrides = {field: null};

        await expectLater(
          heads.load(fake.bridge, 'laya-head.safetensors'),
          throwsTyped<LlamaDecisionException>(
            'The Web decision runtime returned a malformed head description.',
          ),
          reason: field,
        );
      }
      fake.headInfoOverrides = {'hiddenSize': 1.5};
      await expectLater(
        heads.load(fake.bridge, 'laya-head.safetensors'),
        throwsA(isA<LlamaDecisionException>()),
      );
      expect(fake.liveHandles, isEmpty);

      for (final handle in [0, -1]) {
        fake.headInfoOverrides = {'handle': handle};
        await expectLater(
          heads.load(fake.bridge, 'laya-head.safetensors'),
          throwsA(isA<LlamaDecisionException>()),
          reason: '$handle',
        );
      }
      expect(fake.calls.where((call) => call.startsWith('free')), [
        for (final handle in [7, 8, 9, 10, 11]) 'free $handle',
      ]);
    });
  });

  group('run', () {
    test('sends typed sequences to the bridge handle', () async {
      final head = await heads.load(fake.bridge, 'laya-head.safetensors');

      final outputs = await heads.run(fake.bridge, head.handle, [
        sequence([1, 3, 20, 3, 21, 2], [1, 3], DecisionQuestionType.score),
        sequence([1, 3, 2], [1], DecisionQuestionType.noul),
      ]);

      expect(fake.calls.last, 'run 7 2');
      expect(fake.lastSequences.map((s) => s.typedArrays), [true, true]);
      expect(fake.lastSequences.first.tokens, [1, 3, 20, 3, 21, 2]);
      expect(fake.lastSequences.first.markers, [1, 3]);
      expect(fake.lastSequences.map((s) => s.questionType), [1, 2]);
      expect(outputs, hasLength(2));
      expect(outputs.first.logits, isA<Float32List>());
      expect(outputs.first.logits, [2.0, 1.0]);
      expect(outputs.last.logits, [1.0]);
      expect(outputs.first.actLogits, [1.5, -0.5]);
    });

    test('keeps heads scoped to the bridge that loaded them', () async {
      final head = await heads.load(fake.bridge, 'laya-head.safetensors');
      final other = FakeDecisionBridge();

      await expectLater(
        heads.run(other.bridge, head.handle, [
          sequence([1], [0]),
        ]),
        throwsTyped<LlamaStateException>(
          'Decision head 1 is not loaded on this Web runtime; it was freed, '
          'its model was unloaded, or the bridge restarted. Load the decision '
          'head again.',
        ),
      );
      await expectLater(
        heads.run(fake.bridge, head.handle, [
          sequence([1], [0]),
        ]),
        throwsA(isA<LlamaStateException>()),
      );
      await expectLater(
        heads.run(null, 99, const []),
        throwsA(isA<LlamaStateException>()),
      );
      expect(other.calls, isEmpty);
      expect(fake.calls.where((call) => call.startsWith('run')), isEmpty);
    });

    test('forgets every head on clear', () async {
      final head = await heads.load(fake.bridge, 'laya-head.safetensors');
      heads.clear();

      await expectLater(
        heads.run(fake.bridge, head.handle, [
          sequence([1], [0]),
        ]),
        throwsA(isA<LlamaStateException>()),
      );
      await heads.free(fake.bridge, head.handle);
      expect(fake.calls.where((call) => !call.startsWith('capab')), [
        'load ${pageUrl('laya-head.safetensors')}',
      ]);
    });

    test(
      'maps bridge validation failures to LlamaInferenceException',
      () async {
        final head = await heads.load(fake.bridge, 'laya-head.safetensors');
        fake.runError =
            'Decision run failed: Decision sequence 0 has 4 markers for its 3 '
            'tokens; a sequence holds at most one marker per token.';

        await expectLater(
          heads.run(fake.bridge, head.handle, [
            sequence([1, 3, 2], [0, 1, 2, 1]),
          ]),
          throwsTyped<LlamaInferenceException>(
            'Decision sequence 0 has 4 markers for its 3 tokens; a sequence '
            'holds at most one marker per token.',
          ),
        );
        fake.runError = null;
        final outputs = await heads.run(fake.bridge, head.handle, [
          sequence([1, 3, 2], [1]),
        ]);
        expect(outputs, hasLength(1));
      },
    );

    test('keeps a head when the bridge is busy', () async {
      final head = await heads.load(fake.bridge, 'laya-head.safetensors');
      fake.runError =
          'Decision run failed: Decision heads cannot be loaded or run during '
          'active generation or text-to-speech synthesis';

      await expectLater(
        heads.run(fake.bridge, head.handle, [
          sequence([1], [0]),
        ]),
        throwsTyped<LlamaStateException>(
          'Decision heads cannot be loaded or run during active generation or '
          'text-to-speech synthesis',
        ),
      );
      fake.runError = null;
      final outputs = await heads.run(fake.bridge, head.handle, [
        sequence([1], [0]),
      ]);
      expect(outputs, hasLength(1));
    });

    test('drops a head the bridge lost', () async {
      final head = await heads.load(fake.bridge, 'laya-head.safetensors');
      fake.runError =
          'Decision head 1 was lost when the bridge worker failed (boom). '
          'Load the decision head again.';

      await expectLater(
        heads.run(fake.bridge, head.handle, [
          sequence([1], [0]),
        ]),
        throwsTyped<LlamaStateException>(contains('was lost')),
      );
      fake.runError = null;
      await expectLater(
        heads.run(fake.bridge, head.handle, [
          sequence([1], [0]),
        ]),
        throwsTyped<LlamaStateException>(contains('on this Web runtime')),
      );
      expect(fake.calls.where((call) => call.startsWith('run')), hasLength(1));
    });

    test('rejects malformed outputs with LlamaDecisionException', () async {
      final head = await heads.load(fake.bridge, 'laya-head.safetensors');
      final results = <JSAny? Function()>[
        () => JSObject(),
        () => <JSAny?>[null].toJS,
        () => <JSAny?>[
          JSObject()
            ..setProperty('logits'.toJS, Float32List(1).toJS)
            ..setProperty('actLogits'.toJS, <JSNumber>[1.toJS].toJS),
        ].toJS,
        () => <JSAny?>[
          JSObject()..setProperty('logits'.toJS, Float32List(1).toJS),
        ].toJS,
        () => <JSAny?>[
          JSObject()
            ..setProperty('logits'.toJS, <JSNumber>[1.toJS].toJS)
            ..setProperty('actLogits'.toJS, Float32List(2).toJS),
        ].toJS,
      ];
      for (final result in results) {
        fake.runResult = result;
        await expectLater(
          heads.run(fake.bridge, head.handle, [
            sequence([1], [0]),
          ]),
          throwsTyped<LlamaDecisionException>(
            'The Web decision runtime returned malformed outputs.',
          ),
        );
      }
    });
  });

  group('free', () {
    test('frees once and never reuses handles', () async {
      final first = await heads.load(fake.bridge, 'a.safetensors');
      await heads.free(fake.bridge, first.handle);
      await heads.free(fake.bridge, first.handle);
      await heads.free(fake.bridge, 42);
      final second = await heads.load(fake.bridge, 'b.safetensors');

      expect(second.handle, 2);
      expect(fake.calls.where((call) => call.startsWith('free')), ['free 7']);
      expect(fake.liveHandles, {8});
    });

    test('ignores heads of another bridge and maps failures', () async {
      final head = await heads.load(fake.bridge, 'laya-head.safetensors');
      final other = FakeDecisionBridge();
      final otherHead = await heads.load(other.bridge, 'laya-head.safetensors');
      expect(other.liveHandles, {7});

      await heads.free(other.bridge, head.handle);
      await heads.free(null, otherHead.handle);

      expect(other.calls.where((call) => call.startsWith('free')), isEmpty);
      expect(other.liveHandles, {7});
      expect(fake.calls.where((call) => call.startsWith('free')), isEmpty);
      expect(fake.liveHandles, {7});

      for (final message in [
        'Bridge has been disposed.',
        'Decision head handle must be a positive integer, got 0.',
      ]) {
        final loaded = await heads.load(fake.bridge, 'laya-head.safetensors');
        fake.freeError = message;
        await expectLater(
          heads.free(fake.bridge, loaded.handle),
          throwsTyped<LlamaStateException>(message),
          reason: message,
        );
      }
    });
  });
}
