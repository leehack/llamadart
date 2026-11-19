import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:llamadart/llamadart.dart';

import 'src/live_asr_pcm.dart';

Future<void> main(List<String> arguments) async {
  var qwenWindowed = false;
  final positional = <String>[];
  for (final arg in arguments) {
    if (arg == '--qwen-windowed') {
      qwenWindowed = true;
    } else {
      positional.add(arg);
    }
  }
  if (positional.length != 3) {
    stderr.writeln(
      'Usage: dart run bin/llamadart_live_asr_example.dart '
      '[--qwen-windowed] <model.gguf> <mmproj.gguf> <audio.f32le|->',
    );
    exitCode = 64;
    return;
  }

  final modelSource = ModelSource.parse(positional[0]);
  final projectorSource = ModelSource.parse(positional[1]);
  final audioFile = positional[2] == '-' ? null : File(positional[2]);
  if (audioFile != null && !await audioFile.exists()) {
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
        adapter: qwenWindowed
            ? const Qwen3WindowedAsrAdapter()
            : const LlamaCppLiveAsrAdapter(),
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
    var confirmedPrintedLength = 0;
    var lastPending = '';
    final events = session.events.listen(
      (event) {
        switch (event) {
          case SpeechToTextPartialEvent(
            :final text,
            :final confirmedText,
            :final pendingText,
          ):
            final confirmed = confirmedText ?? text;
            final pending = pendingText ?? '';
            if (confirmed.length > confirmedPrintedLength) {
              if (stdout.hasTerminal && lastPending.isNotEmpty) {
                stdout.write('\r\x1b[K');
              }
              lastPending = '';
              final delta = confirmed.substring(confirmedPrintedLength);
              if (qwenWindowed) {
                final trimmed = delta.trimLeft();
                if (trimmed.isNotEmpty) {
                  stdout.writeln(trimmed);
                }
              } else {
                stdout.write(delta);
              }
              confirmedPrintedLength = confirmed.length;
            }
            if (pending.isNotEmpty && pending != lastPending) {
              if (stdout.hasTerminal) {
                stdout.write('\r\x1b[K[pending] $pending');
              } else {
                stdout.writeln('[pending] $pending');
              }
              lastPending = pending;
            }
          case SpeechToTextFinalEvent(:final result):
            if (stdout.hasTerminal && lastPending.isNotEmpty) {
              stdout.write('\r\x1b[K');
            }
            lastPending = '';
            if (result.text.length > confirmedPrintedLength) {
              final tail = result.text.substring(confirmedPrintedLength);
              stdout.writeln(qwenWindowed ? tail.trimLeft() : tail);
              confirmedPrintedLength = result.text.length;
            } else if (!qwenWindowed || confirmedPrintedLength == 0) {
              stdout.writeln();
            }
        }
      },
      onError: (Object error) {
        stderr.writeln('\nError: $error');
      },
    );
    final input = StreamIterator<Float32List>(
      readLiveAsrPcm(audioFile?.openRead() ?? stdin),
    );
    var cancelled = false;
    interrupt = ProcessSignal.sigint.watch().listen((_) {
      cancelled = true;
      unawaited(session.cancel());
      unawaited(input.cancel());
    });

    try {
      if (audioFile == null) {
        stderr.writeln('Ready for mono 16 kHz f32le PCM on stdin.');
      }
      try {
        while (!cancelled && await input.moveNext()) {
          if (!cancelled) {
            await session.addPcm(input.current);
          }
        }
        if (!cancelled) {
          await session.finish();
        }
      } on LlamaException {
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
      await input.cancel();
      await session.cancel();
      await events.cancel();
    }
  } finally {
    await interrupt?.cancel();
    await recognizer.dispose();
  }
}
