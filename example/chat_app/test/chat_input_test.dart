import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_chat_example/models/chat_settings.dart';
import 'package:llamadart_chat_example/providers/chat_provider.dart';
import 'package:llamadart_chat_example/services/audio_recording_service.dart';
import 'package:llamadart_chat_example/services/chat_generation_service.dart';
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

  testWidgets('keeps a supported microphone action visible while busy', (
    tester,
  ) async {
    final provider = _BusyVoiceProvider();
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

    expect(find.byTooltip('Ask with voice'), findsOneWidget);
    final button = tester.widget<IconButton>(
      find.byKey(const ValueKey<String>('record_audio_button')),
    );
    expect(button.onPressed, isNull);
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

  testWidgets('shows Ask with voice for direct-media native models', (
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
    expect(find.byTooltip('Ask with voice'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Ask with voice. Records up to 30 seconds.'),
      findsOneWidget,
    );
  });

  testWidgets('microphone controls stop and ask from the composer', (
    tester,
  ) async {
    final oldSize = tester.view.physicalSize;
    final oldRatio = tester.view.devicePixelRatio;
    tester.view
      ..physicalSize = const Size(320, 700)
      ..devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view
        ..physicalSize = oldSize
        ..devicePixelRatio = oldRatio;
    });

    final engine = MockLlamaEngine()..createChunkContents = const <String>[];
    final recorder = _FakeAudioRecordingService();
    final provider = ChatProvider(
      chatService: MockChatService(engine: engine),
      audioRecordingService: recorder,
      chatGenerationService: const _ImmediateChatGenerationService(),
      settingsService: MockSettingsService(),
      initialSettings: const ChatSettings(
        modelPath: 'gemma-4-E2B-it.litertlm',
        modelSupportsAudio: true,
        directMediaInput: true,
      ),
    );
    addTearDown(provider.dispose);
    await provider.loadModel();

    final controller = TextEditingController(text: 'keep this draft');
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

    await tester.tap(find.byTooltip('Ask with voice'));
    await tester.pumpAndSettle();

    expect(find.text('Recording voice question 0:00 / 0:30'), findsOneWidget);
    expect(find.text('Discard'), findsOneWidget);
    expect(find.text('Stop & ask'), findsOneWidget);
    expect(find.text('Stop & transcribe'), findsNothing);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);

    await tester.tap(find.text('Stop & ask'));
    var sawVoiceGeneration = false;
    for (var index = 0; index < 120; index++) {
      await tester.pump(const Duration(milliseconds: 16));
      sawVoiceGeneration = sawVoiceGeneration || provider.isGenerating;
      if (sawVoiceGeneration &&
          engine.createCalls > 0 &&
          !provider.isGenerating) {
        break;
      }
    }

    expect(find.byKey(const ValueKey('audio_recording_status')), findsNothing);
    expect(find.byTooltip('Ask with voice'), findsOneWidget);
    expect(controller.text, 'keep this draft');
    expect(engine.createCalls, 1);
    expect(recorder.deletedPaths, <String>[recorder.recordedPath]);
    final conversationMessages = provider.messages
        .where((message) => !message.isInfo)
        .toList(growable: false);
    expect(conversationMessages[0].text, 'Voice question');
    final audio = conversationMessages[0].parts!
        .whereType<LlamaAudioContent>()
        .single;
    expect(audio.path, isNull);
    expect(audio.bytes, recorder.recordedBytes);
    provider.stopGeneration();
    await tester.pumpAndSettle();
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
    expect(find.byTooltip('Record for transcription'), findsOneWidget);
    expect(find.bySemanticsLabel('Record for transcription.'), findsOneWidget);
  });

  testWidgets('microphone controls stop and transcribe from the composer', (
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

    final engine = _SpeechMockLlamaEngine()
      ..createChunkContents = const <String>[
        'language English<asr_text>Composer recording.',
      ];
    final recorder = _FakeAudioRecordingService();
    final provider = ChatProvider(
      chatService: MockChatService(engine: engine),
      audioRecordingService: recorder,
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

    await tester.tap(find.byTooltip('Record for transcription'));
    await tester.pumpAndSettle();

    expect(
      find.text('Recording for transcription 0:00 / 5:00'),
      findsOneWidget,
    );
    expect(find.text('Discard'), findsOneWidget);
    expect(find.text('Stop & transcribe'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);

    await tester.tap(find.text('Stop & transcribe'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('audio_recording_status')), findsNothing);
    expect(find.byTooltip('Record for transcription'), findsOneWidget);
    expect(engine.createCalls, 1);
    expect(recorder.deletedPaths, <String>[recorder.recordedPath]);
  });

  test('records, transcribes, and deletes the temporary WAV', () async {
    final engine = _SpeechMockLlamaEngine()
      ..createChunkContents = const <String>[
        'language English<asr_text>Recorded speech.',
      ];
    final recorder = _FakeAudioRecordingService();
    final provider = ChatProvider(
      chatService: MockChatService(engine: engine),
      audioRecordingService: recorder,
      settingsService: MockSettingsService(),
      initialSettings: const ChatSettings(
        modelPath: 'Qwen3-ASR-0.6B-Q8_0.gguf',
        mmprojPath: 'mmproj-Qwen3-ASR-0.6B-Q8_0.gguf',
        modelSupportsSpeechToText: true,
      ),
    );
    addTearDown(provider.dispose);
    await provider.loadModel();

    await provider.startAudioRecording();
    expect(provider.audioRecordingState, ChatAudioRecordingState.recording);
    expect(provider.canTranscribeAudio, isFalse);
    expect(recorder.startCalls, 1);

    await provider.stopAudioRecordingAndTranscribe();

    expect(recorder.stopCalls, 1);
    expect(recorder.deletedPaths, <String>[recorder.recordedPath]);
    expect(provider.audioRecordingState, ChatAudioRecordingState.idle);
    expect(engine.createCalls, 1);
    expect(
      provider.messages.where((message) => !message.isInfo).map((m) => m.text),
      <String>['Transcribe audio: Microphone recording', 'Recorded speech.'],
    );
  });

  test(
    'records a byte-backed voice turn without consuming staged attachments',
    () async {
      final engine = MockLlamaEngine()
        ..createChunkContents = const <String>['A direct answer.'];
      final recorder = _FakeAudioRecordingService();
      final provider = ChatProvider(
        chatService: MockChatService(engine: engine),
        audioRecordingService: recorder,
        settingsService: MockSettingsService(),
        initialSettings: const ChatSettings(
          modelPath: 'gemma-4-E2B-it.litertlm',
          modelSupportsAudio: true,
          directMediaInput: true,
        ),
      );
      addTearDown(provider.dispose);
      await provider.loadModel();
      final stagedBytes = Uint8List.fromList(const <int>[9, 8, 7]);
      expect(provider.stageAudioAttachment(stagedBytes), isTrue);

      expect(provider.canAskWithVoice, isTrue);
      await provider.startAudioRecording();
      expect(
        provider.audioRecordingPurpose,
        ChatAudioRecordingPurpose.voiceQuestion,
      );
      await provider.stopAudioRecordingAndAsk();

      expect(recorder.readCalls, 1);
      expect(recorder.deletedPaths, <String>[recorder.recordedPath]);
      expect(engine.createCalls, 1);
      expect(provider.stagedParts, hasLength(1));
      expect(
        (provider.stagedParts.single as LlamaAudioContent).bytes,
        stagedBytes,
      );
      final userMessage = provider.messages.firstWhere(
        (message) => message.isUser && !message.isInfo,
      );
      expect(userMessage.text, 'Voice question');
      final storedAudio = userMessage.parts!
          .whereType<LlamaAudioContent>()
          .single;
      expect(storedAudio.path, isNull);
      expect(storedAudio.bytes, recorder.recordedBytes);
      expect(
        userMessage.parts!.whereType<LlamaTextContent>().single.text,
        contains('solve that request'),
      );

      final generatedUserTurn = engine.lastCreateMessages!.last;
      expect(generatedUserTurn.role, LlamaChatRole.user);
      expect(
        generatedUserTurn.parts.whereType<LlamaAudioContent>().single.bytes,
        recorder.recordedBytes,
      );
      expect(
        generatedUserTurn.parts.whereType<LlamaTextContent>().single.text,
        contains('solve that request'),
      );
    },
  );

  test(
    'regenerating a voice answer keeps the hidden model instruction',
    () async {
      final engine = MockLlamaEngine()
        ..createChunkContents = const <String>['First answer.'];
      final provider = ChatProvider(
        chatService: MockChatService(engine: engine),
        settingsService: MockSettingsService(),
        initialSettings: const ChatSettings(
          modelPath: 'gemma-4-E2B-it.litertlm',
          modelSupportsAudio: true,
          directMediaInput: true,
        ),
      );
      addTearDown(provider.dispose);
      await provider.loadModel();

      await provider.askWithVoice(Uint8List.fromList(const <int>[1, 2, 3]));
      expect(provider.canRegenerateLastResponse, isTrue);

      engine.createChunkContents = const <String>['Second answer.'];
      await provider.regenerateLastResponse();

      expect(engine.createCalls, 2);
      final regeneratedUserTurn = engine.lastCreateMessages!.last;
      expect(
        regeneratedUserTurn.parts.whereType<LlamaTextContent>().single.text,
        contains('solve that request'),
      );
      expect(
        regeneratedUserTurn.parts.whereType<LlamaAudioContent>().single.bytes,
        <int>[1, 2, 3],
      );
    },
  );

  test('external-projector audio can answer a recorded question', () async {
    final engine = _SpeechMockLlamaEngine()
      ..createChunkContents = const <String>['4'];
    final recorder = _FakeAudioRecordingService();
    final provider = ChatProvider(
      chatService: MockChatService(engine: engine),
      audioRecordingService: recorder,
      settingsService: MockSettingsService(),
      initialSettings: const ChatSettings(
        modelPath: 'gemma-4-E2B-it-Q4_K_S.gguf',
        mmprojPath: 'gemma-4-E2B-it-mmproj-F16.gguf',
        modelSupportsAudio: true,
      ),
    );
    addTearDown(provider.dispose);
    await provider.loadModel();

    expect(provider.supportsAudio, isTrue);
    expect(provider.canAskWithVoice, isTrue);
    expect(provider.supportsMicrophoneRecording, isTrue);

    await provider.startAudioRecording();
    expect(
      provider.audioRecordingPurpose,
      ChatAudioRecordingPurpose.voiceQuestion,
    );
    await provider.stopAudioRecordingAndAsk();

    expect(engine.createCalls, 1);
    expect(recorder.deletedPaths, <String>[recorder.recordedPath]);
    final generatedUserTurn = engine.lastCreateMessages!.last;
    expect(
      generatedUserTurn.parts.whereType<LlamaAudioContent>().single.bytes,
      recorder.recordedBytes,
    );
    expect(
      generatedUserTurn.parts.whereType<LlamaTextContent>().single.text,
      'Listen carefully to every spoken word. Determine what the speaker is '
      'asking, solve that request, and return only the final answer. Do not '
      'merely repeat a word from the recording.',
    );

    provider.updateMmprojPath('replacement-mmproj.gguf');
    expect(provider.canAskWithVoice, isFalse);
    expect(provider.supportsMicrophoneRecording, isFalse);
  });

  test('external-projector voice requires a configured projector', () async {
    final provider = ChatProvider(
      chatService: MockChatService(engine: _AlwaysAudioMockLlamaEngine()),
      audioRecordingService: _FakeAudioRecordingService(),
      settingsService: MockSettingsService(),
      initialSettings: const ChatSettings(
        modelPath: 'audio-chat.gguf',
        modelSupportsAudio: true,
      ),
    );
    addTearDown(provider.dispose);
    await provider.loadModel();

    expect(provider.supportsAudio, isTrue);
    expect(provider.canAskWithVoice, isFalse);
    expect(provider.supportsMicrophoneRecording, isFalse);
  });

  test('external-projector voice requires runtime audio support', () async {
    final provider = ChatProvider(
      chatService: MockChatService(),
      audioRecordingService: _FakeAudioRecordingService(),
      settingsService: MockSettingsService(),
      initialSettings: const ChatSettings(
        modelPath: 'audio-chat.gguf',
        mmprojPath: 'audio-mmproj.gguf',
        modelSupportsAudio: true,
      ),
    );
    addTearDown(provider.dispose);
    await provider.loadModel();

    expect(provider.settings.modelSupportsAudio, isTrue);
    expect(provider.supportsAudio, isFalse);
    expect(provider.canAskWithVoice, isFalse);
    expect(provider.supportsMicrophoneRecording, isFalse);
  });

  test('dedicated STT takes precedence over direct audio chat', () async {
    final recorder = _FakeAudioRecordingService();
    final provider = ChatProvider(
      chatService: MockChatService(engine: _SpeechMockLlamaEngine()),
      audioRecordingService: recorder,
      settingsService: MockSettingsService(),
      initialSettings: const ChatSettings(
        modelPath: 'Qwen3-ASR-0.6B-Q8_0.gguf',
        mmprojPath: 'mmproj-Qwen3-ASR-0.6B-Q8_0.gguf',
        modelSupportsAudio: true,
        modelSupportsSpeechToText: true,
      ),
    );
    addTearDown(provider.dispose);
    await provider.loadModel();

    expect(provider.canTranscribeAudio, isTrue);
    expect(provider.canAskWithVoice, isFalse);
    await provider.startAudioRecording();
    expect(
      provider.audioRecordingPurpose,
      ChatAudioRecordingPurpose.transcription,
    );
    await provider.cancelAudioRecording(showMessage: false);
  });

  test('voice WAV read failure deletes the file without generation', () async {
    final engine = MockLlamaEngine();
    final recorder = _FakeAudioRecordingService(
      readError: const AudioRecordingException(
        AudioRecordingFailure.readFailed,
        'The test recording could not be read.',
      ),
    );
    final provider = ChatProvider(
      chatService: MockChatService(engine: engine),
      audioRecordingService: recorder,
      settingsService: MockSettingsService(),
      initialSettings: const ChatSettings(
        modelPath: 'gemma-4-E2B-it.litertlm',
        modelSupportsAudio: true,
        directMediaInput: true,
      ),
    );
    addTearDown(provider.dispose);
    await provider.loadModel();
    await provider.startAudioRecording();

    await provider.stopAudioRecordingAndAsk();

    expect(engine.createCalls, 0);
    expect(provider.isGenerating, isFalse);
    expect(provider.audioRecordingState, ChatAudioRecordingState.idle);
    expect(recorder.deletedPaths, <String>[recorder.recordedPath]);
    expect(
      provider.messages.last.text,
      'The test recording could not be read.',
    );
  });

  test('reports microphone permission denial without starting STT', () async {
    final engine = _SpeechMockLlamaEngine();
    final recorder = _FakeAudioRecordingService(
      startError: const AudioRecordingException(
        AudioRecordingFailure.permissionDenied,
        'Microphone permission was denied for this test.',
      ),
    );
    final provider = ChatProvider(
      chatService: MockChatService(engine: engine),
      audioRecordingService: recorder,
      settingsService: MockSettingsService(),
      initialSettings: const ChatSettings(
        modelPath: 'Qwen3-ASR-0.6B-Q8_0.gguf',
        mmprojPath: 'mmproj-Qwen3-ASR-0.6B-Q8_0.gguf',
        modelSupportsSpeechToText: true,
      ),
    );
    addTearDown(provider.dispose);
    await provider.loadModel();

    await provider.startAudioRecording();

    expect(provider.audioRecordingState, ChatAudioRecordingState.idle);
    expect(engine.createCalls, 0);
    expect(
      provider.messages.last.text,
      'Microphone permission was denied for this test.',
    );
  });

  test('does not advertise an unsupported platform recorder', () async {
    final engine = _SpeechMockLlamaEngine();
    final recorder = _FakeAudioRecordingService(supported: false);
    final provider = ChatProvider(
      chatService: MockChatService(engine: engine),
      audioRecordingService: recorder,
      settingsService: MockSettingsService(),
      initialSettings: const ChatSettings(
        modelPath: 'Qwen3-ASR-0.6B-Q8_0.gguf',
        mmprojPath: 'mmproj-Qwen3-ASR-0.6B-Q8_0.gguf',
        modelSupportsSpeechToText: true,
      ),
    );
    addTearDown(provider.dispose);
    await provider.loadModel();

    expect(provider.canStartAudioRecording, isFalse);
    await provider.startAudioRecording();

    expect(recorder.startCalls, 0);
    expect(
      provider.messages.last.text,
      'Microphone recording is unavailable on this platform.',
    );
  });

  test('reserves microphone startup before awaiting permission', () async {
    final engine = _SpeechMockLlamaEngine();
    final startGate = Completer<void>();
    final recorder = _FakeAudioRecordingService(startGate: startGate);
    final provider = ChatProvider(
      chatService: MockChatService(engine: engine),
      audioRecordingService: recorder,
      settingsService: MockSettingsService(),
      initialSettings: const ChatSettings(
        modelPath: 'Qwen3-ASR-0.6B-Q8_0.gguf',
        mmprojPath: 'mmproj-Qwen3-ASR-0.6B-Q8_0.gguf',
        modelSupportsSpeechToText: true,
      ),
    );
    addTearDown(provider.dispose);
    await provider.loadModel();

    final first = provider.startAudioRecording();
    expect(provider.audioRecordingState, ChatAudioRecordingState.starting);
    await provider.startAudioRecording();
    expect(recorder.startCalls, 1);

    startGate.complete();
    await first;
    expect(provider.audioRecordingState, ChatAudioRecordingState.recording);
    await provider.cancelAudioRecording(showMessage: false);
  });

  test('cancellation wins while microphone startup is pending', () async {
    final engine = _SpeechMockLlamaEngine();
    final startGate = Completer<void>();
    final recorder = _FakeAudioRecordingService(startGate: startGate);
    final provider = ChatProvider(
      chatService: MockChatService(engine: engine),
      audioRecordingService: recorder,
      settingsService: MockSettingsService(),
      initialSettings: const ChatSettings(
        modelPath: 'Qwen3-ASR-0.6B-Q8_0.gguf',
        mmprojPath: 'mmproj-Qwen3-ASR-0.6B-Q8_0.gguf',
        modelSupportsSpeechToText: true,
      ),
    );
    addTearDown(provider.dispose);
    await provider.loadModel();

    final start = provider.startAudioRecording();
    final cancel = provider.cancelAudioRecording(showMessage: false);
    expect(provider.audioRecordingState, ChatAudioRecordingState.cancelling);

    startGate.complete();
    await Future.wait(<Future<void>>[start, cancel]);

    expect(recorder.startCalls, 1);
    expect(recorder.cancelCalls, 1);
    expect(engine.createCalls, 0);
    expect(provider.audioRecordingState, ChatAudioRecordingState.idle);
  });

  test('discard cancels capture without transcribing', () async {
    final engine = _SpeechMockLlamaEngine();
    final recorder = _FakeAudioRecordingService();
    final provider = ChatProvider(
      chatService: MockChatService(engine: engine),
      audioRecordingService: recorder,
      settingsService: MockSettingsService(),
      initialSettings: const ChatSettings(
        modelPath: 'Qwen3-ASR-0.6B-Q8_0.gguf',
        mmprojPath: 'mmproj-Qwen3-ASR-0.6B-Q8_0.gguf',
        modelSupportsSpeechToText: true,
      ),
    );
    addTearDown(provider.dispose);
    await provider.loadModel();

    await provider.startAudioRecording();
    await provider.cancelAudioRecording();

    expect(recorder.cancelCalls, 1);
    expect(recorder.stopCalls, 0);
    expect(engine.createCalls, 0);
    expect(provider.audioRecordingState, ChatAudioRecordingState.idle);
    expect(provider.messages.last.text, 'Microphone recording cancelled.');
  });

  testWidgets('recording limit automatically stops and transcribes', (
    tester,
  ) async {
    final engine = _SpeechMockLlamaEngine()
      ..createChunkContents = const <String>[
        'language English<asr_text>Limited recording.',
      ];
    final recorder = _FakeAudioRecordingService();
    final provider = ChatProvider(
      chatService: MockChatService(engine: engine),
      audioRecordingService: recorder,
      settingsService: MockSettingsService(),
      initialSettings: const ChatSettings(
        modelPath: 'Qwen3-ASR-0.6B-Q8_0.gguf',
        mmprojPath: 'mmproj-Qwen3-ASR-0.6B-Q8_0.gguf',
        modelSupportsSpeechToText: true,
      ),
    );
    addTearDown(provider.dispose);
    await provider.loadModel();
    await provider.startAudioRecording();

    await tester.pump(ChatProvider.maxAudioRecordingDuration);
    await tester.pumpAndSettle();

    expect(recorder.stopCalls, 1);
    expect(engine.createCalls, 1);
    expect(provider.audioRecordingState, ChatAudioRecordingState.idle);
    expect(
      provider.messages.map((message) => message.text),
      contains(
        'Maximum recording length reached. Transcribing the recording now.',
      ),
    );
  });

  testWidgets('voice recording automatically asks at 30 seconds', (
    tester,
  ) async {
    final engine = MockLlamaEngine()..createChunkContents = const <String>[];
    final recorder = _FakeAudioRecordingService();
    final provider = ChatProvider(
      chatService: MockChatService(engine: engine),
      audioRecordingService: recorder,
      chatGenerationService: const _ImmediateChatGenerationService(),
      settingsService: MockSettingsService(),
      initialSettings: const ChatSettings(
        modelPath: 'gemma-4-E2B-it.litertlm',
        modelSupportsAudio: true,
        directMediaInput: true,
      ),
    );
    addTearDown(provider.dispose);
    await provider.loadModel();
    await provider.startAudioRecording();

    await tester.pump(ChatProvider.maxVoiceQuestionRecordingDuration);
    var sawAutomaticGeneration = false;
    for (var index = 0; index < 120; index++) {
      await tester.pump(const Duration(milliseconds: 16));
      sawAutomaticGeneration = sawAutomaticGeneration || provider.isGenerating;
      if (sawAutomaticGeneration &&
          engine.createCalls > 0 &&
          !provider.isGenerating) {
        break;
      }
    }

    expect(recorder.stopCalls, 1);
    expect(recorder.readCalls, 1);
    expect(engine.createCalls, 1);
    expect(provider.audioRecordingState, ChatAudioRecordingState.idle);
    expect(
      provider.messages.map((message) => message.text),
      contains('30-second limit reached. Asking the model now.'),
    );
    expect(
      provider.messages.map((message) => message.text),
      contains('Voice question'),
    );
    provider.stopGeneration();
    await tester.pumpAndSettle();
  });

  test('stop failure resets capture and reports an actionable error', () async {
    final engine = _SpeechMockLlamaEngine();
    final recorder = _FakeAudioRecordingService(
      stopError: const AudioRecordingException(
        AudioRecordingFailure.stopFailed,
        'The test recorder could not finalize audio.',
      ),
    );
    final provider = ChatProvider(
      chatService: MockChatService(engine: engine),
      audioRecordingService: recorder,
      settingsService: MockSettingsService(),
      initialSettings: const ChatSettings(
        modelPath: 'Qwen3-ASR-0.6B-Q8_0.gguf',
        mmprojPath: 'mmproj-Qwen3-ASR-0.6B-Q8_0.gguf',
        modelSupportsSpeechToText: true,
      ),
    );
    addTearDown(provider.dispose);
    await provider.loadModel();
    await provider.startAudioRecording();

    await provider.stopAudioRecordingAndTranscribe();

    expect(recorder.cancelCalls, 1);
    expect(engine.createCalls, 0);
    expect(provider.audioRecordingState, ChatAudioRecordingState.idle);
    expect(
      provider.messages.last.text,
      'The test recorder could not finalize audio.',
    );
  });

  test('unloading the model cancels an active recording first', () async {
    final engine = _SpeechMockLlamaEngine();
    final recorder = _FakeAudioRecordingService();
    final provider = ChatProvider(
      chatService: MockChatService(engine: engine),
      audioRecordingService: recorder,
      settingsService: MockSettingsService(),
      initialSettings: const ChatSettings(
        modelPath: 'Qwen3-ASR-0.6B-Q8_0.gguf',
        mmprojPath: 'mmproj-Qwen3-ASR-0.6B-Q8_0.gguf',
        modelSupportsSpeechToText: true,
      ),
    );
    addTearDown(provider.dispose);
    await provider.loadModel();
    await provider.startAudioRecording();

    await provider.unloadModel();

    expect(recorder.cancelCalls, 1);
    expect(provider.audioRecordingState, ChatAudioRecordingState.idle);
    expect(provider.isLoaded, isFalse);
  });

  test('clear wins a pending stop and deletes its stale WAV', () async {
    final engine = _SpeechMockLlamaEngine();
    final stopGate = Completer<void>();
    final recorder = _FakeAudioRecordingService(stopGate: stopGate);
    final provider = ChatProvider(
      chatService: MockChatService(engine: engine),
      audioRecordingService: recorder,
      settingsService: MockSettingsService(),
      initialSettings: const ChatSettings(
        modelPath: 'Qwen3-ASR-0.6B-Q8_0.gguf',
        mmprojPath: 'mmproj-Qwen3-ASR-0.6B-Q8_0.gguf',
        modelSupportsSpeechToText: true,
      ),
    );
    addTearDown(provider.dispose);
    await provider.loadModel();
    await provider.startAudioRecording();

    final stop = provider.stopAudioRecordingAndTranscribe();
    expect(provider.audioRecordingState, ChatAudioRecordingState.stopping);
    provider.clearConversation();
    expect(provider.audioRecordingState, ChatAudioRecordingState.cancelling);

    stopGate.complete();
    await stop;
    await provider.cancelAudioRecording(showMessage: false);

    expect(engine.createCalls, 0);
    expect(recorder.deletedPaths, <String>[recorder.recordedPath]);
    expect(provider.audioRecordingState, ChatAudioRecordingState.idle);
    expect(provider.messages.map((message) => message.text), <String>[
      'Conversation cleared. Ready for a new topic!',
    ]);
  });

  test('clear suppresses a late recording-cancelled message', () async {
    final engine = _SpeechMockLlamaEngine();
    final cancelGate = Completer<void>();
    final recorder = _FakeAudioRecordingService(cancelGate: cancelGate);
    final provider = ChatProvider(
      chatService: MockChatService(engine: engine),
      audioRecordingService: recorder,
      settingsService: MockSettingsService(),
      initialSettings: const ChatSettings(
        modelPath: 'Qwen3-ASR-0.6B-Q8_0.gguf',
        mmprojPath: 'mmproj-Qwen3-ASR-0.6B-Q8_0.gguf',
        modelSupportsSpeechToText: true,
      ),
    );
    addTearDown(provider.dispose);
    await provider.loadModel();
    await provider.startAudioRecording();

    final discard = provider.cancelAudioRecording();
    provider.clearConversation();
    cancelGate.complete();
    await discard;
    await provider.cancelAudioRecording(showMessage: false);

    expect(provider.messages.map((message) => message.text), <String>[
      'Conversation cleared. Ready for a new topic!',
    ]);
  });

  test('clear wins while finalized voice audio is being read', () async {
    final engine = MockLlamaEngine();
    final readGate = Completer<void>();
    final recorder = _FakeAudioRecordingService(readGate: readGate);
    final provider = ChatProvider(
      chatService: MockChatService(engine: engine),
      audioRecordingService: recorder,
      settingsService: MockSettingsService(),
      initialSettings: const ChatSettings(
        modelPath: 'gemma-4-E2B-it.litertlm',
        modelSupportsAudio: true,
        directMediaInput: true,
      ),
    );
    addTearDown(provider.dispose);
    await provider.loadModel();
    await provider.startAudioRecording();

    final ask = provider.stopAudioRecordingAndAsk();
    await Future<void>.delayed(Duration.zero);
    expect(recorder.readCalls, 1);
    expect(provider.isGenerating, isTrue);

    provider.clearConversation();
    readGate.complete();
    await ask;

    expect(engine.createCalls, 0);
    expect(recorder.deletedPaths, <String>[recorder.recordedPath]);
    expect(provider.isGenerating, isFalse);
    expect(provider.messages.map((message) => message.text), <String>[
      'Conversation cleared. Ready for a new topic!',
    ]);
  });

  for (final contextChange
      in <({String name, void Function(ChatProvider) run})>[
        (
          name: 'model path',
          run: (provider) => provider.updateModelPath('replacement.gguf'),
        ),
        (
          name: 'mmproj path',
          run: (provider) =>
              provider.updateMmprojPath('replacement-mmproj.gguf'),
        ),
      ]) {
    test(
      '${contextChange.name} change releases a pending voice read',
      () async {
        final engine = MockLlamaEngine();
        final readGate = Completer<void>();
        final recorder = _FakeAudioRecordingService(readGate: readGate);
        final provider = ChatProvider(
          chatService: MockChatService(engine: engine),
          audioRecordingService: recorder,
          settingsService: MockSettingsService(),
          initialSettings: const ChatSettings(
            modelPath: 'gemma-4-E2B-it.litertlm',
            modelSupportsAudio: true,
            directMediaInput: true,
          ),
        );
        addTearDown(provider.dispose);
        await provider.loadModel();
        await provider.startAudioRecording();

        final ask = provider.stopAudioRecordingAndAsk();
        await Future<void>.delayed(Duration.zero);
        expect(recorder.readCalls, 1);
        expect(provider.isGenerating, isTrue);

        contextChange.run(provider);
        expect(provider.isGenerating, isFalse);

        readGate.complete();
        await ask;

        expect(engine.createCalls, 0);
        expect(recorder.deletedPaths, <String>[recorder.recordedPath]);
        expect(provider.isGenerating, isFalse);
      },
    );
  }

  test('stale voice read cannot take ownership from a new text turn', () async {
    final engine = _BlockingSpeechMockLlamaEngine();
    final readGate = Completer<void>();
    final recorder = _FakeAudioRecordingService(readGate: readGate);
    final provider = ChatProvider(
      chatService: MockChatService(engine: engine),
      audioRecordingService: recorder,
      settingsService: MockSettingsService(),
      initialSettings: const ChatSettings(
        modelPath: 'gemma-4-E2B-it.litertlm',
        modelSupportsAudio: true,
        directMediaInput: true,
      ),
    );
    addTearDown(provider.dispose);
    await provider.loadModel();
    await provider.startAudioRecording();

    final ask = provider.stopAudioRecordingAndAsk();
    await Future<void>.delayed(Duration.zero);
    expect(recorder.readCalls, 1);

    provider.clearConversation();
    final freshTurn = provider.sendMessage('Fresh question');
    await engine.createStarted.future;
    expect(provider.isGenerating, isTrue);

    readGate.complete();
    await ask;

    expect(engine.createCalls, 1);
    expect(provider.isGenerating, isTrue);
    expect(
      provider.messages.where((message) => message.isUser).map((m) => m.text),
      <String>['Fresh question'],
    );

    engine.releaseGeneration();
    await freshTurn;
    expect(provider.isGenerating, isFalse);
  });

  for (final transition in <String>['clear', 'switch']) {
    test(
      'started voice generation cannot mutate or finish a fresh turn after $transition',
      () async {
        final engine = _SequencedBlockingLlamaEngine();
        final provider = ChatProvider(
          chatService: MockChatService(engine: engine),
          settingsService: MockSettingsService(),
          initialSettings: const ChatSettings(
            modelPath: 'gemma-4-E2B-it.litertlm',
            modelSupportsAudio: true,
            directMediaInput: true,
          ),
        );
        addTearDown(provider.dispose);
        await provider.loadModel();

        String? switchTarget;
        if (transition == 'switch') {
          switchTarget = provider.activeConversationId;
          provider.createConversation();
        }

        final voiceTurn = provider.askWithVoice(
          Uint8List.fromList(const <int>[1, 2, 3]),
        );
        await engine.started(0);

        if (switchTarget == null) {
          provider.clearConversation();
        } else {
          await provider.switchConversation(switchTarget);
        }
        final freshTurn = provider.sendMessage('Fresh question');
        await engine.started(1);
        expect(provider.isGenerating, isTrue);

        engine.release(0);
        await voiceTurn;

        expect(provider.isGenerating, isTrue);
        expect(
          provider.messages
              .where((message) => message.isUser)
              .map((message) => message.text),
          <String>['Fresh question'],
        );
        expect(
          provider.messages.map((message) => message.text),
          isNot(contains('Stale voice answer')),
        );

        engine.release(1);
        await freshTurn;

        expect(provider.isGenerating, isFalse);
        expect(provider.messages.last.text, 'Fresh answer');
      },
    );
  }

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

class _ImmediateChatGenerationService extends ChatGenerationService {
  const _ImmediateChatGenerationService();

  @override
  Future<GenerationStreamResult> consumeStream({
    required Stream<LlamaCompletionChunk> stream,
    required bool thinkingEnabled,
    required int uiNotifyIntervalMs,
    required String Function(String) cleanResponse,
    required bool Function() shouldContinue,
    required void Function(GenerationStreamUpdate update) onUpdate,
    Duration? stallTimeout,
  }) async {
    final text = StringBuffer();
    final thinking = StringBuffer();
    var generatedTokens = 0;
    await for (final chunk in stream) {
      if (!shouldContinue() || chunk.choices.isEmpty) {
        continue;
      }
      final delta = chunk.choices.first.delta;
      text.write(delta.content ?? '');
      if (thinkingEnabled) {
        thinking.write(delta.thinking ?? '');
      }
      generatedTokens += 1;
    }
    final cleanText = cleanResponse(text.toString());
    onUpdate(
      GenerationStreamUpdate(
        cleanText: cleanText,
        fullThinking: thinking.toString(),
        shouldNotify: true,
        generatedTokenDelta: generatedTokens,
      ),
    );
    return GenerationStreamResult(
      fullResponse: text.toString(),
      fullThinking: thinking.toString(),
      generatedTokens: generatedTokens,
      firstTokenLatencyMs: generatedTokens == 0 ? null : 0,
      elapsedMs: 1,
      decodeElapsedMs: 1,
    );
  }
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

class _BusyVoiceProvider extends _GeneratingReadyProvider {
  @override
  ChatSettings get settings => const ChatSettings(
    modelPath: 'gemma-4-E2B-it.litertlm',
    modelSupportsAudio: true,
    directMediaInput: true,
  );

  @override
  bool get supportsMicrophoneRecording => true;

  @override
  bool get canStartAudioRecording => false;
}

class _SpeechMockLlamaEngine extends MockLlamaEngine {
  @override
  Future<bool> get supportsAudio async => mmprojLoaded;
}

class _AlwaysAudioMockLlamaEngine extends MockLlamaEngine {
  @override
  Future<bool> get supportsAudio async => true;
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

class _SequencedBlockingLlamaEngine extends MockLlamaEngine {
  final List<Completer<void>> _started = <Completer<void>>[];
  final List<Completer<void>> _release = <Completer<void>>[];

  Future<void> started(int index) async {
    while (_started.length <= index) {
      await Future<void>.delayed(Duration.zero);
    }
    await _started[index].future;
  }

  void release(int index) {
    final gate = _release[index];
    if (!gate.isCompleted) {
      gate.complete();
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
    final index = createCalls;
    createCalls += 1;
    lastCreateParams = params;
    lastCreateMessages = List<LlamaChatMessage>.from(messages);
    final startedGate = Completer<void>();
    final releaseGate = Completer<void>();
    _started.add(startedGate);
    _release.add(releaseGate);
    startedGate.complete();
    await releaseGate.future;

    yield LlamaCompletionChunk(
      id: 'mock-id-$index',
      object: 'chat.completion.chunk',
      created: 1234567890,
      model: 'mock-model',
      choices: <LlamaCompletionChunkChoice>[
        LlamaCompletionChunkChoice(
          index: 0,
          delta: LlamaCompletionChunkDelta(
            content: index == 0 ? 'Stale voice answer' : 'Fresh answer',
          ),
        ),
      ],
    );
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

class _FakeAudioRecordingService implements AudioRecordingService {
  final bool supported;
  final Object? startError;
  final Object? stopError;
  final Object? readError;
  final Completer<void>? startGate;
  final Completer<void>? stopGate;
  final Completer<void>? readGate;
  final Completer<void>? cancelGate;
  final String recordedPath = '/tmp/llamadart_test_recording.wav';
  final Uint8List recordedBytes = Uint8List.fromList(const <int>[
    0x52,
    0x49,
    0x46,
    0x46,
  ]);

  int startCalls = 0;
  int stopCalls = 0;
  int readCalls = 0;
  int cancelCalls = 0;
  int disposeCalls = 0;
  final List<String> deletedPaths = <String>[];

  _FakeAudioRecordingService({
    this.supported = true,
    this.startError,
    this.stopError,
    this.readError,
    this.startGate,
    this.stopGate,
    this.readGate,
    this.cancelGate,
  });

  @override
  bool get isSupported => supported;

  @override
  Future<void> start() async {
    startCalls += 1;
    final gate = startGate;
    if (gate != null) {
      await gate.future;
    }
    final error = startError;
    if (error != null) {
      throw error;
    }
  }

  @override
  Future<String> stop() async {
    stopCalls += 1;
    final gate = stopGate;
    if (gate != null) {
      await gate.future;
    }
    final error = stopError;
    if (error != null) {
      throw error;
    }
    return recordedPath;
  }

  @override
  Future<Uint8List> readRecording(String path) async {
    readCalls += 1;
    final gate = readGate;
    if (gate != null) {
      await gate.future;
    }
    final error = readError;
    if (error != null) {
      throw error;
    }
    return recordedBytes;
  }

  @override
  Future<void> cancel() async {
    cancelCalls += 1;
    final gate = cancelGate;
    if (gate != null) {
      await gate.future;
    }
  }

  @override
  Future<void> deleteRecording(String path) async {
    deletedPaths.add(path);
  }

  @override
  Future<void> dispose() async {
    disposeCalls += 1;
  }
}
