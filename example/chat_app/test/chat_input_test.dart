import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_chat_example/models/chat_settings.dart';
import 'package:llamadart_chat_example/providers/chat_provider.dart';
import 'package:llamadart_chat_example/widgets/chat_input.dart';
import 'package:provider/provider.dart';

import 'mocks.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('composer stays editable while generation is running', (
    tester,
  ) async {
    final provider = _GeneratingReadyProvider();
    addTearDown(provider.dispose);

    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<ChatProvider>.value(
        value: provider,
        child: MaterialApp(
          home: Scaffold(
            body: ChatInput(
              controller: controller,
              focusNode: focusNode,
              onSend: () {},
            ),
          ),
        ),
      ),
    );

    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);

    await tester.enterText(find.byType(TextField), 'draft next prompt');
    expect(controller.text, 'draft next prompt');
  });

  testWidgets('uses mobile submit behavior without desktop shortcut copy', (
    tester,
  ) async {
    final oldSize = tester.view.physicalSize;
    final oldRatio = tester.view.devicePixelRatio;
    tester.view
      ..physicalSize = const Size(390, 844)
      ..devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view
        ..physicalSize = oldSize
        ..devicePixelRatio = oldRatio;
    });

    final provider = _GeneratingReadyProvider();
    addTearDown(provider.dispose);
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<ChatProvider>.value(
        value: provider,
        child: MaterialApp(
          home: Scaffold(
            body: ChatInput(
              controller: controller,
              focusNode: focusNode,
              onSend: () {},
            ),
          ),
        ),
      ),
    );

    final textField = tester.widget<TextField>(find.byType(TextField));
    expect(textField.textInputAction, TextInputAction.send);
    expect(find.textContaining('Cmd/Ctrl'), findsNothing);
    expect(find.textContaining('option + enter'), findsNothing);
    expect(find.text('Ask anything…'), findsOneWidget);
  });

  testWidgets('shows audio attachment for direct-media native models', (
    tester,
  ) async {
    final provider = ChatProvider(
      chatService: MockChatService(),
      settingsService: MockSettingsService(),
      initialSettings: const ChatSettings(
        modelPath: 'gemma-4-E2B-it.litertlm',
        modelSupportsAudio: true,
        directMediaInput: true,
      ),
    );
    addTearDown(provider.dispose);
    await provider.loadModel();

    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<ChatProvider>.value(
        value: provider,
        child: MaterialApp(
          home: Scaffold(
            body: ChatInput(
              controller: controller,
              focusNode: focusNode,
              onSend: () {},
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Add attachment'));
    await tester.pumpAndSettle();

    expect(find.text('Paste attachment'), findsOneWidget);
    expect(find.text('Attach Audio'), findsOneWidget);
    expect(find.text('Transcribe Audio'), findsNothing);
    expect(find.text('Attach Image'), findsNothing);
  });

  testWidgets('shows dedicated transcription for native ASR models', (
    tester,
  ) async {
    final engine = _SpeechMockLlamaEngine();
    final provider = ChatProvider(
      chatService: MockChatService(engine: engine),
      settingsService: MockSettingsService(),
      initialSettings: const ChatSettings(
        modelPath: 'Qwen3-ASR-0.6B-Q8_0.gguf',
        mmprojPath: 'mmproj-Qwen3-ASR-0.6B-Q8_0.gguf',
        modelSupportsSpeechToText: true,
      ),
    );
    addTearDown(provider.dispose);
    await provider.loadModel();

    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<ChatProvider>.value(
        value: provider,
        child: MaterialApp(
          home: Scaffold(
            body: ChatInput(
              controller: controller,
              focusNode: focusNode,
              onSend: () {},
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Add attachment'));
    await tester.pumpAndSettle();

    expect(find.text('Attach Audio'), findsOneWidget);
    expect(find.text('Transcribe Audio'), findsOneWidget);
  });

  test('transcribes an in-memory audio file into chat', () async {
    final engine = _SpeechMockLlamaEngine()
      ..createChunkContents = const <String>[
        'language English<asr_text>Recognized ',
        'speech.',
      ];
    final provider = ChatProvider(
      chatService: MockChatService(engine: engine),
      settingsService: MockSettingsService(),
      initialSettings: const ChatSettings(
        modelPath: 'Qwen3-ASR-0.6B-Q8_0.gguf',
        mmprojPath: 'mmproj-Qwen3-ASR-0.6B-Q8_0.gguf',
        modelSupportsSpeechToText: true,
      ),
    );
    addTearDown(provider.dispose);
    await provider.loadModel();

    await provider.transcribeAudio(
      SpeechAudioBytesInput(Uint8List.fromList(const <int>[1, 2, 3])),
      displayName: 'fixture.wav',
    );

    expect(provider.isTranscribing, isFalse);
    expect(provider.isGenerating, isFalse);
    expect(engine.createCalls, 1);
    expect(
      provider.messages.where((message) => !message.isInfo).map((m) => m.text),
      <String>['Transcribe audio: fixture.wav', 'Recognized speech.'],
    );
    expect(provider.messages.last.debugBadges, contains('Transcription'));
    expect(provider.messages.last.generatedTokenCount, 5);
    expect(provider.currentTokens, 5);
    expect(provider.canRegenerateLastResponse, isFalse);
  });

  test('does not overlap a stopped transcription while it settles', () async {
    final engine = _BlockingSpeechMockLlamaEngine();
    final provider = ChatProvider(
      chatService: MockChatService(engine: engine),
      settingsService: MockSettingsService(),
      initialSettings: const ChatSettings(
        modelPath: 'Qwen3-ASR-0.6B-Q8_0.gguf',
        mmprojPath: 'mmproj-Qwen3-ASR-0.6B-Q8_0.gguf',
        modelSupportsSpeechToText: true,
      ),
    );
    addTearDown(provider.dispose);
    await provider.loadModel();

    final first = provider.transcribeAudio(
      SpeechAudioBytesInput(Uint8List.fromList(const <int>[1, 2, 3])),
      displayName: 'first.wav',
    );
    await engine.createStarted.future;

    provider.stopGeneration();
    expect(provider.isTranscribing, isTrue);
    expect(provider.canTranscribeAudio, isFalse);
    await provider.transcribeAudio(
      SpeechAudioBytesInput(Uint8List.fromList(const <int>[4, 5, 6])),
      displayName: 'second.wav',
    );
    expect(engine.createCalls, 1);

    engine.releaseGeneration();
    await first;
    expect(provider.isTranscribing, isFalse);
  });

  test('reserves transcription before the projector probe completes', () async {
    final engine = _BlockingAudioProbeSpeechMockLlamaEngine();
    final provider = ChatProvider(
      chatService: MockChatService(engine: engine),
      settingsService: MockSettingsService(),
      initialSettings: const ChatSettings(
        modelPath: 'Qwen3-ASR-0.6B-Q8_0.gguf',
        mmprojPath: 'mmproj-Qwen3-ASR-0.6B-Q8_0.gguf',
        modelSupportsSpeechToText: true,
      ),
    );
    addTearDown(provider.dispose);
    await provider.loadModel();
    engine.blockAudioProbe = true;

    final first = provider.transcribeAudio(
      SpeechAudioBytesInput(Uint8List.fromList(const <int>[1, 2, 3])),
      displayName: 'first.wav',
    );
    await engine.audioProbeStarted.future;

    expect(provider.isTranscribing, isTrue);
    await provider.transcribeAudio(
      SpeechAudioBytesInput(Uint8List.fromList(const <int>[4, 5, 6])),
      displayName: 'second.wav',
    );
    expect(engine.createCalls, 0);

    provider.stopGeneration();
    engine.releaseAudioProbe();
    await first;
    expect(provider.isTranscribing, isFalse);
    expect(engine.createCalls, 0);
  });

  test('clear suppresses stale transcription completion', () async {
    final engine = _BlockingSpeechMockLlamaEngine();
    final provider = ChatProvider(
      chatService: MockChatService(engine: engine),
      settingsService: MockSettingsService(),
      initialSettings: const ChatSettings(
        modelPath: 'Qwen3-ASR-0.6B-Q8_0.gguf',
        mmprojPath: 'mmproj-Qwen3-ASR-0.6B-Q8_0.gguf',
        modelSupportsSpeechToText: true,
      ),
    );
    addTearDown(provider.dispose);
    await provider.loadModel();

    final transcription = provider.transcribeAudio(
      SpeechAudioBytesInput(Uint8List.fromList(const <int>[1, 2, 3])),
      displayName: 'fixture.wav',
    );
    await engine.createStarted.future;

    provider.clearConversation();
    final clearedMessages = provider.messages.map((message) => message.text);
    expect(clearedMessages, <String>[
      'Conversation cleared. Ready for a new topic!',
    ]);

    engine.releaseGeneration();
    await transcription;
    expect(provider.messages.map((message) => message.text), <String>[
      'Conversation cleared. Ready for a new topic!',
    ]);
    expect(provider.currentTokens, 0);
  });

  test('stages clipboard media bytes for the next message', () async {
    final provider = ChatProvider(
      chatService: MockChatService(),
      settingsService: MockSettingsService(),
      initialSettings: const ChatSettings(modelPath: 'test_model.gguf'),
    );
    addTearDown(provider.dispose);

    expect(await provider.stageImageAttachment(Uint8List(0)), isFalse);
    expect(provider.stageAudioAttachment(Uint8List(0)), isFalse);

    final imageBytes = Uint8List.fromList(const [1, 2, 3]);
    final audioBytes = Uint8List.fromList(const [4, 5, 6]);
    expect(await provider.stageImageAttachment(imageBytes), isTrue);
    expect(provider.stageAudioAttachment(audioBytes), isTrue);

    expect(provider.stagedParts, hasLength(2));
    expect(provider.stagedParts.first, isA<LlamaImageContent>());
    expect(provider.stagedParts.last, isA<LlamaAudioContent>());
  });
}

class _GeneratingReadyProvider extends ChatProvider {
  _GeneratingReadyProvider()
    : super(
        chatService: MockChatService(),
        settingsService: MockSettingsService(),
        initialSettings: const ChatSettings(modelPath: 'test_model.gguf'),
      );

  @override
  bool get isGenerating => true;

  @override
  bool get isReady => true;

  @override
  bool get toolsEnabled => false;

  @override
  bool get canAttachMedia => false;

  @override
  List<LlamaContentPart> get stagedParts => const <LlamaContentPart>[];
}

class _SpeechMockLlamaEngine extends MockLlamaEngine {
  @override
  Future<bool> get supportsAudio async => mmprojLoaded;
}

class _BlockingSpeechMockLlamaEngine extends _SpeechMockLlamaEngine {
  final Completer<void> createStarted = Completer<void>();
  final Completer<void> _release = Completer<void>();

  void releaseGeneration() {
    if (!_release.isCompleted) {
      _release.complete();
    }
  }

  @override
  Stream<LlamaCompletionChunk> create(
    List<LlamaChatMessage> messages, {
    GenerationParams? params,
    List<ToolDefinition>? tools,
    ToolChoice? toolChoice,
    bool parallelToolCalls = false,
    bool enableThinking = true,
    Map<String, dynamic>? responseFormat,
    String? sourceLangCode,
    String? targetLangCode,
    Map<String, dynamic>? chatTemplateKwargs,
    DateTime? templateNow,
  }) async* {
    createCalls += 1;
    lastCreateParams = params;
    if (!createStarted.isCompleted) {
      createStarted.complete();
    }
    await _release.future;
    for (final content in createChunkContents) {
      yield LlamaCompletionChunk(
        id: 'mock-id',
        object: 'chat.completion.chunk',
        created: 1234567890,
        model: 'mock-model',
        choices: <LlamaCompletionChunkChoice>[
          LlamaCompletionChunkChoice(
            index: 0,
            delta: LlamaCompletionChunkDelta(content: content),
          ),
        ],
      );
    }
  }
}

class _BlockingAudioProbeSpeechMockLlamaEngine extends _SpeechMockLlamaEngine {
  final Completer<void> audioProbeStarted = Completer<void>();
  final Completer<void> _releaseAudioProbe = Completer<void>();
  bool blockAudioProbe = false;

  void releaseAudioProbe() {
    if (!_releaseAudioProbe.isCompleted) {
      _releaseAudioProbe.complete();
    }
  }

  @override
  Future<bool> get supportsAudio async {
    if (blockAudioProbe) {
      if (!audioProbeStarted.isCompleted) {
        audioProbeStarted.complete();
      }
      await _releaseAudioProbe.future;
    }
    return super.supportsAudio;
  }
}
