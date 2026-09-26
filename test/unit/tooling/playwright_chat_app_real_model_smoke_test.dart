@TestOn('vm')
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _script = 'tool/testing/playwright_chat_app_real_model_smoke.py';
const _playwrightReached = 'fake playwright reached';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('llamadart-smoke-args-');
    final package = Directory(p.join(tempDir.path, 'playwright'));
    await package.create();
    await File(p.join(package.path, '__init__.py')).writeAsString('');
    await File(p.join(package.path, 'sync_api.py')).writeAsString(
      'class TimeoutError(Exception):\n'
      '    pass\n'
      '\n'
      'def sync_playwright():\n'
      '    raise SystemExit("$_playwrightReached")\n',
    );
  });

  tearDown(() => tempDir.delete(recursive: true));

  Future<ProcessResult> runSmoke(String audioName, {bool microphone = false}) {
    final audio = File(p.join(tempDir.path, audioName))
      ..writeAsBytesSync(const <int>[0]);
    return Process.run(
      Platform.isWindows ? 'python' : 'python3',
      [
        _script,
        'http://127.0.0.1:1/',
        '--model-url',
        'http://127.0.0.1:1/model.gguf',
        '--mmproj-url',
        'http://127.0.0.1:1/mmproj.gguf',
        '--speech-audio-path',
        audio.path,
        if (microphone) '--speech-microphone',
        '--expect',
        'Known transcript.',
      ],
      environment: {'PYTHONPATH': tempDir.path},
    );
  }

  for (final name in ['speech.wav', 'speech.mp3', 'speech.FLAC']) {
    test('accepts a $name selected-file fixture', () async {
      final result = await runSmoke(name);

      expect(result.stderr, contains(_playwrightReached));
    });
  }

  test('rejects other selected-file encodings', () async {
    final result = await runSmoke('speech.ogg');

    expect(result.exitCode, 2);
    expect(
      result.stderr,
      contains('--speech-audio-path must be a WAV, MP3 or FLAC file'),
    );
  });

  test('requires a WAV for the fake microphone', () async {
    final result = await runSmoke('speech.mp3', microphone: true);

    expect(result.exitCode, 2);
    expect(
      result.stderr,
      contains('--speech-microphone requires a WAV --speech-audio-path'),
    );
  });
}
