@Tags(['local-only', 'e2e'])
/// Local-only device check that llama.cpp text generation and
/// stable_diffusion image generation coexist in one process
/// (https://github.com/leehack/llamadart/issues/779).
///
/// It downloads and hash-checks the locked `chat-gguf-cpu` validation model
/// and the chat app's SDXS-512 image model, then runs these steps through the
/// public API. Each engine stays loaded from its load to the last step:
///
/// 1. `solo`: a greedy, seeded chat reply from a `LlamaEngine`, before
///    anything of the image runtime is called.
/// 2. `ImageGenerationEngine.load`, then a seeded 512x512 image.
/// 3. `after_image`: the same chat request on the same `LlamaEngine`.
/// 4. The same image request again.
///
/// The test fails unless the second reply equals the first and both are at
/// least 16 tokens long, the second PNG equals the first and is a 512x512
/// image that is not blank, and both engines name their backend.
///
/// A `started` line precedes each step, so a run that dies names the step it
/// died in, and a `memory` line with the resident and peak resident set size
/// follows it. A typed error is logged before it fails the test:
///
/// ```text
/// E2E coexistence: text when=<solo|after_image> sha256=<hex> tokens=<n> ms=<n>
/// E2E coexistence: image n=<1|2> sha256=<hex> backend=<name> ms=<n>
/// E2E coexistence: memory after=<step> rss_mb=<n> peak_rss_mb=<n>
/// E2E coexistence: error step=<step> type=<Type> message=<json string>
/// E2E coexistence: result text_equal=<bool> image_equal=<bool>
/// ```
///
/// The first PNG and a `coexistence.json` receipt go to `coexistence/run-*`
/// (app external files on Android, the temporary directory elsewhere).
///
/// ```bash
/// cd example/chat_app
/// flutter test --run-skipped -t local-only \
///   integration_test/text_image_coexistence_e2e_test.dart -d <device>
/// ```
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/hook/native_release_pins.dart';
import 'package:llamadart_validation/io.dart';
import 'package:llamadart_validation/llamadart_validation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:llamadart_chat_example/models/image_model_profile.dart';
import 'package:llamadart_chat_example/services/image_model_service.dart';

import 'support/image_evidence.dart';

const _logTag = 'E2E coexistence:';
const _evidenceDirectoryName = 'coexistence';
const _textProfileAsset =
    'packages/llamadart_validation/assets/profiles/chat-gguf-cpu.json';
