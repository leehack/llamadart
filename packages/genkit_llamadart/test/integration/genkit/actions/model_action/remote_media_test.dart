import 'dart:async';
import 'dart:typed_data';

import 'package:genkit/plugin.dart' as genkit;
import 'package:genkit_llamadart/genkit_llamadart.dart';
import 'package:llamadart/llamadart.dart' as llama;
import 'package:test/test.dart';

import '../../../../core/runtime/test_support/fake_runtime.dart';

class _Resolver implements LlamaDartMediaResolver {
  final calls = <String>[];
  Object? error;
  genkit.CancellationToken? lastCancel;
  Completer<void>? started;
  Future<void>? gate;
  @override
  Future<Uint8List> resolve(
    Uri uri, {
    required String contentType,
    genkit.CancellationToken? cancel,
  }) async {
    calls.add(contentType);
    lastCancel = cancel;
    started?.complete();
    await gate;
    if (error != null) throw error!;
    return Uint8List.fromList([7, 8, 9]);
  }
}

genkit.ModelRequest _request(String type, {String? url}) => genkit.ModelRequest(
  messages: [
    genkit.Message(
      role: genkit.Role.user,
      content: [
        genkit.TextPart(text: 'Describe'),
        genkit.MediaPart(
          media: genkit.Media(
            url: url ?? 'https://media.example/asset?token=secret',
            contentType: type,
          ),
        ),
      ],
    ),
  ],
);

genkit.ModelRequest _toolResultRequest(String type) => genkit.ModelRequest(
  messages: [
    genkit.Message(
      role: genkit.Role.tool,
      content: [
        genkit.ToolResponsePart(
          toolResponse: genkit.ToolResponse(
            ref: 'call',
            name: 'render',
            content: [
              {'text': 'caption'},
              {
                'media': {
                  'url': 'https://media.example/asset?token=secret',
                  'contentType': type,
                },
              },
            ],
          ),
        ),
      ],
    ),
  ],
);

