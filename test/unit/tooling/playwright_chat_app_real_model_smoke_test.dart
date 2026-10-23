@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/bounded_process.dart';

const _script = 'tool/testing/playwright_chat_app_real_model_smoke.py';
const _playwrightReached = 'fake playwright reached';

// Well above any run here: `python` stays under 4 s even on GitHub's Windows
// runners.
const _processTimeout = Duration(seconds: 60);

Future<ProcessResult> _runProcess(
  String executable,
  List<String> arguments, {
  Map<String, String>? environment,
}) => runBoundedProcess(
  executable,
  arguments,
  timeout: _processTimeout,
  environment: environment,
);

// Stands in for a browser: the page answers from a scenario and records the
// scripts the helper hands it.
const _scriptedPlaywright = r'''
import json
import os

_SCENARIO = json.loads(os.environ["LLAMADART_FAKE_PLAYWRIGHT_SCENARIO"])
_CAPTURE = {"initScript": None, "evaluateScripts": []}


def _save():
    with open(_SCENARIO["capturePath"], "w", encoding="utf-8") as capture:
        json.dump(_CAPTURE, capture)


class TimeoutError(Exception):
    pass


class _Anything:
    def __getattr__(self, name):
        return _Anything()

    def __call__(self, *args, **kwargs):
        return _Anything()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False


class _Request:
    method = "GET"
    failure = None

    def __init__(self, url):
        self.url = url


class _Body(_Anything):
    def inner_text(self, **kwargs):
        return _SCENARIO["body"]


class _Page(_Anything):
    def __init__(self):
        self._handlers = {}

    def add_init_script(self, script):
        _CAPTURE["initScript"] = script
        _save()

    def on(self, event, handler):
        self._handlers.setdefault(event, []).append(handler)

    def goto(self, url, **kwargs):
        for requested in _SCENARIO["requests"]:
            for handler in self._handlers.get("request", []):
                handler(_Request(requested))

    def locator(self, selector):
        return _Body() if selector == "body" else _Anything()

    def evaluate(self, script, *args):
        _CAPTURE["evaluateScripts"].append(script)
        _save()
        return _SCENARIO["pageState"]


class _Context(_Anything):
    def new_page(self):
        return _Page()


class _Browser(_Anything):
    def new_context(self, **kwargs):
        return _Context()


class _Chromium:
    def launch(self, **kwargs):
        return _Browser()


class _Playwright(_Anything):
    chromium = _Chromium()


def sync_playwright():
    return _Playwright()
''';

