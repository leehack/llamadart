import 'dart:async';
import 'dart:io';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart_basic_example/services/image_cli_options.dart';

Future<void> main(List<String> arguments) async {
  final parser = createImageArgParser();
  final ImageCliOptions options;
  try {
    final results = parser.parse(arguments);
    if (results['help'] as bool) {
      stdout.write(buildImageHelpText(parser));
      return;
    }
    options = parseImageCliOptions(results);
  } on FormatException catch (error) {
    stderr
      ..writeln(error.message)
      ..writeln()
      ..writeln(parser.usage);
    exitCode = 64;
    return;
  }

  final runtime = await ImageGenerationEngine.checkRuntime();
  if (!runtime.isSupported) {
    stderr.writeln(
      'Image generation is unavailable: ${runtime.unsupportedReason}',
    );
    exitCode = 2;
    return;
  }

  final downloads = DefaultModelDownloadManager();
  ImageGenerationEngine? engine;
  StreamSubscription<ProcessSignal>? interrupt;
  try {
    final modelPath = await _resolve(downloads, options.modelSource, 'model');
    final taesdSource = options.taesdSource;
    final taesdPath = taesdSource == null
        ? null
        : await _resolve(downloads, taesdSource, 'TAESD');

    print('Loading ${options.preset.flag}...');
    final loadTimer = Stopwatch()..start();
    engine = await ImageGenerationEngine.load(
      options.model(modelPath, taesdPath),
      options: ImageGenerationOptions(
        device: options.device,
        threads: options.threads,
      ),
    );
    final capabilities = engine.capabilities;
    print(
      'Loaded ${capabilities.modelVersion} on ${capabilities.backendName} '
      'in ${loadTimer.elapsedMilliseconds} ms.',
    );

    final task = engine.generate(options.request);
    interrupt = ProcessSignal.sigint.watch().listen((_) {
      stdout.writeln('\nCancelling...');
      task.cancel();
    });

    await for (final event in task.events) {
      switch (event) {
        case ImageGenerationProgressEvent(
          :final phase,
          :final step,
          :final steps,
          :final imageIndex,
          :final imageCount,
        ):
          final image = imageCount > 1 ? ' image ${imageIndex + 1}' : '';
          stdout.write('\r${phase.name}$image $step/$steps\x1B[K');
        case ImageGenerationFinalEvent(:final result):
          stdout.writeln();
          for (final (index, image) in result.images.indexed) {
            final path = options.outputPathFor(index);
            File(path).writeAsBytesSync(image.toPng());
            print(
              'Wrote $path (${image.width}x${image.height}, seed '
              '${result.seed + index}).',
            );
          }
          print('Generated in ${result.elapsed.inMilliseconds} ms.');
      }
    }
    if ((await task.done).state == ImageGenerationCompletionState.cancelled) {
      print('Cancelled.');
      exitCode = 130;
    }
  } on LlamaUnsupportedException catch (error) {
    stderr.writeln('\nCannot generate images here: ${error.message}');
    exitCode = 2;
  } on LlamaException catch (error) {
    stderr.writeln('\nError: ${error.message}');
    exitCode = 1;
  } catch (error) {
    stderr.writeln('\nError: $error');
    exitCode = 1;
  } finally {
    await interrupt?.cancel();
    await engine?.dispose();
  }
}

Future<String> _resolve(
  DefaultModelDownloadManager downloads,
  ModelSource source,
  String label,
) async {
  if (source.isLocal) {
    return source.path!;
  }
  print('Fetching $label ${source.displayName}...');
  final entry = await downloads.ensureModel(
    source,
    onProgress: (progress) {
      final fraction = progress.fraction;
      stdout.write(
        fraction == null
            ? '\r${progress.receivedBytes ~/ 1048576} MB'
            : '\r${(fraction * 100).toStringAsFixed(0)}%',
      );
    },
  );
  stdout.writeln();
  return entry.filePath;
}
