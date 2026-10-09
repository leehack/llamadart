@TestOn('vm')
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:mirrors';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:llamadart/src/backends/llama_cpp/exit_teardown_api.dart';
import 'package:llamadart/src/backends/llama_cpp/llama_cpp_service.dart';
import 'package:llamadart/src/core/exceptions.dart';
import 'package:llamadart/src/core/models/chat/content_part.dart';
import 'package:llamadart/src/core/models/inference/generation_params.dart';
import 'package:llamadart/src/core/models/inference/model_params.dart';
import 'package:test/test.dart';

import '../../../support/fake_mtmd.dart';
import '../../../support/synthetic_embedding_gguf.dart';

const _params = ModelParams(gpuLayers: 0, contextSize: 64);
const _greedy = GenerationParams(maxTokens: 1, temp: 0, topK: 1, seed: 1);

// The first bytes mtmd reads to tell audio from an image.
final Uint8List _png = Uint8List.fromList([
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 0x0d, //
  0x49, 0x48, 0x44, 0x52,
]);
final Uint8List _wav = Uint8List.fromList(
  'RIFF\x24\x00\x00\x00WAVEfmt '.codeUnits,
);
final Uint8List _mp3 = Uint8List.fromList([0xff, 0xfb, ...List.filled(12, 0)]);
final Uint8List _flac = Uint8List.fromList(
  'fLaC\x00\x00\x00\x22data'.codeUnits,
);

Matcher _noEncoder(String kind) => throwsA(
  isA<LlamaUnsupportedException>().having(
    (e) => e.message,
    'message',
    '$kind input is not supported by the loaded multimodal projector: it has '
        'no ${kind.toLowerCase()} encoder. Load a projector that has one, or '
        'leave ${kind.toLowerCase()} input out of the request.',
  ),
);

Matcher _untyped(String text) => throwsA(
  isA<Exception>()
      .having((e) => e, 'type', isNot(isA<LlamaException>()))
      .having((e) => '$e', 'text', 'Exception: $text'),
);

