import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart_cli_example/llamadart_cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late String modelPath;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('llamadart_cli_runner_');
    modelPath = p.join(tempDir.path, 'model.gguf');
    await File(modelPath).writeAsBytes(const <int>[]);
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  LlamaCliConfig configFor({required bool simpleIo}) => LlamaCliConfig(
    showHelp: false,
    modelPathOrUrl: modelPath,
    modelsDirectory: tempDir.path,
    interactive: true,
    interactiveFirst: false,
    contextSize: 4096,
    gpuLayers: 0,
    threads: 1,
    threadsBatch: 1,
    maxTokens: 8,
    temperature: 0,
    topK: 40,
    topP: 0.95,
    minP: 0.05,
    repeatPenalty: 1,
    fitContext: true,
    jinja: true,
    instruct: false,
    simpleIo: simpleIo,
    color: false,
    reversePrompts: const <String>[],
  );

  Future<String> runPiped(_QueuedBackend backend, String input) async {
    final output = _RecordingStdout();
    final runner = LlamaCliRunner(
      configFor(simpleIo: true),
      engine: LlamaEngine(backend),
    );
    await IOOverrides.runZoned(
      () async {
        try {
          await runner.run();
        } finally {
          await runner.dispose();
        }
      },
      stdout: () => output,
      stdin: () => _PipedStdin(input),
    );
    return output.text;
  }

  test(
    'a reply ending in a newline is stored and printed without it',
    () async {
      final backend = _QueuedBackend()
        ..queueResponse(<String>['4', '\n'])
        ..queueResponse(<String>['6']);

      final transcript = await runPiped(backend, '2+2?\n3+3?\n');

      expect(backend.prompts, hasLength(2));
      expect(
        backend.prompts[1],
        '<|im_start|>user\n2+2?<|im_end|>\n'
        '<|im_start|>assistant\n4<|im_end|>\n'
        '<|im_start|>user\n3+3?<|im_end|>\n'
        '<|im_start|>assistant\n',
      );
      expect(transcript, endsWith('> \n4\n\n> \n6\n\n\nExiting...\n'));
    },
  );

  test('whitespace inside a reply is printed and stored', () async {
    final backend = _QueuedBackend()
      ..queueResponse(<String>['a', '\n\n', 'b ', ' '])
      ..queueResponse(<String>['c']);

    final transcript = await runPiped(backend, 'one\ntwo\n');

    expect(transcript, contains('> \na\n\nb\n\n> \nc\n\n'));
    expect(backend.prompts[1], contains('assistant\na\n\nb<|im_end|>'));
  });
}

class _QueuedBackend implements LlamaBackend {
  final List<List<String>> _responses = <List<String>>[];
  final List<String> prompts = <String>[];

  void queueResponse(List<String> chunks) => _responses.add(chunks);

  @override
  bool get isReady => true;

  @override
  Future<int> modelLoad(String path, ModelParams params) async => 1;

  @override
  Future<int> modelLoadFromUrl(
    String url,
    ModelParams params, {
    Function(double progress)? onProgress,
  }) async => 1;

  @override
  Future<void> modelFree(int modelHandle) async {}

  @override
  Future<int> contextCreate(int modelHandle, ModelParams params) async => 1;

  @override
  Future<void> contextFree(int contextHandle) async {}

  @override
  Future<int> getContextSize(int contextHandle) async => 4096;

  @override
  Stream<List<int>> generate(
    int contextHandle,
    String prompt,
    GenerationParams params, {
    List<LlamaContentPart>? parts,
  }) async* {
    prompts.add(prompt);
    for (final chunk in _responses.removeAt(0)) {
      yield utf8.encode(chunk);
    }
  }

  @override
  void cancelGeneration() {}

  @override
  Future<List<int>> tokenize(
    int modelHandle,
    String text, {
    bool addSpecial = true,
  }) async => List<int>.filled(utf8.encode(text).length, 0);

  @override
  Future<String> detokenize(
    int modelHandle,
    List<int> tokens, {
    bool special = false,
  }) async => '';

  @override
  Future<Map<String, String>> modelMetadata(int modelHandle) async =>
      <String, String>{
        'tokenizer.chat_template':
            '{% for message in messages %}'
            "{{ '<|im_start|>' + message['role'] + '\\n' "
            "+ message['content'] + '<|im_end|>' + '\\n' }}"
            '{% endfor %}'
            "{% if add_generation_prompt %}{{ '<|im_start|>assistant\\n' }}"
            '{% endif %}',
      };

  @override
  Future<void> setLoraAdapter(
    int contextHandle,
    String path,
    double scale,
  ) async {}

  @override
  Future<void> removeLoraAdapter(int contextHandle, String path) async {}

  @override
  Future<void> clearLoraAdapters(int contextHandle) async {}

  @override
  Future<String> getBackendName() async => 'queued-test';

  @override
  bool get supportsUrlLoading => false;

  @override
  Future<bool> isGpuSupported() async => false;

  @override
  Future<void> setLogLevel(LlamaLogLevel level) async {}

  @override
  Future<void> dispose() async {}

  @override
  Future<int?> multimodalContextCreate(
    int modelHandle,
    String mmProjPath,
  ) async => null;

  @override
  Future<void> multimodalContextFree(int mmContextHandle) async {}

  @override
  Future<bool> supportsVision(int mmContextHandle) async => false;

  @override
  Future<bool> supportsAudio(int mmContextHandle) async => false;

  @override
  Future<({int total, int free})> getVramInfo() async => (total: 0, free: 0);

  @override
  Future<String> applyChatTemplate(
    int modelHandle,
    List<Map<String, dynamic>> messages, {
    String? customTemplate,
    bool addAssistant = true,
  }) async => '';
}

class _RecordingStdout implements Stdout {
  final StringBuffer _buffer = StringBuffer();

  String get text => _buffer.toString();

  @override
  void write(Object? object) => _buffer.write(object);

  @override
  void writeln([Object? object = '']) => _buffer.writeln(object);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _PipedStdin extends Stream<List<int>> implements Stdin {
  final String _input;

  _PipedStdin(this._input);

  @override
  bool get hasTerminal => false;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(utf8.encode(_input)).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
