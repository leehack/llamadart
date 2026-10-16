@TestOn('vm')
@Tags(['local-only'])
library;

import 'dart:io';

import 'package:llamadart/llamadart.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  final source = Platform.environment['LLAMADART_LITERT_LM_SOURCE'];
  late Directory scratch;
  late String executable;

  setUpAll(() async {
    scratch = await Directory.systemTemp.createTemp('asr_overlap_');
    executable = p.join(scratch.path, 'asr_overlap');
    // The merger only uses LiteRT's status-assignment macro. Forward it to
    // Abseil so this model-free replay needs no LiteRT inference dependencies.
    final macros = File(p.join(scratch.path, 'litert/cc/litert_macros.h'));
    await macros.parent.create(recursive: true);
    await macros.writeAsString(
      '#include "absl/status/status_macros.h"\n'
      '#define LITERT_ASSIGN_OR_RETURN ABSL_ASSIGN_OR_RETURN\n',
    );
    final flags = await Process.run('pkg-config', [
      '--cflags',
      '--libs',
      'absl_statusor',
      'absl_synchronization',
      'absl_strings',
      'absl_log',
      'absl_vlog_is_on',
    ]);
    expect(flags.exitCode, 0, reason: '${flags.stderr}');
    final build = await Process.run(Platform.environment['CXX'] ?? 'c++', [
      '-std=c++17',
      '-I${scratch.path}',
      '-I$source',
      'test/fixtures/litert_lm/asr_overlap.cc',
      '$source/omni/asr/timestamp_text_merger.cc',
      '$source/omni/asr/levenshtein_align.cc',
      ...flags.stdout.toString().trim().split(RegExp(r'\s+')),
      '-o',
      executable,
    ]);
    expect(build.exitCode, 0, reason: '${build.stderr}');
  });
  tearDownAll(() => scratch.delete(recursive: true));

  Future<String> replay(double overlap, {bool single = false}) async {
    final result = await Process.run(executable, [
      '$overlap',
      single ? 'single' : 'overlap',
    ]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    return result.stdout.toString().trim();
  }

  group(
    'upstream Moonshine boundary replay',
    () {
      const expected =
          'And so my fellow Americans ask not. what your country '
          'can do for you, ask what you can do for your country.';
      const legacy = LiteRtLmAsrRuntimeConfig(
        modelPath: 'moonshine.tflite',
        tokenizerPath: 'tokenizer.json',
        modelPreset: LiteRtLmAsrModelPreset.moonshineTiny,
      );
      final config = LiteRtLmAsrRuntimeConfig.source(
        model: ModelSource.path('moonshine.tflite'),
        tokenizer: ModelSource.path('tokenizer.json'),
        modelPreset: LiteRtLmAsrModelPreset.moonshineTiny,
      );
      const adapter = LiteRtLmAsrAdapter(LiteRtLmAsrModelPreset.moonshineTiny);

      test('old overlap reproduces the duplicated fragment', () async {
        expect(
          await replay(0.4),
          'And so my fellow Americans ask not. what your country can do for '
          'you. tree can do for you, ask what you can do for your country.',
        );
      });

      for (final (name, overlap) in [
        ('legacy config', legacy.overlapRatio),
        ('source config', config.overlapRatio),
        ('adapter', adapter.overlapRatio),
      ]) {
        test('$name default removes the duplicated fragment', () async {
          expect(await replay(overlap), expected);
        });
      }

      test(
        'single-window text keeps legitimate repetitions byte for byte',
        () async {
          for (final overlap in [0.0, 0.4, adapter.overlapRatio]) {
            expect(
              await replay(overlap, single: true),
              'Go go, never never stop.',
            );
          }
        },
      );
    },
    skip: source == null ? 'Set LLAMADART_LITERT_LM_SOURCE to v0.18.0.' : false,
  );
}
