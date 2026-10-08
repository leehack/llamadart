@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/backends/litert_lm/litert_lm_backend.dart';
import 'package:llamadart/src/backends/litert_lm/litert_lm_runtime.dart';
import 'package:llamadart/src/backends/litert_lm/litert_lm_service.dart';
import 'package:llamadart/src/backends/litert_lm/worker.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('llamadart_qwen_media_');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  // The real service behind the real backend and engine, in this isolate,
  // with only the native runtime client replaced.
  Future<({LlamaEngine engine, List<_RuntimeClient> clients})> load(
    String bundle, {
    required bool encoders,
  }) async {
    final clients = <_RuntimeClient>[];
    final handshake = ReceivePort();
    runLiteRtLmWorkerForTesting(
      handshake.sendPort,
      LiteRtLmService(
        clientFactory: () {
          final client = _RuntimeClient(failConversation: !encoders);
          clients.add(client);
          return client;
        },
        readBundleCapabilities: (_) =>
            (vision: encoders, audio: encoders, speculativeDecoding: false),
      ),
      exitOnDispose: false,
    );
    final engine = LlamaEngine(
      LiteRtLmBackend(initialSendPort: await handshake.first as SendPort),
    );
    final modelFile = File('${tempDir.path}/$bundle');
    await modelFile.writeAsString('fake model');
    await engine.loadModel(modelFile.path);
    return (engine: engine, clients: clients);
  }

  LlamaChatMessage user(LlamaContentPart media) => LlamaChatMessage.withContent(
    role: LlamaChatRole.user,
    content: [const LlamaTextContent('Describe this.'), media],
  );

  for (final bundle in [
    'Qwen3-0.6B.litertlm',
    'Qwen3.5-0.8B_int8.litertlm',
    'qwen-3-vl.litertlm',
  ]) {
    for (final kind in ['image', 'audio']) {
      final bytes = kind == 'image' ? [1, 2, 3] : [4, 5, 6];
      LlamaContentPart media() => kind == 'image'
          ? LlamaImageContent(bytes: Uint8List.fromList(bytes))
          : LlamaAudioContent(bytes: Uint8List.fromList(bytes));

      test('$bundle renders the $kind marker in the Dart template', () async {
        final loaded = await load(bundle, encoders: true);
        try {
          final rendered = await loaded.engine.chatTemplate(
            [user(media())],
            tools: [
              ToolDefinition(
                name: 'lookup',
                description: 'Lookup',
                parameters: const [],
                handler: (_) async => 'unused',
              ),
            ],
            includeTokenCount: false,
          );
          expect(
            rendered.prompt,
            endsWith(
              '<|im_start|>user\nDescribe this.<__media__><|im_end|>\n'
              '<|im_start|>assistant\n',
            ),
          );
          expect(rendered.format, ChatFormat.hermes.index);
          expect(rendered.grammarTriggers.single.value, '<tool_call>');
          expect(rendered.preservedTokens, ['<tool_call>', '</tool_call>']);
        } finally {
          await loaded.engine.dispose();
        }
      });

      test('$bundle $kind request fails at the native media boundary when the '
          'bundle has no $kind encoder', () async {
        final loaded = await load(bundle, encoders: false);
        try {
          await expectLater(
            loaded.engine.create([user(media())]).drain<void>(),
            throwsA(
              isA<LlamaUnsupportedException>().having(
                (error) => error.message,
                'message',
                allOf(
                  contains('declares no $kind encoder'),
                  contains('conversation create failed'),
                ),
              ),
            ),
          );
          expect(loaded.clients.last.conversations, 1);
        } finally {
          await loaded.engine.dispose();
        }
      });

      test('$bundle $kind request reaches the native conversation with the '
          'bundle template', () async {
        final loaded = await load(bundle, encoders: true);
        try {
          expect(await loaded.engine.create([user(media())]).text(), 'A cat.');
          final client = loaded.clients.last;
          expect(client.promptTemplates, [null]);
          expect(jsonDecode(client.messageJson!), {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': 'Describe this.'},
              {'type': kind, 'blob': base64Encode(bytes)},
            ],
          });
        } finally {
          await loaded.engine.dispose();
        }
      });

      test('$bundle ChatSession $kind turn reaches the native '
          'conversation', () async {
        final loaded = await load(bundle, encoders: true);
        try {
          final session = ChatSession(loaded.engine);
          expect(await session.create(user(media()).parts).text(), 'A cat.');
          expect(loaded.clients.last.promptTemplates, [null]);
          expect(session.history.map((message) => message.role), [
            LlamaChatRole.user,
            LlamaChatRole.assistant,
          ]);
        } finally {
          await loaded.engine.dispose();
        }
      });
    }
  }

  test('a video part gets the typed video error, not a template error, '
      'through ChatSession', () async {
    final loaded = await load('Qwen3-0.6B.litertlm', encoders: true);
    try {
      final video = LlamaVideoContent(bytes: Uint8List.fromList([7, 8, 9]));
      final rendered = await loaded.engine.chatTemplate([
        user(video),
      ], includeTokenCount: false);
      expect(
        rendered.prompt,
        '<|im_start|>user\nDescribe this.<__media__><|im_end|>\n'
        '<|im_start|>assistant\n',
      );
      await expectLater(
        ChatSession(loaded.engine).create(user(video).parts).drain<void>(),
        throwsA(
          isA<LlamaUnsupportedException>().having(
            (error) => error.message,
            'message',
            contains('Video input is not consumable'),
          ),
        ),
      );
      expect(loaded.clients.every((client) => client.conversations == 0), true);
    } finally {
      await loaded.engine.dispose();
    }
  });

  test('a text-only turn on a Qwen 3 bundle still gets the built-in '
      'template as the native override', () async {
    final loaded = await load('Qwen3-0.6B.litertlm', encoders: true);
    try {
      expect(
        await loaded.engine.create(const [
          LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'Hello'),
        ]).text(),
        'A cat.',
      );
      expect(
        loaded.clients.last.promptTemplates.single,
        (await loaded.engine.getMetadata())['tokenizer.chat_template'],
      );
    } finally {
      await loaded.engine.dispose();
    }
  });
}

