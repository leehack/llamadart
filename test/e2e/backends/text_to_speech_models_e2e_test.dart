@TestOn('vm')
@Tags(<String>['local-only', 'e2e'])
@Timeout(Duration(minutes: 30))
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:llamadart/llamadart.dart';
import 'package:test/test.dart';

const _asrModelKey = 'LLAMADART_STT_MODEL_PATH';
const _asrMmprojKey = 'LLAMADART_STT_MMPROJ_PATH';
const _outputDirectoryKey = 'LLAMADART_TTS_OUTPUT_DIR';
const _gpuKey = 'LLAMADART_TTS_GPU';
const _text = 'Good morning. The weather is sunny and warm today.';

const _params = ModelParams(
  contextSize: 4096,
  numberOfThreads: 2,
  numberOfThreadsBatch: 2,
  preferredBackend: GpuBackend.cpu,
  gpuLayers: 0,
);
const _gpuParams = ModelParams(
  contextSize: 4096,
  numberOfThreads: 2,
  numberOfThreadsBatch: 2,
  gpuLayers: ModelParams.maxGpuLayers,
);

class _Spec {
  final String name;
  final String key;
  final TextToSpeechAdapter adapter;
  final int sampleRateHz;
  final List<String> voices;
  final bool supportsLanguage;
  final double temperature;

  const _Spec({
    required this.name,
    required this.key,
    required this.adapter,
    required this.sampleRateHz,
    this.voices = const <String>[],
    this.supportsLanguage = false,
    this.temperature = 0.8,
  });

  String get modelKey => 'LLAMADART_TTS_${key}_MODEL_PATH';
  String get mmprojKey => 'LLAMADART_TTS_${key}_MMPROJ_PATH';
}

const _specs = <_Spec>[
  _Spec(
    name: 'LFM3-Audio',
    key: 'LFM3',
    adapter: Lfm3AudioTtsAdapter(),
    sampleRateHz: 24000,
    voices: ['female', 'male'],
    supportsLanguage: true,
  ),
  _Spec(
    name: 'Soprano',
    key: 'SOPRANO',
    adapter: SopranoTtsAdapter(),
    sampleRateHz: 32000,
    temperature: 0,
  ),
];

