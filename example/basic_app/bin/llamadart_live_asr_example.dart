import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:llamadart/llamadart.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 3) {
    stderr.writeln(
      'Usage: dart run bin/llamadart_live_asr_example.dart '
      '<model.gguf> <mmproj.gguf> <audio.f32le>',
    );
    exitCode = 64;
    return;
  }

  final modelSource = ModelSource.parse(arguments[0]);
  final projectorSource = ModelSource.parse(arguments[1]);
  final audioFile = File(arguments[2]);
  if (!await audioFile.exists()) {
    stderr.writeln('Audio file not found: ${audioFile.path}');
    exitCode = 66;
    return;
  }

  final SpeechToTextEngine recognizer;
  try {
    recognizer = await SpeechToTextEngine.load(
      SpeechToTextModel(
        modelSource,
        projector: projectorSource,
        adapter: const LlamaCppLiveAsrAdapter(),
      ),
      params: const ModelParams(contextSize: 4096),
    );
  } on LlamaUnsupportedException catch (error) {
    stderr.writeln('Unsupported: ${error.message}');
    exitCode = 1;
    return;
  }

  StreamSubscription<ProcessSignal>? interrupt;
  try {
    final session = await recognizer.startStream();
    var printedLength = 0;
    final events = session.events.listen(
      (event) {
        switch (event) {
          case SpeechToTextPartialEvent(:final text):
            if (text.length > printedLength) {
              stdout.write(text.substring(printedLength));
              printedLength = text.length;
            }
          case SpeechToTextFinalEvent(:final result):
            if (result.text.length > printedLength) {
              stdout.write(result.text.substring(printedLength));
              printedLength = result.text.length;
            }
            stdout.writeln();
        }
      },
      onError: (Object error) {
        stderr.writeln('\nError: $error');
      },
    );
    var cancelled = false;
    interrupt = ProcessSignal.sigint.watch().listen((_) {
      cancelled = true;
      unawaited(session.cancel());
    });

    try {
      const chunkBytes =
          16000; // 4,000 mono float32 samples = 250 ms at 16 kHz.
      final carry = <int>[];
      try {
        await for (final rawChunk in audioFile.openRead()) {
          if (cancelled) {
            break;
          }
          if (rawChunk.isEmpty) {
            continue;
          }
          var offset = 0;
          if (carry.isNotEmpty) {
            final needed = 4 - carry.length;
            if (rawChunk.length < needed) {
              carry.addAll(rawChunk);
              continue;
            }
            carry.addAll(rawChunk.sublist(0, needed));
            await session.addPcm(_bytesToFloat32(Uint8List.fromList(carry)));
            carry.clear();
            offset = needed;
          }

          final remaining = rawChunk.length - offset;
          final alignedBytes = remaining - (remaining % 4);
          var sliceOffset = offset;
          while (sliceOffset < offset + alignedBytes) {
            if (cancelled) {
              break;
            }
            final sliceEnd = sliceOffset + chunkBytes < offset + alignedBytes
                ? sliceOffset + chunkBytes
                : offset + alignedBytes;
            final aligned = Uint8List.fromList(
              rawChunk.sublist(sliceOffset, sliceEnd),
            );
            await session.addPcm(_bytesToFloat32(aligned));
            sliceOffset = sliceEnd;
          }
          if (sliceOffset < rawChunk.length) {
            carry.addAll(rawChunk.sublist(sliceOffset));
          }
        }

        if (!cancelled) {
          if (carry.isNotEmpty) {
            throw FormatException(
              'Trailing ${carry.length} byte(s) in ${audioFile.path}; '
              'expected 4-byte aligned mono 16 kHz little-endian float32 PCM.',
            );
          }

          await session.finish();
        }
      } on LlamaStateException {
        if (!cancelled) {
          rethrow;
        }
      }
      final completion = await session.done;
      if (completion.state == SpeechToTextCompletionState.failed) {
        stderr.writeln('Failed: ${completion.error}');
        exitCode = 1;
      } else if (completion.state == SpeechToTextCompletionState.cancelled) {
        stderr.writeln('\nCancelled.');
        exitCode = 130;
      }
    } finally {
      await session.cancel();
      await events.cancel();
    }
  } finally {
    await interrupt?.cancel();
    await recognizer.dispose();
  }
}

Float32List _bytesToFloat32(Uint8List bytes) {
  final count = bytes.lengthInBytes ~/ 4;
  final data = ByteData.sublistView(bytes);
  final samples = Float32List(count);
  for (var i = 0; i < count; i++) {
    samples[i] = data.getFloat32(i * 4, Endian.little);
  }
  return samples;
}
