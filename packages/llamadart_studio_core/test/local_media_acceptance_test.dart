@Tags(<String>['local-only'])
library;

import 'dart:io';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:test/test.dart';

String? _path(String key) => Platform.environment['STUDIO_ACCEPTANCE_$key'];
ResolvedModelAssets _assets(String id, String model, {String? projector}) =>
    ResolvedModelAssets(
      descriptor: CuratedModelCatalog.byId(id)!,
      primarySource: ModelSource.parse(model),
      companionSources: <String, ModelSource>{
        if (projector != null) 'projector': ModelSource.parse(projector),
      },
    );

void main() {
  test(
    'real Qwen ASR transcribes a known file',
    () async {
      final port = DirectLlamaSpeechPort();
      addTearDown(port.dispose);
      final caps = await port.loadSttModel(
        assets: _assets(
          'qwen3-asr-0.6b-q8-0',
          _path('ASR_MODEL')!,
          projector: _path('ASR_PROJECTOR')!,
        ),
        isWeb: false,
      );
      expect(caps.isSupported, isTrue, reason: caps.unsupportedReason);
      final result = await port.transcribe(audioFilePath: _path('AUDIO'));
      expect(result.text.toLowerCase(), contains('ask not what your country'));
      print(
        'REAL_STUDIO_ASR text=${result.text} elapsedMs=${result.elapsedMs}',
      );
    },
    skip:
        _path('ASR_MODEL') == null ||
        _path('ASR_PROJECTOR') == null ||
        _path('AUDIO') == null,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'real Qwen TTS synthesizes PCM WAV',
    () async {
      final port = DirectLlamaSpeechPort();
      addTearDown(port.dispose);
      // The local 0.6B pack uses the same Qwen3 adapter and preset as curated1.7B.
      final caps = await port.loadTtsModel(
        assets: _assets(
          'qwen3-tts-1.7b-base-q4-k-m',
          _path('TTS_MODEL')!,
          projector: _path('TTS_PROJECTOR')!,
        ),
        isWeb: false,
      );
      expect(caps.isSupported, isTrue, reason: caps.unsupportedReason);
      final result = await port.synthesize(
        text: 'Hello.',
        isWeb: false,
        language: 'English',
        temperature: 0,
        speakerReferencePath: _path('AUDIO'),
      );
      expect(result.wavBytes.take(4), <int>[82, 73, 70, 70]);
      expect(result.wavBytes.length, greaterThan(44));
      expect(result.duration.inMilliseconds, greaterThan(0));
      expect(result.framesGenerated, greaterThan(0));
      expect(result.truncated, isFalse);
      expect(result.wavBytes.skip(44).any((byte) => byte != 0), isTrue);
      final output = _path('TTS_OUTPUT');
      if (output != null) await File(output).writeAsBytes(result.wavBytes);
      if (_path('ASR_MODEL') != null && _path('ASR_PROJECTOR') != null) {
        await port.loadSttModel(
          assets: _assets(
            'qwen3-asr-0.6b-q8-0',
            _path('ASR_MODEL')!,
            projector: _path('ASR_PROJECTOR')!,
          ),
          isWeb: false,
        );
        final transcript = await port.transcribe(audioBytes: result.wavBytes);
        print('REAL_STUDIO_TTS_ROUNDTRIP text=${transcript.text}');
        expect(transcript.text.toLowerCase(), contains('hello'));
      }
      print(
        'REAL_STUDIO_TTS durationMs=${result.duration.inMilliseconds} '
        'frames=${result.framesGenerated} bytes=${result.wavBytes.length}',
      );
    },
    skip:
        _path('TTS_MODEL') == null ||
        _path('TTS_PROJECTOR') == null ||
        _path('AUDIO') == null,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