void main() {
  SpeechToTextEngine? recognizer;

  setUpAll(() async {
    final model = _file(_asrModelKey);
    final projector = _file(_asrMmprojKey);
    if (model == null || projector == null) return;
    recognizer = await SpeechToTextEngine.load(
      SpeechToTextModel(
        ModelSource.path(model),
        projector: ModelSource.path(projector),
        adapter: const Qwen3AsrAdapter(),
      ),
      params: _params,
    );
  });

  tearDownAll(() async => recognizer?.dispose());

  for (final spec in _specs) {
    group(spec.name, () {
      TextToSpeechEngine? synthesizer;

      setUpAll(() async {
        final model = _file(spec.modelKey);
        final projector = _file(spec.mmprojKey);
        if (model == null || projector == null) return;
        synthesizer = await TextToSpeechEngine.load(
          TextToSpeechModel(
            ModelSource.path(model),
            projector: ModelSource.path(projector),
            adapter: spec.adapter,
          ),
          params: Platform.environment[_gpuKey] == '1' ? _gpuParams : _params,
        );
      });

      tearDownAll(() async => synthesizer?.dispose());

      TextToSpeechEngine? engine() {
        final value = synthesizer;
        if (value == null) {
          markTestSkipped(
            'Set ${spec.modelKey} and ${spec.mmprojKey} to run the '
            '${spec.name} E2E.',
          );
        }
        return value;
      }

      TextToSpeechRequest request({String? voice, int seed = 1}) =>
          TextToSpeechRequest(
            text: _text,
            voice: voice,
            maxFrames: 1024,
            temperature: spec.temperature,
            seed: seed,
          );

      test('reports the model capabilities', () async {
        final tts = engine();
        if (tts == null) return;
        final capabilities = await tts.capabilities;
        expect(
          capabilities.isSupported,
          isTrue,
          reason: capabilities.unsupportedReason,
        );
        expect(capabilities.sampleRateHz, spec.sampleRateHz);
        expect(capabilities.channelCount, 1);
        expect(capabilities.supportsVoice, spec.voices.isNotEmpty);
        expect(capabilities.voices, spec.voices);
        expect(capabilities.supportsLanguage, spec.supportsLanguage);
        expect(capabilities.supportsSpeakerReference, isFalse);
      });

      test('speech transcribes back to the text', () async {
        final tts = engine();
        if (tts == null) return;
        final result = await tts.synthesizeOnce(request());
        expect(result.sampleRateHz, spec.sampleRateHz);
        expect(result.truncated, isFalse);
        await _expectTranscript(recognizer, result, '${spec.key}-default');
      });

      test('each listed voice speaks the text and changes the audio', () async {
        final tts = engine();
        if (tts == null) return;
        if (spec.voices.length < 2) {
          markTestSkipped('${spec.name} lists fewer than two voices.');
          return;
        }
        final first = await tts.synthesizeOnce(
          request(voice: spec.voices.first),
        );
        final last = await tts.synthesizeOnce(
          request(voice: spec.voices.last.toUpperCase()),
        );
        expect(last.samples, isNot(orderedEquals(first.samples)));
        await _expectTranscript(
          recognizer,
          last,
          '${spec.key}-${spec.voices.last}',
        );
      });

      test('rejects what the model does not take before synthesis', () async {
        final tts = engine();
        if (tts == null) return;
        if (spec.voices.isEmpty) {
          await expectLater(
            tts.synthesize(request(voice: 'female')),
            throwsA(isA<LlamaUnsupportedException>()),
          );
        } else {
          await expectLater(
            tts.synthesize(request(voice: 'no-such-voice')),
            throwsA(isA<LlamaTextToSpeechException>()),
          );
        }
        if (!spec.supportsLanguage) {
          await expectLater(
            tts.synthesize(
              const TextToSpeechRequest(text: _text, language: 'en'),
            ),
            throwsA(isA<LlamaUnsupportedException>()),
          );
        }
        await expectLater(
          tts.synthesize(
            TextToSpeechRequest(
              text: _text,
              speakerReference: SpeechAudioBytesInput(
                Uint8List.fromList(const [1, 2, 3]),
              ),
            ),
          ),
          throwsA(isA<LlamaUnsupportedException>()),
        );
      });

      test('a fixed seed repeats after a cancelled task', () async {
        final tts = engine();
        if (tts == null) return;
        final first = await tts.synthesizeOnce(request());
        final cancelled = await tts.synthesize(request());
        await cancelled.events.firstWhere(
          (event) => event is TextToSpeechProgressEvent,
        );
        cancelled.cancel();
        expect(
          (await cancelled.done).state,
          TextToSpeechCompletionState.cancelled,
        );
        final repeated = await tts.synthesizeOnce(request());
        expect(repeated.framesGenerated, first.framesGenerated);
        expect(repeated.samples, orderedEquals(first.samples));
      });
    });
  }
}

Future<void> _expectTranscript(
  SpeechToTextEngine? recognizer,
  TextToSpeechResult result,
  String name,
) async {
  final wav = result.toWavBytes();
  final directory = Platform.environment[_outputDirectoryKey];
  if (directory != null && directory.isNotEmpty) {
    File('$directory/$name.wav')
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(wav, flush: true);
  }
  if (recognizer == null) {
    markTestSkipped(
      'Set $_asrModelKey and $_asrMmprojKey to check the speech content.',
    );
    return;
  }
  final transcript = (await recognizer.transcribeOnce(
    SpeechToTextRequest(
      audio: SpeechAudioBytesInput(
        wav,
        format: const SpeechAudioFormat(encoding: 'wav'),
      ),
    ),
  )).text;
  print('TRANSCRIPT $name: $transcript');
  expect(
    _wordErrorRate(_text, transcript),
    lessThanOrEqualTo(0.25),
    reason: 'transcript: $transcript',
  );
}

double _wordErrorRate(String reference, String hypothesis) {
  List<String> words(String text) => text
      .toLowerCase()
      .replaceAll(RegExp(r"[^a-z0-9' ]"), ' ')
      .split(RegExp(r'\s+'))
      .where((word) => word.isNotEmpty)
      .toList();
  final expected = words(reference);
  final actual = words(hypothesis);
  var previous = List<int>.generate(actual.length + 1, (index) => index);
  for (var i = 1; i <= expected.length; i++) {
    final current = List<int>.filled(actual.length + 1, 0)..[0] = i;
    for (var j = 1; j <= actual.length; j++) {
      final substitution =
          previous[j - 1] + (expected[i - 1] == actual[j - 1] ? 0 : 1);
      current[j] = [
        previous[j] + 1,
        current[j - 1] + 1,
        substitution,
      ].reduce((a, b) => a < b ? a : b);
    }
    previous = current;
  }
  return previous[actual.length] / expected.length;
}

String? _file(String key) {
  final value = Platform.environment[key];
  if (value == null || value.isEmpty) return null;
  if (!File(value).existsSync()) {
    throw StateError('$key does not exist.');
  }
  return value;
}
