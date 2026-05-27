import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:llamadart/llamadart.dart';

class MockLlamaBackend implements LlamaBackend, BackendAvailability {
  int _generateCallCount = 0;
  final List<String> _responses = [];
  int contextSize = 2048;
  String? lastPrompt;
  int tokenizeCalls = 0;
  bool supportsTokenization = true;

  void queueResponse(String response) => _responses.add(response);

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
  Future<int> getContextSize(int contextHandle) async => contextSize;

  @override
  Stream<List<int>> generate(
    int contextHandle,
    String prompt,
    GenerationParams params, {
    List<LlamaContentPart>? parts,
  }) async* {
    lastPrompt = prompt;
    if (_generateCallCount < _responses.length) {
      yield utf8.encode(_responses[_generateCallCount++]);
    } else {
      yield utf8.encode('default response');
    }
  }

  @override
  void cancelGeneration() {}

  @override
  Future<List<int>> tokenize(
    int modelHandle,
    String text, {
    bool addSpecial = true,
  }) async {
    tokenizeCalls += 1;
    if (!supportsTokenization) {
      throw UnsupportedError('tokenization unavailable');
    }
    return List.generate(text.length, (i) => i);
  }

  @override
  Future<String> detokenize(
    int modelHandle,
    List<int> tokens, {
    bool special = false,
  }) async => 'decoded';

  @override
  Future<Map<String, String>> modelMetadata(int modelHandle) async => {
    'tokenizer.chat_template':
        '{{ bos_token }}{% for message in messages %}{% if message["role"] == "user" %}{{ "user: " }}{% for part in message["content"] %}{% if part["type"] == "text" %}{{ part["text"] }}{% elif part["type"] == "image" %}{{ "<__media__>" }}{% endif %}{% endfor %}{% elif message["role"] == "assistant" %}{{ "assistant: " + message["content"] }}{% endif %}{% endfor %}{% if add_generation_prompt %}{{ "assistant: " }}{% endif %}',
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
  Future<String> getBackendName() async => 'Mock';
  @override
  Future<String> getAvailableBackends() async => 'Mock';
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
  Future<({int total, int free})> getVramInfo() async =>
      (total: 8192, free: 4096);

  @override
  Future<String> applyChatTemplate(
    int modelHandle,
    List<Map<String, dynamic>> messages, {
    String? customTemplate,
    bool addAssistant = true,
  }) async {
    return messages.map((m) => "${m['role']}: ${m['content']}").join('\n');
  }
}

void main() {
  late MockLlamaBackend backend;
  late LlamaEngine engine;
  late ChatSession session;

  setUp(() async {
    backend = MockLlamaBackend();
    engine = LlamaEngine(backend);
    await engine.loadModel('qwen-test.gguf');
    session = ChatSession(engine);
  });

  group('ChatSession Mock Tests', () {
    test('onMessageAdded callback', () async {
      final added = <LlamaChatMessage>[];
      backend.queueResponse('Resp');
      await session.create([
        const LlamaTextContent('Hi'),
      ], onMessageAdded: (m) => added.add(m)).drain();
      expect(added.length, 2);
    });

    test('enforceContextLimit truncation', () async {
      backend.contextSize = 400;
      session.maxContextTokens = 400;
      for (int i = 0; i < 20; i++) {
        backend.queueResponse('R');
        await session.create([LlamaTextContent('M' * 50)]).drain();
      }
      expect(session.history, isNotEmpty);
      expect(session.history.length, lessThan(40));
    });

    test('enforceContextLimit trims with bounded template passes', () async {
      backend.contextSize = 420;
      session.maxContextTokens = 420;

      for (int i = 0; i < 16; i++) {
        final userText = 'U$i ${List.filled(40, 'x').join()}';
        final assistantText = 'A$i ${List.filled(40, 'y').join()}';
        session.addMessage(
          LlamaChatMessage.fromText(role: LlamaChatRole.user, text: userText),
        );
        session.addMessage(
          LlamaChatMessage.fromText(
            role: LlamaChatRole.assistant,
            text: assistantText,
          ),
        );
      }

      final beforeCount = backend.tokenizeCalls;
      backend.queueResponse('ok');
      await session.create(const []).drain();
      final trimTemplateCalls = backend.tokenizeCalls - beforeCount;

      expect(trimTemplateCalls, lessThan(10));
      expect(session.history.length, lessThan(33));
    });

    test(
      'enforceContextLimit uses estimated count when tokenization is missing',
      () async {
        backend.supportsTokenization = false;
        session.maxContextTokens = 512;

        for (int i = 0; i < 12; i++) {
          session.addMessage(
            LlamaChatMessage.fromText(
              role: LlamaChatRole.user,
              text: 'U$i ${List.filled(120, 'x').join()}',
            ),
          );
          session.addMessage(
            LlamaChatMessage.fromText(
              role: LlamaChatRole.assistant,
              text: 'A$i ${List.filled(120, 'y').join()}',
            ),
          );
        }

        backend.queueResponse('ok');
        await session.create(const [LlamaTextContent('new turn')]).drain();

        expect(backend.tokenizeCalls, greaterThan(0));
        expect(backend.lastPrompt, isNotNull);
        expect(
          session.history.any((message) => message.content == 'new turn'),
          isTrue,
        );
        expect(session.history.length, lessThan(26));
      },
    );

    test('multimodal marker injection', () async {
      final msg = LlamaChatMessage.withContent(
        role: LlamaChatRole.user,
        content: [
          LlamaImageContent(bytes: Uint8List.fromList([1, 2, 3])),
          const LlamaTextContent('What is this?'),
        ],
      );
      session.addMessage(msg);
      backend.queueResponse('An image');

      await session.create([const LlamaTextContent('Explain')]).drain();

      expect(backend.lastPrompt, contains('<__media__>'));
    });

    test(
      'tools are passed to engine',
      skip: 'Native template does not support tools yet',
      () async {
        final tools = [
          ToolDefinition(
            name: 'test_tool',
            description: 'A test tool',
            handler: (p) async => 'result',
            parameters: [],
          ),
        ];

        backend.queueResponse('I will call the tool');
        await session.create([
          const LlamaTextContent('use the tool'),
        ], tools: tools).drain();

        // Verify tool definitions were injected into prompt
        expect(backend.lastPrompt, contains('test_tool'));
        expect(backend.lastPrompt, contains('A test tool'));
      },
    );
  });
}
