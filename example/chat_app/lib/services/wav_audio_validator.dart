import 'dart:math' as math;
import 'dart:typed_data';

/// Signal metadata extracted from a mono or interleaved PCM16 WAV file.
typedef WavPcm16Signal = ({
  int sampleRate,
  int channels,
  int sampleFrames,
  int peakAmplitude,
  double rmsAmplitude,
  double durationSeconds,
});

/// Returns whether [bytes] contain a RIFF/WAVE file with nonempty audio data.
bool wavBytesHaveAudioData(Uint8List bytes) {
  final fileLength = bytes.length;
  if (fileLength < 20 ||
      bytes[0] != 0x52 ||
      bytes[1] != 0x49 ||
      bytes[2] != 0x46 ||
      bytes[3] != 0x46 ||
      bytes[8] != 0x57 ||
      bytes[9] != 0x41 ||
      bytes[10] != 0x56 ||
      bytes[11] != 0x45) {
    return false;
  }

  var offset = 12;
  while (offset + 8 <= fileLength) {
    final chunkHeader = Uint8List.sublistView(bytes, offset, offset + 8);
    final chunkSize = ByteData.sublistView(
      chunkHeader,
    ).getUint32(4, Endian.little);
    final payloadOffset = offset + 8;
    final isDataChunk =
        chunkHeader[0] == 0x64 &&
        chunkHeader[1] == 0x61 &&
        chunkHeader[2] == 0x74 &&
        chunkHeader[3] == 0x61;
    if (isDataChunk) {
      return chunkSize > 0 && fileLength - payloadOffset >= chunkSize;
    }

    final paddedChunkSize = chunkSize + (chunkSize.isOdd ? 1 : 0);
    final nextOffset = payloadOffset + paddedChunkSize;
    if (nextOffset <= offset || nextOffset > fileLength) {
      return false;
    }
    offset = nextOffset;
  }
  return false;
}

/// Inspects PCM16 signal levels without retaining raw microphone samples.
///
/// Returns `null` for unsupported or malformed WAV encodings. The browser
/// recorder uses PCM16, so callers can distinguish a valid container from a
/// capture that is too short or effectively silent before invoking ASR.
WavPcm16Signal? inspectPcm16WavSignal(Uint8List bytes) {
  final layout = _parsePcm16Wav(bytes);
  if (layout == null) {
    return null;
  }

  final data = ByteData.sublistView(bytes);
  var peak = 0;
  var sumSquares = 0.0;
  final sampleCount = layout.dataLength ~/ 2;
  for (var index = 0; index < sampleCount; index += 1) {
    final sample = data.getInt16(layout.dataOffset + index * 2, Endian.little);
    final magnitude = sample.abs();
    if (magnitude > peak) {
      peak = magnitude;
    }
    sumSquares += sample * sample;
  }

  final sampleFrames = sampleCount ~/ layout.channels;
  return (
    sampleRate: layout.sampleRate,
    channels: layout.channels,
    sampleFrames: sampleFrames,
    peakAmplitude: peak,
    rmsAmplitude: sampleCount == 0 ? 0 : math.sqrt(sumSquares / sampleCount),
    durationSeconds: sampleFrames / layout.sampleRate,
  );
}