class _RuntimeClient extends LiteRtLmRuntimeClient {
  _RuntimeClient({required this.failConversation});

  final bool failConversation;
  final List<String?> promptTemplates = <String?>[];
  String? messageJson;
  int conversations = 0;

  @override
  Future<void> initialize({
    required String modelPath,
    String backend = 'gpu',
    String? visionBackend,
    String? audioBackend,
    int maxTokens = 4096,
    int outputTokens = 256,
    int? prefillTokens,
    int? maxNumImages,
    String? cacheDir,
    bool speculativeDecoding = true,
    int minLogLevel = 3,
    LiteRtLmActivationDataType? activationDataType,
    int? prefillChunkSize,
    bool? parallelFileSectionLoading,
    String? dispatchLibDir,
    int? numberOfThreads,
  }) async {}

  @override
  void setMinLogLevel(int level) {}

  @override
  List<int> tokenize(String text, {bool addSpecial = true}) => text.codeUnits;

  @override
  void createConversation({
    String? systemMessage,
    String? promptTemplate,
    List<Map<String, dynamic>>? messages,
    List<Map<String, dynamic>>? tools,
    Map<String, dynamic>? extraContext,
    double temperature = 0.8,
    int topK = 40,
    double topP = 0.95,
    int seed = 1,
    bool npuBackend = false,
    String? loraPath,
  }) {
    conversations += 1;
    if (failConversation) throw StateError('conversation create failed');
    promptTemplates.add(promptTemplate);
  }

  @override
  Stream<String> generateMessageJson(
    String messageJson, {
    Map<String, dynamic>? extraContext,
    int? visualTokenBudget,
    int? maxOutputTokens,
  }) {
    this.messageJson = messageJson;
    return Stream.value('A cat.');
  }

  @override
  LiteRtLmRuntimeMetrics readMetrics({required int wallMilliseconds}) =>
      LiteRtLmRuntimeMetrics(
        inputTokens: 0,
        outputTokens: 0,
        timeToFirstTokenSeconds: null,
        initSeconds: null,
        prefillTokensPerSecond: null,
        decodeTokensPerSecond: null,
        wallMilliseconds: wallMilliseconds,
      );

  @override
  void cancel() {}

  @override
  void dispose() {}
}
