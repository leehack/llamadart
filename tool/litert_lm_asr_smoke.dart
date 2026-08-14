import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:llamadart/llamadart.dart';

const int _sampleRateHz = 16000;
const int _pushSamples = _sampleRateHz ~/ 10;

Future<void> main(List<String> args) async {
  if (args.length < 5) {
    stderr.writeln(
      'Usage: dart run tool/litert_lm_asr_smoke.dart '
      '<model.tflite> <tokenizer.json> <audio.wav> '
      '<moonshine-tiny|parakeet-tdt|parakeet-ctc|whisper-tiny|qwen3-asr> '
      '<expected transcript substring>',
    );
    exitCode = 64;
    return;
  }

  final modelPath = args[0];
  final tokenizerPath = args[1];
  final audioPath = args[2];
  final preset = _parsePreset(args[3]);
  final expected = args[4].trim();
  if (expected.isEmpty) {
    throw ArgumentError.value(args[4], 'expected', 'must not be empty');
  }

  final fixture = await _readPcm16MonoWav(audioPath);
  final libraryPath = Platform.environment['LLAMADART_LITERT_LM_LIBRARY_PATH']
      ?.trim();
  final client = LiteRtLmRuntimeClient(
    libraryPath: libraryPath == null || libraryPath.isEmpty
        ? null
        : libraryPath,
  );
  final stopwatch = Stopwatch()..start();
  LiteRtLmAsrRuntimeSession? session;
  try {
    if (!client.supportsAsrBridge) {
      throw StateError(
        'The loaded LiteRT-LM runtime does not expose the dedicated ASR bridge.',
      );
    }
    session = client.createAsrSession(
      LiteRtLmAsrRuntimeConfig(
        modelPath: modelPath,
        tokenizerPath: tokenizerPath,
        modelPreset: preset,
      ),
    );
    final transcript = _transcribe(session, fixture.samples);
    stopwatch.stop();
    final normalizedTranscript = _normalize(transcript);
    final normalizedExpected = _normalize(expected);
    if (!normalizedTranscript.contains(normalizedExpected)) {
      throw StateError(
        'LiteRT-LM ASR transcript mismatch: expected a transcript containing '
        '"$normalizedExpected", received "$normalizedTranscript".',
      );
    }
    print(
      'RESULT litert_lm_asr ${jsonEncode(<String, Object>{'modelPreset': preset.name, 'backend': LiteRtLmAsrBackend.cpu.name, 'sampleRateHz': _sampleRateHz, 'sampleCount': fixture.samples.length, 'fixtureId': fixture.fixtureId, 'elapsedMilliseconds': stopwatch.elapsedMilliseconds, 'transcript': transcript})}',
    );
  } finally {
    session?.dispose();
    client.dispose();
  }
}

String _transcribe(LiteRtLmAsrRuntimeSession session, Float32List samples) {
  final confirmed = <String>[];
  var offset = 0;
  var finalSeen = false;

  while (offset < samples.length) {
    final end = math.min(offset + _pushSamples, samples.length);
    final chunk = Float32List.sublistView(samples, offset, end);
    final push = session.pushAudio(chunk);
    if (push.acceptedSamples == 0) {
      if (!push.wouldBlock) {
        throw StateError(
          'LiteRT-LM ASR accepted no audio without backpressure.',
        );
      }
      final state = _processAvailable(session, confirmed);
      if (state == LiteRtLmAsrProcessState.needsMoreAudio) {
        throw StateError(
          'LiteRT-LM ASR reported backpressure but could not process a window.',
        );
      }
      finalSeen = state == LiteRtLmAsrProcessState.endOfStream;
      continue;
    }
    offset += push.acceptedSamples;
    final state = _processAvailable(session, confirmed);
    if (state == LiteRtLmAsrProcessState.endOfStream) {
      finalSeen = true;
      break;
    }
  }

  if (!finalSeen) {
    session.finishAudio();
    for (var attempt = 0; attempt < 10000; attempt++) {
      final result = session.processNext();
      if (result.state == LiteRtLmAsrProcessState.endOfStream) {
        finalSeen = true;
        break;
      }
      if (result.state == LiteRtLmAsrProcessState.needsMoreAudio) {
        throw StateError(
          'LiteRT-LM ASR requested more audio after input finalization.',
        );
      }
      _appendConfirmed(confirmed, result.confirmedText);
      if (result.isFinal) {
        finalSeen = true;
        break;
      }
    }
  }
  if (!finalSeen) {
    throw StateError('LiteRT-LM ASR did not produce a final result.');
  }
  return confirmed.join(' ').trim();
}