/// Removes leading and trailing quiet frames from a PCM16 WAV recording.
///
/// Browser capture starts before the UI reports that the microphone is ready,
/// so a short warmup interval is expected. The adaptive threshold preserves
/// quiet speech while removing that warmup and trailing device silence.
Uint8List? trimPcm16WavSilence(
  Uint8List bytes, {
  WavPcm16Signal? signal,
  int minimumAmplitude = 96,
  double relativePeakFraction = 0.05,
}) {
  final layout = _parsePcm16Wav(bytes);
  final measuredSignal = signal ?? inspectPcm16WavSignal(bytes);
  if (layout == null || measuredSignal == null) {
    return null;
  }

  final relativeThreshold =
      (measuredSignal.peakAmplitude * relativePeakFraction).round();
  final threshold = math.max(minimumAmplitude, relativeThreshold);
  final data = ByteData.sublistView(bytes);
  final activityWindowFrames = math.max(1, measuredSignal.sampleRate ~/ 50);
  // Preserve enough context for soft initial and final phonemes around the
  // first/last active windows. A very small boundary made short browser
  // utterances more likely to lose consonant transitions before ASR.
  final boundaryPaddingFrames = measuredSignal.sampleRate ~/ 4;
  final usesWindowedActivity =
      measuredSignal.sampleFrames >= activityWindowFrames * 2;
  int? firstActiveFrame;
  int? lastActiveFrame;

  if (!usesWindowedActivity) {
    // Keep sample-level behavior for very short synthetic/test clips. Real
    // microphone recordings use windowed RMS below so isolated ambient spikes
    // cannot pin the speech boundary to the beginning or end of the capture.
    for (var frame = 0; frame < measuredSignal.sampleFrames; frame += 1) {
      var isActive = false;
      for (var channel = 0; channel < layout.channels; channel += 1) {
        final sampleIndex = frame * layout.channels + channel;
        final sample = data.getInt16(
          layout.dataOffset + sampleIndex * 2,
          Endian.little,
        );
        if (sample.abs() >= threshold) {
          isActive = true;
          break;
        }
      }
      if (isActive) {
        firstActiveFrame ??= frame;
        lastActiveFrame = frame;
      }
    }
  } else {
    for (
      var windowStart = 0;
      windowStart < measuredSignal.sampleFrames;
      windowStart += activityWindowFrames
    ) {
      final windowEnd = math.min(
        measuredSignal.sampleFrames,
        windowStart + activityWindowFrames,
      );
      var sumSquares = 0.0;
      var sampleCount = 0;
      for (var frame = windowStart; frame < windowEnd; frame += 1) {
        for (var channel = 0; channel < layout.channels; channel += 1) {
          final sampleIndex = frame * layout.channels + channel;
          final sample = data.getInt16(
            layout.dataOffset + sampleIndex * 2,
            Endian.little,
          );
          sumSquares += sample * sample;
          sampleCount += 1;
        }
      }
      final windowRms = sampleCount == 0
          ? 0
          : math.sqrt(sumSquares / sampleCount);
      if (windowRms >= threshold) {
        firstActiveFrame ??= windowStart;
        lastActiveFrame = windowEnd - 1;
      }
    }
  }

  if (firstActiveFrame == null || lastActiveFrame == null) {
    return null;
  }
  if (usesWindowedActivity) {
    firstActiveFrame = math.max(0, firstActiveFrame - boundaryPaddingFrames);
    lastActiveFrame = math.min(
      measuredSignal.sampleFrames - 1,
      lastActiveFrame + boundaryPaddingFrames,
    );
  }
  if (firstActiveFrame == 0 &&
      lastActiveFrame == measuredSignal.sampleFrames - 1) {
    return bytes;
  }

  final bytesPerFrame = layout.channels * 2;
  final firstByte = layout.dataOffset + firstActiveFrame * bytesPerFrame;
  final audioByteLength =
      (lastActiveFrame - firstActiveFrame + 1) * bytesPerFrame;
  final trimmed = Uint8List(44 + audioByteLength);
  final trimmedData = ByteData.sublistView(trimmed);

  void writeAscii(int offset, String value) {
    for (var index = 0; index < value.length; index += 1) {
      trimmed[offset + index] = value.codeUnitAt(index);
    }
  }

  writeAscii(0, 'RIFF');
  trimmedData.setUint32(4, trimmed.length - 8, Endian.little);
  writeAscii(8, 'WAVE');
  writeAscii(12, 'fmt ');
  trimmedData.setUint32(16, 16, Endian.little);
  trimmedData.setUint16(20, 1, Endian.little);
  trimmedData.setUint16(22, layout.channels, Endian.little);
  trimmedData.setUint32(24, layout.sampleRate, Endian.little);
  trimmedData.setUint32(28, layout.sampleRate * bytesPerFrame, Endian.little);
  trimmedData.setUint16(32, bytesPerFrame, Endian.little);
  trimmedData.setUint16(34, 16, Endian.little);
  writeAscii(36, 'data');
  trimmedData.setUint32(40, audioByteLength, Endian.little);
  trimmed.setRange(44, trimmed.length, bytes, firstByte);
  return trimmed;
}

final class _Pcm16WavLayout {
  const _Pcm16WavLayout({
    required this.sampleRate,
    required this.channels,
    required this.dataOffset,
    required this.dataLength,
  });

  final int sampleRate;
  final int channels;
  final int dataOffset;
  final int dataLength;
}

_Pcm16WavLayout? _parsePcm16Wav(Uint8List bytes) {
  if (!wavBytesHaveAudioData(bytes)) {
    return null;
  }

  final fileLength = bytes.length;
  final data = ByteData.sublistView(bytes);
  int? sampleRate;
  int? channels;
  int? dataOffset;
  int? dataLength;
  var isPcm16 = false;
  var offset = 12;
  while (offset + 8 <= fileLength) {
    final chunkSize = data.getUint32(offset + 4, Endian.little);
    final payloadOffset = offset + 8;
    if (payloadOffset + chunkSize > fileLength) {
      return null;
    }

    final chunkId = String.fromCharCodes(bytes.sublist(offset, offset + 4));
    if (chunkId == 'fmt ' && chunkSize >= 16) {
      final audioFormat = data.getUint16(payloadOffset, Endian.little);
      channels = data.getUint16(payloadOffset + 2, Endian.little);
      sampleRate = data.getUint32(payloadOffset + 4, Endian.little);
      final bitsPerSample = data.getUint16(payloadOffset + 14, Endian.little);
      isPcm16 = audioFormat == 1 && bitsPerSample == 16;
    } else if (chunkId == 'data') {
      dataOffset = payloadOffset;
      dataLength = chunkSize;
    }

    final paddedChunkSize = chunkSize + (chunkSize.isOdd ? 1 : 0);
    offset = payloadOffset + paddedChunkSize;
  }

  if (!isPcm16 ||
      sampleRate == null ||
      sampleRate <= 0 ||
      channels == null ||
      channels <= 0 ||
      dataOffset == null ||
      dataLength == null ||
      dataLength < channels * 2) {
    return null;
  }
  return _Pcm16WavLayout(
    sampleRate: sampleRate,
    channels: channels,
    dataOffset: dataOffset,
    dataLength: dataLength,
  );
}