const _textPrompt = 'Write three short sentences about the sea.';
const _minReplyTokens = 16;
const _imageProfile = ImageModelProfile.sdxs;
const _imagePrompt = 'a lighthouse on a cliff at sunset';
const _imageSeed = 42;
const _imageSize = 512;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('llama.cpp text and stable_diffusion images coexist', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Text('Running text and image coexistence E2E')),
      ),
    );
    const commit = String.fromEnvironment(
      'VALIDATION_COMMIT',
      defaultValue: 'unknown',
    );
    const dirty = bool.fromEnvironment(
      'VALIDATION_SOURCE_DIRTY',
      defaultValue: true,
    );
    debugPrint(
      '$_logTag config os=${Platform.operatingSystem} commit=$commit '
      'dirty=$dirty llama_cpp=$llamaCppTag '
      'stable_diffusion=$stableDiffusionReleaseTag',
    );
    final textProfile = ValidationProfile.fromJson(
      jsonDecode(await rootBundle.loadString(_textProfileAsset))
          as Map<String, dynamic>,
    );
    final textModelPath = await _prepareTextModel(textProfile);
    final imageModel = await _prepareImageModel();

    final memory = <String, Map<String, int>>{};
    Future<T> step<T>(String name, Future<T> Function() body) async {
      debugPrint('$_logTag started step=$name');
      try {
        return await body();
      } on LlamaException catch (error) {
        debugPrint(
          '$_logTag error step=$name type=${error.runtimeType} '
          'message=${jsonEncode(error.message)}',
        );
        rethrow;
      } finally {
        final snapshot = memory[name] = {
          'rss_mb': ProcessInfo.currentRss >> 20,
          'peak_rss_mb': ProcessInfo.maxRss >> 20,
        };
        debugPrint(
          '$_logTag memory after=$name rss_mb=${snapshot['rss_mb']} '
          'peak_rss_mb=${snapshot['peak_rss_mb']}',
        );
      }
    }

    final textEngine = LlamaEngine(LlamaBackend());
    addTearDown(textEngine.dispose);
    final textBackend = await step('text_load', () async {
      await textEngine.setModel(
        LlamaModel(ModelSource.path(textModelPath)),
        params: textProfile.loadParams,
      );
      return textEngine.getBackendName();
    });
    debugPrint('$_logTag engine kind=text backend=$textBackend');
    expect(textBackend, isNotEmpty);

    Future<Map<String, Object>> reply(String when) =>
        step('text_$when', () async {
          final watch = Stopwatch()..start();
          final completion = await textEngine
              .create(
                [
                  LlamaChatMessage.fromText(
                    role: LlamaChatRole.user,
                    text: _textPrompt,
                  ),
                ],
                params: textProfile.generationParams,
                enableThinking: false,
              )
              .collect();
          final ms = watch.elapsedMilliseconds;
          final hash = sha256.convert(utf8.encode(completion.text)).toString();
          final tokens = completion.usage?.completionTokens ?? 0;
          debugPrint(
            '$_logTag reply when=$when '
            'finish=${completion.finishReason?.wireValue} '
            'text=${jsonEncode(completion.text)}',
          );
          debugPrint(
            '$_logTag text when=$when sha256=$hash tokens=$tokens ms=$ms',
          );
          return {
            'text': completion.text,
            'sha256': hash,
            'tokens': tokens,
            'ms': ms,
          };
        });

    final solo = await reply('solo');

    final imageEngine = await step(
      'image_load',
      () => ImageGenerationEngine.load(imageModel.toGenerationModel()),
    );
    addTearDown(imageEngine.dispose);
    final imageCapabilities = await imageEngine.capabilities;
    final imageBackend = imageCapabilities.backendName ?? '';
    debugPrint(
      '$_logTag engine kind=image backend=$imageBackend '
      'model=${jsonEncode(imageCapabilities.modelVersion)}',
    );
    expect(imageBackend, isNotEmpty);

    Future<({Uint8List png, String sha256, int ms})> picture(int n) =>
        step('image_$n', () async {
          final watch = Stopwatch()..start();
          final result = await imageEngine.generateImage(
            ImageGenerationRequest(
              prompt: _imagePrompt,
              width: _imageSize,
              height: _imageSize,
              steps: _imageProfile.steps,
              guidanceScale: _imageProfile.guidanceScale,
              seed: _imageSeed,
            ),
          );
          final ms = watch.elapsedMilliseconds;
          final image = result.images.single;
          final png = image.toPng();
          final hash = sha256.convert(png).toString();
          debugPrint(
            '$_logTag image n=$n sha256=$hash backend=$imageBackend ms=$ms',
          );
          expect(result.seed, _imageSeed);
          expect(inspectEvidencePng(png), {
            'width': _imageSize,
            'height': _imageSize,
          });
          expect(
            image.pixels.toSet().length,
            greaterThan(64),
            reason: 'image $n is blank',
          );
          return (png: png, sha256: hash, ms: ms);
        });

    final first = await picture(1);
    final afterImage = await reply('after_image');
    final second = await picture(2);
    await step('dispose', () async {
      await imageEngine.dispose();
      await textEngine.dispose();
    });

    final textEqual = afterImage['text'] == solo['text'];
    final imageEqual = second.sha256 == first.sha256;
    debugPrint('$_logTag result text_equal=$textEqual image_equal=$imageEqual');
    final directory = await _writeEvidence(first.png, {
      'schema_version': 1,
      'scenario': 'text-image-coexistence-e2e',
      'source_commit': commit,
      'source_dirty': dirty,
      'os': Platform.operatingSystem,
      'text': {
        'runtime_tag': llamaCppTag,
        'profile': textProfile.id,
        'model_sha256': textProfile.modelHash,
        'backend': textBackend,
        'prompt': _textPrompt,
        'solo': solo,
        'after_image': afterImage,
      },
      'image': {
        'runtime_tag': stableDiffusionReleaseTag,
        'profile': _imageProfile.id,
        'model_sha256': _imageProfile.modelSource.sha256,
        'backend': imageBackend,
        'prompt': _imagePrompt,
        'seed': _imageSeed,
        'width': _imageSize,
        'height': _imageSize,
        'first': {'sha256': first.sha256, 'ms': first.ms},
        'second': {'sha256': second.sha256, 'ms': second.ms},
      },
      'memory': memory,
      'text_equal': textEqual,
      'image_equal': imageEqual,
    });
    debugPrint('$_logTag evidence written: ${directory.path}');

    expect(
      solo['tokens'],
      greaterThanOrEqualTo(_minReplyTokens),
      reason: 'the reply is too short to compare',
    );
    expect(
      (solo['text'] as String).trim(),
      isNotEmpty,
      reason: 'the reply has no visible text to compare',
    );
    expect(
      afterImage['text'],
      solo['text'],
      reason: 'the reply changed once the image engine was loaded',
    );
    expect(
      second.sha256,
      first.sha256,
      reason: 'the same seed gave another image',
    );
  }, timeout: const Timeout(Duration(minutes: 30)));
}

Future<String> _prepareTextModel(ValidationProfile profile) async {
  final support = await getApplicationSupportDirectory();
  final client = http.Client();
  final watch = Stopwatch()..start();
  try {
    final model = await prepareModel(
      profile,
      Directory(p.join(support.path, 'validation', 'models')),
      client: client,
      timeout: const Duration(minutes: 10),
    );
    debugPrint(
      '$_logTag model kind=text sha256=${profile.modelHash} '
      'cache_hit=${model.evidence['cache_hit']} '
      'prepare_ms=${watch.elapsedMilliseconds}',
    );
    return model.path;
  } finally {
    client.close();
  }
}

Future<InstalledImageModel> _prepareImageModel() async {
  final service = ImageModelService();
  final watch = Stopwatch()..start();
  final cached = await service.resolve(_imageProfile);
  final installed =
      cached ??
      await service.install(
        _imageProfile,
        cancelToken: CancelToken(),
        onProgress: (_) {},
        onVerifying: () {},
      );
  debugPrint(
    '$_logTag model kind=image sha256=${_imageProfile.modelSource.sha256} '
    'cache_hit=${cached != null} prepare_ms=${watch.elapsedMilliseconds}',
  );
  return installed;
}

Future<Directory> _writeEvidence(
  Uint8List png,
  Map<String, Object?> receipt,
) async {
  final base = Platform.isAndroid
      ? await getExternalStorageDirectory()
      : await getTemporaryDirectory();
  if (base == null) throw StateError('No pullable evidence directory');
  final directory = Directory(
    p.join(
      base.path,
      _evidenceDirectoryName,
      'run-${DateTime.now().toUtc().microsecondsSinceEpoch}',
    ),
  );
  await directory.create(recursive: true);
  await File(
    p.join(directory.path, 'coexistence_image.png'),
  ).writeAsBytes(png, flush: true);
  await File(
    p.join(directory.path, 'coexistence.json'),
  ).writeAsString('${jsonEncode(receipt)}\n', flush: true);
  return directory;
}