// Runs the real llama.cpp runtime on the CPU with a fake projector whose
// encoders, bitmap loading and tokenize result each test sets.
void main() {
  late Directory dir;
  late LlamaCppService service;
  late FakeMtmd fake;
  late int context;

  void attach({required bool vision, required bool audio}) {
    dir = Directory.systemTemp.createTempSync('llamadart_media_encoder_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final modelPath = writeSyntheticLlamaGguf('${dir.path}/model.gguf').path;
    service = LlamaCppService(objectCalls: LlamaCppObjectCalls.upstream)
      ..initializeBackend();
    final model = service.loadModel(modelPath, _params);
    fake = FakeMtmd.install(
      service,
      tokens: service.tokenize(model, 'ab', true),
      vision: vision,
      audio: audio,
    );
    addTearDown(fake.dispose);
    addTearDown(service.dispose);
    context = service.createContext(model, _params);
    final projectorPath = '${dir.path}/mmproj.gguf';
    File(projectorPath).writeAsStringSync('GGUF');
    service.createMultimodalContext(model, projectorPath);
    fake.calls.clear();
  }

  String file(String name, List<int> bytes) =>
      (File('${dir.path}/$name')..writeAsBytesSync(bytes)).path;

  Future<void> send(List<LlamaContentPart> parts) async {
    final cancel = calloc<Int8>();
    try {
      await service
          .generate(
            context,
            '<__media__>' * parts.length,
            _greedy,
            cancel.address,
            parts: parts,
          )
          .drain<void>();
    } finally {
      calloc.free(cancel);
    }
  }

  group('a projector with a vision encoder only', () {
    setUp(() => attach(vision: true, audio: false));

    test('names the audio encoder when mtmd cannot load encoded audio, '
        'whatever the type of the part', () async {
      fake.encodedBitmapLoads = false;

      for (final audio in [_wav, _mp3, _flac]) {
        await expectLater(
          send([LlamaAudioContent(bytes: audio)]),
          _noEncoder('Audio'),
        );
      }
      await expectLater(
        send([LlamaAudioContent(path: file('clip.wav', _wav))]),
        _noEncoder('Audio'),
      );
      await expectLater(
        send([LlamaImageContent(bytes: _wav)]),
        _noEncoder('Audio'),
      );
      await expectLater(
        send([LlamaAudioContent(bytes: _wav), LlamaImageContent(bytes: _png)]),
        _noEncoder('Audio'),
      );
      expect(fake.calls, isNot(contains('mtmd_tokenize')));
    });

    test('names the audio encoder when mtmd refuses PCM samples', () async {
      fake.tokenizeResult = 2;

      await expectLater(
        send([LlamaAudioContent(samples: Float32List(1))]),
        _noEncoder('Audio'),
      );
      expect(fake.calls, contains('mtmd_tokenize'));
    });

    test('hands mtmd an image sent as an audio part, by bytes and by '
        'path', () async {
      await send([LlamaAudioContent(bytes: _png)]);
      await send([LlamaAudioContent(path: file('page.png', _png))]);

      expect(fake.calls.where((call) => call == 'mtmd_tokenize'), hasLength(2));
      expect(fake.evaluations, 2);
    });

    test('keeps the load error of an image mtmd cannot decode', () async {
      fake.encodedBitmapLoads = false;

      await expectLater(
        send([LlamaAudioContent(bytes: _png)]),
        _untyped('Failed to load media part 0'),
      );
      await expectLater(
        send([LlamaImageContent(path: '${dir.path}/missing.png')]),
        _untyped('Failed to load media part 0'),
      );
    });

    test('keeps the tokenize error of an image request', () async {
      fake.tokenizeResult = 2;

      await expectLater(
        send([LlamaImageContent(bytes: _png)]),
        _untyped('mtmd_tokenize failed: 2'),
      );
    });
  });

  group('a projector with an audio encoder only', () {
    setUp(() => attach(vision: false, audio: true));

    test('names the image encoder when mtmd refuses an image, whatever the '
        'type of the part', () async {
      fake.tokenizeResult = 2;

      await expectLater(
        send([LlamaImageContent(bytes: _png)]),
        _noEncoder('Image'),
      );
      await expectLater(
        send([LlamaImageContent(path: file('page.png', _png))]),
        _noEncoder('Image'),
      );
      await expectLater(
        send([LlamaAudioContent(bytes: _png)]),
        _noEncoder('Image'),
      );
      await expectLater(
        send([LlamaAudioContent(bytes: _wav), LlamaImageContent(bytes: _png)]),
        _noEncoder('Image'),
      );
    });

    test('hands mtmd audio sent as an image part, by bytes and by '
        'path', () async {
      await send([LlamaImageContent(bytes: _wav)]);
      await send([LlamaImageContent(path: file('clip.wav', _wav))]);

      expect(fake.calls.where((call) => call == 'mtmd_tokenize'), hasLength(2));
      expect(fake.evaluations, 2);
    });

    test('keeps the errors of an audio request', () async {
      fake.tokenizeResult = 2;
      await expectLater(
        send([LlamaAudioContent(samples: Float32List(1))]),
        _untyped('mtmd_tokenize failed: 2'),
      );

      fake
        ..tokenizeResult = 0
        ..encodedBitmapLoads = false;
      await expectLater(
        send([LlamaAudioContent(bytes: _wav)]),
        _untyped('Failed to load media part 0'),
      );
    });
  });

  test('a runtime without the mtmd encoder probe leaves the mtmd error as it '
      'is', () {
    attach(vision: false, audio: false);
    final owner = reflectClass(LlamaCppService).owner as LibraryMirror;
    Object? missingEncoder() => reflect(service).invoke(
      MirrorSystem.getSymbol('_missingEncoderFor', owner),
      [
        FakeMtmd.projector,
        <LlamaContentPart>[
          LlamaImageContent(bytes: _png),
          LlamaAudioContent(samples: Float32List(1)),
        ],
      ],
    ).reflectee;

    expect(missingEncoder(), isA<LlamaUnsupportedException>());
    fake.setFallback(present: false);
    // The projector is freed through the fallback.
    addTearDown(() => fake.setFallback(present: true));
    expect(missingEncoder(), isNull);
  });
}