void main() {
  const native = bool.fromEnvironment('dart.library.io');
  late _Resolver resolver;
  late FakeRuntime runtime;
  late LlamaDartPlugin plugin;
  late genkit.Model<LlamaDartGenerationConfig> model;
  late int factories;

  setUp(() async {
    factories = 0;
    resolver = _Resolver();
    runtime = FakeRuntime()..createChunks = [textChunk('ok')];
    plugin = LlamaDartPlugin(
      models: [
        const LlamaModelDefinition(name: 'local', modelPath: '/model.gguf'),
      ],
      mediaResolver: resolver,
      runtimeFactory: () {
        factories++;
        return runtime;
      },
    );
    model = (await plugin.init())
        .whereType<genkit.Model<LlamaDartGenerationConfig>>()
        .single;
  });
  tearDown(() => plugin.dispose());

  test(
    'remote resolution retains validated text and decoded inline media',
    () async {
      if (!native) return;
      final release = Completer<void>();
      resolver.started = Completer<void>();
      resolver.gate = release.future;
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final request = _request('audio/wav');
      request.messages.single.content = [
        genkit.TextPart(text: 'original'),
        genkit.MediaPart(
          media: genkit.Media(
            url: 'data:image/png;base64,AQID',
            contentType: 'image/png',
          ),
        ),
        request.messages.single.content.last,
      ];
      final pending = model(request);
      await resolver.started!.future;
      request.messages.single.content = [genkit.TextPart(text: 'changed')];
      release.complete();
      await pending;
      final parts = runtime.lastMessages!.single.parts;
      expect(parts, hasLength(3));
      expect((parts[0] as llama.LlamaTextContent).text, 'original');
      expect((parts[1] as llama.LlamaImageContent).bytes, [1, 2, 3]);
      expect((parts[2] as llama.LlamaAudioContent).bytes, [7, 8, 9]);
      expect(resolver.calls, ['audio/wav']);
    },
  );

  test(
    'native image/audio become bytes; Web images retain direct URL',
    () async {
      await model(_request('image/png'));
      final image =
          runtime.lastMessages!.single.parts.last as llama.LlamaImageContent;
      if (native) {
        expect(image.bytes, [7, 8, 9]);
        expect(image.url, isNull);
        await model(_request('audio/wav'));
        expect(
          (runtime.lastMessages!.single.parts.last as llama.LlamaAudioContent)
              .bytes,
          [7, 8, 9],
        );
        expect(resolver.calls, ['image/png', 'audio/wav']);
      } else {
        expect(image.url, 'https://media.example/asset?token=secret');
        expect(resolver.calls, isEmpty);
        await expectLater(
          model(_request('audio/wav')),
          throwsA(isA<genkit.GenkitException>()),
        );
        expect(resolver.calls, isEmpty);
      }
    },
  );

  test(
    'action total latency includes resolution before model initialization',
    () async {
      if (!native) return;
      final released = Completer<void>();
      resolver.started = Completer<void>();
      resolver.gate = released.future;
      final pending = model(_request('image/png'));
      await resolver.started!.future;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(factories, 0);
      released.complete();
      final response = await pending;
      expect(response.raw!['totalLatencyMs'], greaterThanOrEqualTo(40));
      expect(response.raw!['queueMs'], isNonNegative);
      expect(response.raw!['initializationMs'], isNonNegative);
    },
  );

  test(
    'cancellation during resolution prevents later model initialization',
    () async {
      if (!native) return;
      final released = Completer<void>();
      resolver.started = Completer<void>();
      resolver.gate = released.future;
      final controller = genkit.CancellationController();
      final pending = model(_request('audio/wav'), cancel: controller.token);
      final assertion = expectLater(
        pending,
        throwsA(isA<genkit.CancelledException>()),
      );
      await resolver.started!.future;
      controller.cancel('secret caller reason');
      released.complete();
      await assertion;
      expect(factories, 0);
    },
  );

  test('local, file and data input bypass remote resolver', () async {
    for (final url in [
      '/local.png',
      'file:///local.png',
      'data:image/png;base64,AQID',
    ]) {
      await model(_request('image/png', url: url));
    }
    expect(resolver.calls, isEmpty);
    expect(
      (runtime.lastMessages!.single.parts.last as llama.LlamaImageContent)
          .bytes,
      [1, 2, 3],
    );
  });

  test(
    'invalid media and malformed schemas fail before resolver or model load',
    () async {
      await expectLater(
        model(_request('video/mp4')),
        throwsA(isA<genkit.GenkitException>()),
      );
      final request = _request('image/png')
        ..tools = [
          genkit.ToolDefinition(
            name: 'invalid',
            description: 'Invalid schema',
            inputSchema: {'type': 'object', 'properties': []},
          ),
        ];
      await expectLater(model(request), throwsA(isA<genkit.GenkitException>()));
      expect(resolver.calls, isEmpty);
      expect(factories, 0);
    },
  );

  test(
    'resolver failures are sanitized and do not poison the next request',
    () async {
      if (!native) return;
      resolver.error = genkit.GenkitException(
        'secret signed URL',
        cause: 'secret',
      );
      await expectLater(
        model(_request('audio/wav')),
        throwsA(
          isA<genkit.GenkitException>()
              .having(
                (e) => e.toString(),
                'safe message',
                isNot(contains('secret')),
              )
              .having((e) => e.cause, 'cause', isNull),
        ),
      );
      expect(factories, 0);
      resolver.error = null;
      await model(_request('audio/wav'));
      expect(runtime.createCallCount, 1);
    },
  );

  test(
    'cancellation is passed into resolver and prevents runtime initialization',
    () async {
      if (!native) return;
      final controller = genkit.CancellationController()..cancel();
      await expectLater(
        model(_request('audio/wav'), cancel: controller.token),
        throwsA(isA<genkit.CancelledException>()),
      );
      expect(resolver.calls, isEmpty);
      expect(factories, 0);
      final active = genkit.CancellationController();
      await model(_request('audio/wav'), cancel: active.token);
      expect(resolver.lastCancel, same(active.token));
    },
  );

  test(
    'runtime capability guards still reject resolved unsupported media',
    () async {
      if (!native) return;
      runtime.capabilitySnapshot = const llama.LlamaEngineCapabilities(
        isSupported: true,
      );
      await expectLater(
        model(_request('audio/wav')),
        throwsA(
          isA<genkit.GenkitException>().having(
            (e) => e.status,
            'status',
            genkit.StatusCode.unimplemented,
          ),
        ),
      );
      expect(resolver.calls, ['audio/wav']);
      expect(runtime.createCallCount, 0);
    },
  );

  group('tool-result media', () {
    setUp(() {
      runtime.capabilitySnapshot = const llama.LlamaEngineCapabilities(
        isSupported: true,
        supportsVision: true,
        supportsMultiTurnChat: true,
        supportsToolCalling: true,
        toolResultMedia: {llama.LlamaToolResultMedia.image},
      );
    });

    test('remote images resolve through the application resolver', () async {
      if (!native) return;
      await model(_toolResultRequest('image/png'));
      final result =
          runtime.lastMessages!.single.parts.single
              as llama.LlamaToolResultContent;
      expect(result.id, 'call');
      expect(result.result, isNull);
      expect((result.content[0] as llama.LlamaTextContent).text, 'caption');
      final image = result.content[1] as llama.LlamaImageContent;
      expect(image.bytes, [7, 8, 9]);
      expect(image.url, isNull);
      expect(resolver.calls, ['image/png']);
    });

    test('resolver failures are sanitized before model load', () async {
      if (!native) return;
      resolver.error = genkit.GenkitException(
        'secret signed URL',
        cause: 'secret',
      );
      await expectLater(
        model(_toolResultRequest('image/png')),
        throwsA(
          isA<genkit.GenkitException>()
              .having(
                (e) => e.toString(),
                'safe message',
                isNot(contains('secret')),
              )
              .having((e) => e.cause, 'cause', isNull),
        ),
      );
      expect(factories, 0);
    });

    test('cancellation reaches the resolver', () async {
      if (!native) return;
      final active = genkit.CancellationController();
      await model(_toolResultRequest('image/png'), cancel: active.token);
      expect(resolver.lastCancel, same(active.token));
      final cancelled = genkit.CancellationController()..cancel();
      await expectLater(
        model(_toolResultRequest('image/png'), cancel: cancelled.token),
        throwsA(isA<genkit.CancelledException>()),
      );
      expect(resolver.calls, hasLength(1));
    });

    for (final (url, type) in [
      ('https://media.example/clip', 'video/mp4'),
      ('https://media.example/voice', 'audio/wav'),
      ('https://media.example/doc.pdf', 'application/pdf'),
    ]) {
      test('remote $type is rejected without resolution', () async {
        if (!native) return;
        final request = _toolResultRequest(type);
        final response = request.messages.single.content.single.toolResponse!;
        (response.content![1] as Map)['media']['url'] = url;
        await expectLater(
          model(request),
          throwsA(
            isA<genkit.GenkitException>().having(
              (e) => e.status,
              'status',
              genkit.StatusCode.unimplemented,
            ),
          ),
        );
        expect(resolver.calls, isEmpty);
        expect(factories, 0);
      });
    }
  });
}