LiteRtLmAsrProcessState _processAvailable(
  LiteRtLmAsrRuntimeSession session,
  List<String> confirmed,
) {
  for (var attempt = 0; attempt < 10000; attempt++) {
    final result = session.processNext();
    if (result.state != LiteRtLmAsrProcessState.update) {
      return result.state;
    }
    _appendConfirmed(confirmed, result.confirmedText);
    if (result.isFinal) {
      return LiteRtLmAsrProcessState.endOfStream;
    }
  }
  throw StateError('LiteRT-LM ASR processing did not quiesce.');
}

void _appendConfirmed(List<String> confirmed, String value) {
  final normalized = value.trim();
  if (normalized.isNotEmpty) {
    confirmed.add(normalized);
  }
}

LiteRtLmAsrModelPreset _parsePreset(String value) {
  return switch (value.trim().toLowerCase()) {
    'moonshine-tiny' => LiteRtLmAsrModelPreset.moonshineTiny,
    'parakeet-tdt' => LiteRtLmAsrModelPreset.parakeetTdt0_6bV3,
    'parakeet-ctc' => LiteRtLmAsrModelPreset.parakeetCtc0_6b,
    'whisper-tiny' => LiteRtLmAsrModelPreset.whisperTiny,
    'qwen3-asr' => LiteRtLmAsrModelPreset.qwen3Asr0_6b,
    _ => throw ArgumentError.value(value, 'preset', 'is not supported'),
  };
}

String _normalize(String value) =>
    value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

Future<_WavFixture> _readPcm16MonoWav(String filePath) async {
  final bytes = await File(filePath).readAsBytes();
  if (bytes.length < 44 ||
      ascii.decode(bytes.sublist(0, 4), allowInvalid: true) != 'RIFF' ||
      ascii.decode(bytes.sublist(8, 12), allowInvalid: true) != 'WAVE') {
    throw FormatException('ASR smoke fixture must be a RIFF/WAVE file.');
  }
  final data = ByteData.sublistView(bytes);
  int? audioFormat;
  int? channels;
  int? sampleRate;
  int? bitsPerSample;
  Uint8List? pcm;
  var offset = 12;
  while (offset + 8 <= bytes.length) {
    final chunkId = ascii.decode(
      bytes.sublist(offset, offset + 4),
      allowInvalid: true,
    );
    final chunkLength = data.getUint32(offset + 4, Endian.little);
    final chunkStart = offset + 8;
    final chunkEnd = chunkStart + chunkLength;
    if (chunkEnd > bytes.length) {
      throw FormatException('ASR smoke WAV contains a truncated chunk.');
    }
    if (chunkId == 'fmt ' && chunkLength >= 16) {
      audioFormat = data.getUint16(chunkStart, Endian.little);
      channels = data.getUint16(chunkStart + 2, Endian.little);
      sampleRate = data.getUint32(chunkStart + 4, Endian.little);
      bitsPerSample = data.getUint16(chunkStart + 14, Endian.little);
    } else if (chunkId == 'data') {
      pcm = Uint8List.sublistView(bytes, chunkStart, chunkEnd);
    }
    offset = chunkEnd + (chunkLength.isOdd ? 1 : 0);
  }
  if (audioFormat != 1 ||
      channels != 1 ||
      sampleRate != _sampleRateHz ||
      bitsPerSample != 16 ||
      pcm == null ||
      pcm.isEmpty ||
      pcm.length.isOdd) {
    throw FormatException(
      'ASR smoke fixture must contain nonempty mono 16 kHz PCM16 audio.',
    );
  }
  final pcmData = ByteData.sublistView(pcm);
  final samples = Float32List(pcm.length ~/ 2);
  for (var index = 0; index < samples.length; index++) {
    samples[index] = pcmData.getInt16(index * 2, Endian.little) / 32768.0;
  }
  return _WavFixture(
    samples: samples,
    fixtureId: 'sha256:${sha256.convert(bytes)}',
  );
}

class _WavFixture {
  const _WavFixture({required this.samples, required this.fixtureId});

  final Float32List samples;
  final String fixtureId;
}
