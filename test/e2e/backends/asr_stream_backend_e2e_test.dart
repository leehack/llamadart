@TestOn('vm')
@Tags(['local-only'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/backends/llama_cpp/llama_cpp_backend.dart';
import 'package:test/test.dart';

const String _lfm3Model =
    '/opt/UnitySrc/personal/llama/models/lfm3-audio-2b-02355c1a/LFM3-Audio-2B-Q4_K_M.gguf';
const String _lfm3Mmproj =
    '/opt/UnitySrc/personal/llama/models/lfm3-audio-2b-02355c1a/mmproj-LFM3-Audio-2B-Q8_0.gguf';
const String _voxtralModel =
    '/opt/UnitySrc/personal/llama/models/voxtral-mini-4b-realtime-0b0f7ac9/Voxtral-Mini-4B-Realtime-2602-Q4_K_M.gguf';
const String _voxtralMmproj =
    '/opt/UnitySrc/personal/llama/models/voxtral-mini-4b-realtime-0b0f7ac9/mmproj-Voxtral-Mini-4B-Realtime-2602-Q8_0.gguf';
const String _jfkWav = 'packages/llamadart_validation/assets/speech/jfk.wav';

Float32List _decodeWavPcm16Mono16k(String path) {
  final bytes = File(path).readAsBytesSync();
  final data = ByteData.sublistView(bytes);
  var offset = 12;
  while (offset + 8 <= bytes.length) {
    final chunkId = String.fromCharCodes(bytes.sublist(offset, offset + 4));
    final chunkSize = data.getUint32(offset + 4, Endian.little);
    offset += 8;
    if (chunkId == 'data') {
      final sampleCount = chunkSize ~/ 2;
      final pcm = Float32List(sampleCount);
      for (var i = 0; i < sampleCount; i++) {
        pcm[i] = data.getInt16(offset + i * 2, Endian.little) / 32768.0;
      }
      return pcm;
    }
    offset += chunkSize + (chunkSize.isOdd ? 1 : 0);
  }
  throw StateError('No WAV data chunk found in $path');
}

void main() {
  final jfkExists = File(_jfkWav).existsSync();

  test(
    'LFM3-Audio real model streams JFK at 2048 floor on NativeLlamaBackend',
    () async {
      final backend = NativeLlamaBackend();
      try {
        final model = await backend.modelLoad(
          _lfm3Model,
          const ModelParams(
            contextSize: 2048,
            numberOfThreads: 2,
            numberOfThreadsBatch: 2,
          ),
        );
        final ctx = await backend.contextCreate(
          model,
          const ModelParams(
            contextSize: 2048,
            numberOfThreads: 2,
            numberOfThreadsBatch: 2,
          ),
        );
        final mm = (await backend.multimodalContextCreate(model, _lfm3Mmproj))!;

        expect(await backend.probeAsrStreamUnsupportedReason(ctx, mm), isNull);

        final pcm = _decodeWavPcm16Mono16k(_jfkWav);
        final session = await backend.startAsrStreamSession(ctx, mm);
        final partials = <String>[];
        final sub = session.updates.listen(
          (u) => partials.add(u.confirmedText),
        );
        try {
          for (var i = 0; i < pcm.length; i += 5120) {
            final end = (i + 5120 < pcm.length) ? i + 5120 : pcm.length;
            await session.pushAudio(Float32List.sublistView(pcm, i, end));
          }
          final finalText = await session.finish();
          expect(finalText.toLowerCase(), contains('fellow americans'));
          for (var i = 1; i < partials.length; i++) {
            expect(partials[i].startsWith(partials[i - 1]), isTrue);
          }
        } finally {
          await sub.cancel();
        }
      } finally {
        await backend.dispose();
      }
    },
    skip:
        !(jfkExists &&
            File(_lfm3Model).existsSync() &&
            File(_lfm3Mmproj).existsSync()),
  );

  test(
    'Voxtral Realtime real model streams JFK at 512 context on NativeLlamaBackend',
    () async {
      final backend = NativeLlamaBackend();
      try {
        final model = await backend.modelLoad(
          _voxtralModel,
          const ModelParams(
            contextSize: 512,
            numberOfThreads: 2,
            numberOfThreadsBatch: 2,
          ),
        );
        final ctx = await backend.contextCreate(
          model,
          const ModelParams(
            contextSize: 512,
            numberOfThreads: 2,
            numberOfThreadsBatch: 2,
          ),
        );
        final mm = (await backend.multimodalContextCreate(
          model,
          _voxtralMmproj,
        ))!;

        expect(await backend.probeAsrStreamUnsupportedReason(ctx, mm), isNull);

        final pcm = _decodeWavPcm16Mono16k(_jfkWav);
        final session = await backend.startAsrStreamSession(ctx, mm);
        final partials = <String>[];
        final sub = session.updates.listen(
          (u) => partials.add(u.confirmedText),
        );
        try {
          for (var i = 0; i < pcm.length; i += 5120) {
            final end = (i + 5120 < pcm.length) ? i + 5120 : pcm.length;
            await session.pushAudio(Float32List.sublistView(pcm, i, end));
          }
          final finalText = await session.finish();
          expect(finalText.toLowerCase(), contains('fellow americans'));
          for (var i = 1; i < partials.length; i++) {
            expect(partials[i].startsWith(partials[i - 1]), isTrue);
          }
        } finally {
          await sub.cancel();
        }

        // Verify cancel while idle on a second session
        final session2 = await backend.startAsrStreamSession(ctx, mm);
        await session2.cancel();
      } finally {
        await backend.dispose();
      }
    },
    skip:
        !(jfkExists &&
            File(_voxtralModel).existsSync() &&
            File(_voxtralMmproj).existsSync()),
  );
}
