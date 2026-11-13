@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/bounded_process.dart';
import 'support/silent_wav.dart';

const _script = 'tool/testing/playwright_chat_app_microphone_lifecycle.py';

const _processTimeout = Duration(seconds: 60);

// Stands in for a browser. Each case's page changes from `before` to `after`
// when the script does what triggers the case: a click, or revoking the
// permission. The page answers the instrumentation snapshot from the scenario.
const _scriptedPlaywright = r'''
import json
import os

_SCENARIO = json.loads(os.environ["LLAMADART_FAKE_PLAYWRIGHT_SCENARIO"])
_STATE = {"case": None, "stage": "before"}
_CAPTURE = {"launches": [], "grants": []}


def _save():
    with open(_SCENARIO["capturePath"], "w", encoding="utf-8") as capture:
        json.dump(_CAPTURE, capture)


def _case():
    return _SCENARIO["cases"].get(_STATE["case"], {})


class TimeoutError(Exception):
    pass


class _Anything:
    def __getattr__(self, name):
        return _Anything()

    def __call__(self, *args, **kwargs):
        return _Anything()


class _Body:
    def inner_text(self, **kwargs):
        if _STATE["case"] is None:
            return _SCENARIO["loadedBody"]
        return _case()["body"][_STATE["stage"]]


class _Button:
    def __init__(self, name):
        self.name = name

    @property
    def last(self):
        return self

    def click(self):
        recording = _STATE["stage"] == "before" and self.name == "Record for transcription"
        if self.name in ("Discard", "Stop & transcribe") or (
            recording and _STATE["case"] == "denied"
        ):
            _STATE["stage"] = "after"

    def is_enabled(self, **kwargs):
        return True

    def is_visible(self, **kwargs):
        return _case().get("recordingVisible", False)

    def count(self):
        return 2 if _STATE["stage"] == "after" else 1

    def wait_for(self, **kwargs):
        pass


class _Page:
    def set_default_timeout(self, timeout):
        pass

    def add_init_script(self, script):
        pass

    def goto(self, url, **kwargs):
        pass

    def wait_for_timeout(self, timeout):
        pass

    def locator(self, selector):
        return _Body() if selector == "body" else _Anything()

    def get_by_role(self, role, name=None):
        return _Button(name if isinstance(name, str) else "Load Model")

    def evaluate(self, script, *args):
        if "__llamadartMicBegin" in script:
            _STATE["case"] = args[0]
            _STATE["stage"] = "before"
            return None
        if "__llamadartMicSnapshot" in script:
            return _case()["snapshot"]
        if "readText" in script:
            return _case().get("transcript", "")
        return None


class _Context:
    def grant_permissions(self, permissions, **kwargs):
        _CAPTURE["grants"].append(permissions)
        _save()

    def clear_permissions(self):
        _STATE["stage"] = "after"

    def new_page(self):
        return _Page()


class _Browser:
    def new_context(self, **kwargs):
        _STATE["case"] = None
        return _Context()

    def close(self):
        pass


class _Chromium:
    def launch(self, **kwargs):
        _CAPTURE["launches"].append(kwargs.get("args", []))
        _save()
        return _Browser()


class _Playwright:
    chromium = _Chromium()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False


def sync_playwright():
    return _Playwright()
''';

Map<String, Object?> _snapshot({
  List<Map<String, Object?>> tracks = const [
    {'readyState': 'ended', 'ended': false},
  ],
  List<String> contexts = const ['closed'],
  List<bool> blobsRevoked = const [true],
  List<String> events = const [],
  List<String> gumErrors = const [],
}) => {
  'tracks': tracks,
  'contexts': contexts,
  'blobsRevoked': blobsRevoked,
  'events': events,
  'gumErrors': gumErrors,
};

const _loadedBody = 'Model loaded successfully! Ready to chat.';
const _interrupted =
    'Microphone input was interrupted. Using the audio recorded so far.';