// Runs the recorded page scripts against a stand-in `@litert-lm/core` module,
// loading the wrapped module the way `LiteRtLmBackend` does on the Web.
const _pageScriptHarness = r'''
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const [failureCapturePath, successCapturePath, workDir] = process.argv.slice(2);
const failure = JSON.parse(readFileSync(failureCapturePath, 'utf8'));
const success = JSON.parse(readFileSync(successCapturePath, 'utf8'));
const evaluate = (script) => (0, eval)(`(${script})`)();
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const runtimePath = join(workDir, 'fake_litert_lm.mjs');
writeFileSync(
  runtimePath,
  `export const Backend = {};
export class Engine {
  static calls = 0;
  static async create(settings) {
    Engine.calls += 1;
    if (settings.model === 'broken') {
      throw new Error('fake engine create failed');
    }
    return {
      async createConversation() {
        return {
          sendMessageStreaming() {
            return new ReadableStream({
              start(controller) {
                controller.enqueue({ content: [{ text: '4' }] });
                controller.close();
              },
            });
          },
        };
      },
    };
  }
}
`,
);
const runtimeUrl = pathToFileURL(runtimePath).href;

globalThis.window = globalThis;
Object.defineProperty(globalThis, 'localStorage', {
  configurable: true,
  value: { setItem() {}, removeItem() {} },
});
// Node cannot import a blob: URL, so the wrapper module goes through a file.
let wrapperSource;
URL.createObjectURL = (blob) => {
  wrapperSource = blob.text();
  return 'blob:llamadart-test';
};
window.__llamadartLiteRtLmModuleUrl = runtimeUrl;
(0, eval)(success.initScript);
// The init script polls for a WebGPU bridge that never loads here. Left
// running, its interval turns any stalled await below into a hang instead of
// node's unsettled top-level await error.
clearInterval(window.__llamadartRealBridgePatchTimer);

const wrapperPath = join(workDir, 'wrapped_litert_lm.mjs');
writeFileSync(wrapperPath, await wrapperSource);
const wrapper = await import(pathToFileURL(wrapperPath).href);
const runtime = await import(runtimeUrl);
const runtimeCreate = runtime.Engine.create;
window.LiteRtLmEngine = wrapper.Engine;
// Longer than any timer the init script could install before the app calls
// Engine.create.
await sleep(200);

const report = {
  runtimeUrl,
  runtimeCreateReplaced: runtime.Engine.create !== runtimeCreate,
};
try {
  const engine = await window.LiteRtLmEngine.create({ model: 'ok' });
  const conversation = await engine.createConversation({});
  const reader = conversation.sendMessageStreaming('2+2?').getReader();
  while (!(await reader.read()).done) {}
  for (let i = 0; i < 100 && !window.__llamadartRealLiteRtLmLastResponse; i++) {
    await sleep(20);
  }
  await window.LiteRtLmEngine.create({ model: 'ok' });
  report.runtimeCreateCalls = runtime.Engine.calls;
  report.response = window.__llamadartRealLiteRtLmLastResponse;
  report.prompt = window.__llamadartRealLiteRtLmLastPrompt;
  report.settingsModel = window.__llamadartRealLiteRtLmLastSettings.model;
  report.resultGlobals = evaluate(success.evaluateScripts.at(-1));
} catch (error) {
  report.createError = String(error);
}
try {
  await window.LiteRtLmEngine.create({ model: 'broken' });
} catch (error) {
  report.brokenCreateError = String(error);
}
report.loadFailureStates = failure.evaluateScripts.map(evaluate);
console.log(JSON.stringify(report));
process.exit(0);
''';

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
    return _runProcess(
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

  group(
    'LiteRT-LM chat run against a scripted page',
    // A test here runs up to three processes, so a stalled one reports through
    // _processTimeout instead of the default 30 s test timeout.
    timeout: Timeout(_processTimeout * 3),
    () {
      const moduleUrl =
          'https://cdn.jsdelivr.net/npm/@litert-lm/core@9.9.9/+esm';
      const wasmLoaderUrl =
          'https://cdn.jsdelivr.net/npm/@litert-lm/core@9.9.9/wasm/litertlm_wasm_internal.js';
      const wasmUrl =
          'https://cdn.jsdelivr.net/npm/@litert-lm/core@9.9.9/wasm/litertlm_wasm_internal.wasm';
      const modelUrl = 'http://127.0.0.1:1/model.litertlm';
      const createErrorStack =
          'RangeError: Maximum call stack size exceeded\n    at Proxy.<anonymous>';

      setUp(() async {
        await File(
          p.join(tempDir.path, 'playwright', 'sync_api.py'),
        ).writeAsString(_scriptedPlaywright);
      });

      Future<({ProcessResult result, Map<String, dynamic> capture})> runChat(
        String name, {
        required String body,
        required Map<String, Object?> pageState,
      }) async {
        final capturePath = p.join(tempDir.path, '$name.json');
        final result = await _runProcess(
          Platform.isWindows ? 'python' : 'python3',
          [
            _script,
            'http://127.0.0.1:1/',
            '--model-url',
            modelUrl,
            '--response-source',
            'litert',
            '--load-timeout-ms',
            '4000',
          ],
          environment: {
            'PYTHONPATH': tempDir.path,
            'LLAMADART_FAKE_PLAYWRIGHT_SCENARIO': jsonEncode({
              'capturePath': capturePath,
              'body': body,
              'pageState': pageState,
              'requests': [
                modelUrl,
                moduleUrl,
                wasmLoaderUrl,
                wasmUrl,
                moduleUrl,
              ],
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

      Future<({ProcessResult result, Map<String, dynamic> capture})>
      runFailedLoad() => runChat(
        'failed_load',
        body: 'Model failed to load\nRangeError\nRetry\nChange model',
        pageState: {'liteRtLmCreateErrorStack': createErrorStack},
      );

      Future<({ProcessResult result, Map<String, dynamic> capture})>
      runLoadedChat() => runChat(
        'loaded_chat',
        body: 'Model loaded successfully! Ready to chat.',
        pageState: {'liteRtLmResponse': '4'},
      );

      Future<({ProcessResult result, Map<String, dynamic> capture})>
      runPenaltyCheck(
        String name,
        List<String> flags, {
        required Object? capabilities,
        required Object? options,
      }) async {
        final capturePath = p.join(tempDir.path, '$name.json');
        final result = await _runProcess(
          Platform.isWindows ? 'python' : 'python3',
          [
            _script,
            'http://127.0.0.1:1/',
            '--model-url',
            modelUrl,
            '--allow-any-response',
            '--load-timeout-ms',
            '4000',
            ...flags,
          ],
          environment: {
            'PYTHONPATH': tempDir.path,
            'LLAMADART_FAKE_PLAYWRIGHT_SCENARIO': jsonEncode({
              'capturePath': capturePath,
              'body': 'Model loaded successfully! Ready to chat.',
              'pageState': {
                'bridgeResponse': 'ok',
                'capabilities': capabilities,
                'options': options,
              },
              'requests': [modelUrl],
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

      group('penaltyPromptTokens checks', () {
        const probe = '--expect-penalty-prompt-tokens-probe';
        const option = '--expect-penalty-prompt-tokens-option';

        test('the probe flag passes when the probe reports true', () async {
          final run = await runPenaltyCheck(
            'probe_pass',
            [probe],
            capabilities: {'penaltyPromptTokens': true},
            options: {},
          );
          expect(run.result.exitCode, 0, reason: '${run.result.stderr}');
        });

        for (final capabilities in <Object?>[
          {'penaltyPromptTokens': false},
          <String, Object?>{},
          null,
        ]) {
          test('the probe flag fails on $capabilities', () async {
            final run = await runPenaltyCheck(
              'probe_fail',
              [probe],
              capabilities: capabilities,
              options: {},
            );
            expect(run.result.exitCode, isNot(0));
            expect(
              run.result.stderr,
              contains('did not report penaltyPromptTokens: true'),
            );
          });
        }

        test('the absent option passes and fails', () async {
          final pass = await runPenaltyCheck(
            'absent_pass',
            [option, 'absent'],
            capabilities: null,
            options: {'penaltyPromptTokens': '<absent>'},
          );
          expect(pass.result.exitCode, 0, reason: '${pass.result.stderr}');

          final fail = await runPenaltyCheck(
            'absent_fail',
            [option, 'absent'],
            capabilities: null,
            options: {'penaltyPromptTokens': false},
          );
          expect(fail.result.exitCode, isNot(0));
          expect(
            fail.result.stderr,
            contains('Completion call carried penaltyPromptTokens'),
          );
        });

        test('the false option passes and fails', () async {
          final pass = await runPenaltyCheck(
            'false_pass',
            [option, 'false'],
            capabilities: null,
            options: {'penaltyPromptTokens': false},
          );
          expect(pass.result.exitCode, 0, reason: '${pass.result.stderr}');

          for (final carried in <Object?>['<absent>', true]) {
            final fail = await runPenaltyCheck(
              'false_fail',
              [option, 'false'],
              capabilities: null,
              options: {'penaltyPromptTokens': carried},
            );
            expect(fail.result.exitCode, isNot(0), reason: '$carried');
          }
        });

        test('the init script records the option and the probe', () async {
          final initScript =
              (await runPenaltyCheck(
                    'init',
                    const [],
                    capabilities: null,
                    options: {},
                  )).capture['initScript']
                  as String;
          expect(initScript, contains("'penaltyPromptTokens' in options"));
          expect(initScript, contains('getCompletionCapabilities'));
          expect(initScript, contains("'<absent>'"));
        });

        test(
          'the patched bridge records the option, its absence and the probe',
          testOn: '!windows',
          () async {
            final initScript =
                (await runPenaltyCheck(
                      'node_init',
                      const [],
                      capabilities: null,
                      options: {},
                    )).capture['initScript']
                    as String;
            final scriptFile = File(p.join(tempDir.path, 'init.js'))
              ..writeAsStringSync(initScript);
            final harness = File(p.join(tempDir.path, 'penalty_harness.mjs'))
              ..writeAsStringSync(r"""
import fs from 'node:fs';
globalThis.window = globalThis;
globalThis.localStorage = { setItem() {}, removeItem() {} };
class LlamaWebGpuBridge {
  async createCompletion() { return 'ok'; }
  getCompletionCapabilities() {
    return Promise.resolve({ penaltyPromptTokens: true });
  }
}
globalThis.LlamaWebGpuBridge = LlamaWebGpuBridge;
(0, eval)(fs.readFileSync(process.argv[2], 'utf8'));
await new Promise(resolve => setTimeout(resolve, 100));
const bridge = new LlamaWebGpuBridge();
await bridge.createCompletion('p', { penalty: 1.1 });
const absent = window.__llamadartRealBridgeLastOptions.penaltyPromptTokens;
await bridge.createCompletion('p', { penaltyPromptTokens: false });
const falseValue = window.__llamadartRealBridgeLastOptions.penaltyPromptTokens;
await bridge.createCompletion('p', { penaltyPromptTokens: true });
const trueValue = window.__llamadartRealBridgeLastOptions.penaltyPromptTokens;
await bridge.getCompletionCapabilities();
await new Promise(resolve => setTimeout(resolve, 20));
console.log(JSON.stringify({
  absent, falseValue, trueValue,
  capabilities: window.__llamadartRealBridgeCompletionCapabilities,
}));
process.exit(0);
""");
            final node = await _runProcess('node', [
              harness.path,
              scriptFile.path,
            ]);

            expect(node.exitCode, 0, reason: '${node.stderr}');
            expect(jsonDecode((node.stdout as String).trim()), {
              'absent': '<absent>',
              'falseValue': false,
              'trueValue': true,
              'capabilities': {'penaltyPromptTokens': true},
            });
          },
        );

        test('--tools seeds the tools setting and a declaration', () async {
          const emptyDeclarations = r'"flutter.tool_declarations": "\"[]\""';
          final off =
              (await runPenaltyCheck(
                    'tools_off',
                    const [],
                    capabilities: null,
                    options: {},
                  )).capture['initScript']
                  as String;
          expect(off, contains('"flutter.tools_enabled": "false"'));
          expect(off, contains(emptyDeclarations));

          final on =
              (await runPenaltyCheck(
                    'tools_on',
                    const ['--tools'],
                    capabilities: null,
                    options: {},
                  )).capture['initScript']
                  as String;
          expect(on, contains('"flutter.tools_enabled": "true"'));
          expect(on, contains(r'getWeather'));
          expect(on, isNot(contains(emptyDeclarations)));
        });
      });

      List<Map<String, dynamic>> events(ProcessResult result) => [
        for (final line in const LineSplitter().convert(
          result.stdout as String,
        ))
          jsonDecode(line) as Map<String, dynamic>,
      ];

      test(
        'a failed model load ends the run with the page error state',
        () async {
          final run = await runFailedLoad();

          expect(run.result.exitCode, 1);
          expect(
            run.result.stderr,
            allOf(
              contains('App entered error state while waiting for model load'),
              contains(jsonEncode(createErrorStack)),
              isNot(contains('Timed out waiting for model load')),
            ),
          );
        },
      );

      test('the result names the LiteRT-LM runtime files requested', () async {
        final run = await runLoadedChat();

        expect(run.result.exitCode, 0, reason: '${run.result.stderr}');
        final emitted = events(run.result);
        expect(
          [
            for (final event in emitted)
              if (event['event'] == 'litert_lm_runtime_request') event['url'],
          ],
          [moduleUrl, wasmLoaderUrl, wasmUrl],
        );
        final result = emitted.singleWhere(
          (event) => event['event'] == 'result',
        );
        expect(result['liteRtLmRuntimeRequests'], [
          moduleUrl,
          wasmLoaderUrl,
          wasmUrl,
        ]);
      });

      test('the init script wraps Engine.create once and leaves '
          'window.LiteRtLmEngine alone', () async {
        final initScript =
            (await runLoadedChat()).capture['initScript'] as String;

        expect('new Proxy(mod.Engine'.allMatches(initScript), hasLength(1));
        expect(initScript.contains('LiteRtLmEngine'), isFalse);
        expect(initScript.contains('.create ='), isFalse);
      });

      // The page scripts target a browser, so node on Linux and macOS covers
      // them. The first `node` start of a GitHub Windows job takes 3-42 s
      // (later ones under 1 s) and has stalled past two minutes.
      const nodeTestOn = '!windows';

      Future<Map<String, dynamic>> runPageScripts() async {
        await runFailedLoad();
        await runLoadedChat();
        final harness = File(p.join(tempDir.path, 'page_script_harness.mjs'))
          ..writeAsStringSync(_pageScriptHarness);
        final node = await _runProcess('node', [
          harness.path,
          p.join(tempDir.path, 'failed_load.json'),
          p.join(tempDir.path, 'loaded_chat.json'),
          tempDir.path,
        ]);

        expect(node.exitCode, 0, reason: '${node.stderr}');
        return jsonDecode((node.stdout as String).trim())
            as Map<String, dynamic>;
      }

      // Issue 970: a second wrapper assigned through the module's Proxy made
      // Engine.create call itself until the stack overflowed.
      test(
        'wrapped Engine.create reaches the runtime once per call',
        testOn: nodeTestOn,
        () async {
          final report = await runPageScripts();

          expect(report['createError'], isNull);
          expect(report['runtimeCreateReplaced'], isFalse);
          expect(report['runtimeCreateCalls'], 2);
          expect(report['settingsModel'], 'ok');
          expect(report['prompt'], '2+2?');
          expect(report['response'], '4');
          expect(
            (report['resultGlobals']
                as Map<String, dynamic>)['liteRtLmOriginalModuleUrl'],
            report['runtimeUrl'],
          );
        },
      );

      test(
        'a rejected Engine.create leaves its stack for the load-failure '
        'report',
        testOn: nodeTestOn,
        () async {
          final report = await runPageScripts();

          expect(
            report['brokenCreateError'],
            'Error: fake engine create failed',
          );
          final state =
              (report['loadFailureStates'] as List<dynamic>).single
                  as Map<String, dynamic>;
          expect(state['liteRtLmError'], 'Error: fake engine create failed');
          expect(
            state['liteRtLmCreateErrorStack'],
            allOf(
              startsWith('Error: fake engine create failed\n'),
              contains('fake_litert_lm.mjs'),
            ),
          );
        },
      );
    },
  );
}