Map<String, Object?> _healthyCases() => {
  'discard': {
    'body': {'before': 'Ready', 'after': 'Ready'},
    'snapshot': _snapshot(),
  },
  'too-short': {
    'body': {
      'before': 'Ready',
      'after': 'The microphone recording was too short. Record at least two.',
    },
    'snapshot': _snapshot(),
  },
  'track-ended': {
    'body': {'before': 'Ready', 'after': _interrupted},
    'snapshot': _snapshot(
      tracks: [
        {'readyState': 'ended', 'ended': true},
      ],
      events: ['track-ended'],
    ),
    'transcript': 'And so, my fellow Americans, ask.',
  },
  'denied': {
    'body': {'before': 'Ready', 'after': 'Microphone permission was denied.'},
    'snapshot': _snapshot(tracks: const [], gumErrors: ['NotAllowedError']),
  },
};

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('llamadart-lifecycle-');
    final package = Directory(p.join(tempDir.path, 'playwright'));
    await package.create();
    await File(p.join(package.path, '__init__.py')).writeAsString('');
    await File(
      p.join(package.path, 'sync_api.py'),
    ).writeAsString(_scriptedPlaywright);
  });

  tearDown(() => tempDir.delete(recursive: true));

  Future<({ProcessResult result, Map<String, dynamic> capture})> run(
    Map<String, Object?> cases, {
    String casesFlag = 'discard,too-short,track-ended,denied',
  }) async {
    final audio = File(p.join(tempDir.path, 'speech.wav'))
      ..writeAsBytesSync(silentWav());
    final python = Platform.isWindows ? 'python' : 'python3';
    final capturePath = p.join(tempDir.path, 'capture.json');
    final result = await runBoundedProcess(
      python,
      [
        _script,
        'http://127.0.0.1:1/',
        '--model-url',
        'http://127.0.0.1:1/model.gguf',
        '--mmproj-url',
        'http://127.0.0.1:1/mmproj.gguf',
        '--speech-audio-path',
        audio.path,
        '--reference',
        'And so my fellow Americans ask not what your country can do',
        '--cases',
        casesFlag,
        '--message-timeout-ms',
        '1000',
        '--load-timeout-ms',
        '4000',
        '--response-timeout-ms',
        '4000',
      ],
      timeout: _processTimeout,
      environment: {
        'PYTHONPATH': tempDir.path,
        'LLAMADART_FAKE_PLAYWRIGHT_SCENARIO': jsonEncode({
          'capturePath': capturePath,
          'loadedBody': _loadedBody,
          'cases': cases,
        }),
      },
    );
    return (
      result: result,
      capture:
          jsonDecode(File(capturePath).readAsStringSync())
              as Map<String, dynamic>,
    );
  }

  Map<String, Object?> withCase(String name, Map<String, Object?> change) {
    final cases = _healthyCases();
    cases[name] = {...(cases[name]! as Map<String, Object?>), ...change};
    return cases;
  }

  test(
    'passes when every case shows its message and releases the mic',
    () async {
      final passed = await run(_healthyCases());

      expect(passed.result.exitCode, 0, reason: '${passed.result.stderr}');
      final launches = (passed.capture['launches'] as List<dynamic>)
          .map((launch) => (launch as List<dynamic>).cast<String>())
          .toList();
      expect(launches, hasLength(2), reason: 'denied has its own launch');
      expect(
        launches.first,
        isNot(contains('--use-fake-ui-for-media-stream=deny')),
      );
      expect(launches.last, contains('--use-fake-ui-for-media-stream=deny'));
      for (final launch in launches) {
        expect(
          launch.singleWhere(
            (arg) => arg.startsWith('--use-file-for-fake-audio-capture='),
          ),
          endsWith('capture.wav%noloop'),
        );
      }
    },
  );

  test('fails a case that leaves the microphone live', () async {
    final failed = await run(
      withCase('too-short', {
        'snapshot': _snapshot(
          tracks: [
            {'readyState': 'live', 'ended': false},
          ],
        ),
      }),
    );

    expect(failed.result.exitCode, isNot(0));
    expect(failed.result.stderr, contains('too-short'));
    expect(failed.result.stderr, contains('1 live microphone track(s)'));
  });

  test('fails a case that leaves an AudioContext open', () async {
    final failed = await run(
      withCase('discard', {
        'snapshot': _snapshot(contexts: ['running']),
      }),
    );

    expect(failed.result.exitCode, isNot(0));
    expect(failed.result.stderr, contains('1 AudioContext(s) not closed'));
  });

  test('fails a case that leaves a recording blob unrevoked', () async {
    final failed = await run(
      withCase('too-short', {
        'snapshot': _snapshot(blobsRevoked: [false]),
      }),
    );

    expect(failed.result.exitCode, isNot(0));
    expect(
      failed.result.stderr,
      contains('1 recording blob URL(s) not revoked'),
    );
  });

  test('fails a case the app never opened a microphone for', () async {
    final failed = await run(
      withCase('discard', {'snapshot': _snapshot(tracks: const [])}),
    );

    expect(failed.result.exitCode, isNot(0));
    expect(failed.result.stderr, contains('never opened a microphone stream'));
  });

  test('denied needs the browser to reject getUserMedia', () async {
    final failed = await run(
      withCase('denied', {'snapshot': _snapshot(tracks: const [])}),
    );

    expect(failed.result.exitCode, isNot(0));
    expect(failed.result.stderr, contains('NotAllowedError'));
  });

  test('track-ended needs the browser to have fired ended', () async {
    // The page shows the warning and the partial transcript, so only the
    // missing ended event can fail this case.
    final failed = await run(
      withCase('track-ended', {
        'snapshot': _snapshot(
          tracks: [
            {'readyState': 'ended', 'ended': false},
          ],
        ),
      }),
      casesFlag: 'track-ended',
    );

    expect(failed.result.exitCode, isNot(0));
    expect(
      failed.result.stderr,
      contains("the browser to fire 'ended' on the microphone track"),
    );
  });

  test('track-ended needs a partial transcript', () async {
    final failed = await run(
      withCase('track-ended', {'transcript': ''}),
      casesFlag: 'track-ended',
    );

    expect(failed.result.exitCode, isNot(0));
    expect(failed.result.stderr, contains('Empty or unrelated'));
  });

  test('fails without the interruption warning', () async {
    final failed = await run(
      withCase('track-ended', {
        'body': {'before': 'Ready', 'after': 'Ready'},
      }),
      casesFlag: 'track-ended',
    );

    expect(failed.result.exitCode, isNot(0));
    expect(failed.result.stderr, contains('Microphone input was interrupted'));
  });

  test('fails without the too-short message', () async {
    final failed = await run(
      withCase('too-short', {
        'body': {'before': 'Ready', 'after': 'Ready'},
      }),
      casesFlag: 'too-short',
    );

    expect(failed.result.exitCode, isNot(0));
    expect(failed.result.stderr, contains('recording was too short'));
  });

  test('fails without the denied message', () async {
    final failed = await run(
      withCase('denied', {
        'body': {'before': 'Ready', 'after': 'Ready'},
      }),
      casesFlag: 'denied',
    );

    expect(failed.result.exitCode, isNot(0));
    expect(failed.result.stderr, contains('permission was denied'));
  });

  test('discard fails when it shows a failure message', () async {
    final failed = await run(
      withCase('discard', {
        'body': {
          'before': 'Ready',
          'after': 'The microphone recording was too short.',
        },
      }),
      casesFlag: 'discard',
    );

    expect(failed.result.exitCode, isNot(0));
    expect(failed.result.stderr, contains('Discarding showed a message'));
  });

  for (final (name, change, expected) in [
    ('contexts', {'contexts': <String>[]}, 'never opened an AudioContext'),
    ('blobs', {'blobsRevoked': <bool>[]}, 'never opened a recording blob'),
  ]) {
    test('a recording with no observed $name fails', () async {
      final base = _snapshot();
      final failed = await run(
        withCase('discard', {
          'snapshot': {...base, ...change},
        }),
        casesFlag: 'discard',
      );

      expect(failed.result.exitCode, isNot(0));
      expect(failed.result.stderr, contains(expected));
    });
  }

  test('rejects an unknown case', () async {
    final audio = File(p.join(tempDir.path, 'speech.wav'))
      ..writeAsBytesSync(const [0]);
    final result = await runBoundedProcess(
      Platform.isWindows ? 'python' : 'python3',
      [
        _script,
        'http://127.0.0.1:1/',
        '--model-url',
        'm',
        '--mmproj-url',
        'p',
        '--speech-audio-path',
        audio.path,
        '--reference',
        'r',
        '--cases',
        'nope',
      ],
      timeout: _processTimeout,
      environment: {
        'PYTHONPATH': tempDir.path,
        'LLAMADART_FAKE_PLAYWRIGHT_SCENARIO': '{}',
      },
    );

    expect(result.exitCode, 2, reason: '${result.stderr}');
    expect(result.stderr, contains('--cases must name some of'));
  });
}
