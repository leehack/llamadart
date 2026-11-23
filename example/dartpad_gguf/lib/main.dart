import 'package:llamadart/llamadart.dart';
import 'package:material_ui/material_ui.dart';

import 'bridge_bootstrap.dart';
import 'chat_controller.dart';
import 'chat_widgets.dart';

void main() => runApp(const GgufApp());

Future<LlamaEngine> _createEngine() async {
  await bootstrapBridge();
  return LlamaEngine(LlamaBackend());
}

class GgufApp extends StatelessWidget {
  const GgufApp({super.key, this.createEngine = _createEngine});

  final Future<LlamaEngine> Function() createEngine;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      // The Navigator provides overlays without writing to the iframe URL.
      builder: (_, _) => Navigator(
        onGenerateRoute: (_) => MaterialPageRoute<void>(
          builder: (_) => _GgufScreen(createEngine: createEngine),
        ),
      ),
    );
  }
}

class _GgufScreen extends StatefulWidget {
  const _GgufScreen({required this.createEngine});

  final Future<LlamaEngine> Function() createEngine;

  @override
  State<_GgufScreen> createState() => _GgufScreenState();
}

class _GgufScreenState extends State<_GgufScreen> {
  late final _chat = ChatController(widget.createEngine);
  final _prompt = TextEditingController();
  final _promptFocus = FocusNode();
  final _scroll = ScrollController();
  bool _scrollScheduled = false;

  @override
  void initState() {
    super.initState();
    _chat.streamingText.addListener(_onStreamingText);
  }

  @override
  void dispose() {
    _chat.streamingText.removeListener(_onStreamingText);
    _chat.dispose();
    _prompt.dispose();
    _promptFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onStreamingText() {
    if (_chat.streamingText.value != null) {
      _followTranscript();
    }
  }

  void _followTranscript({bool force = false}) {
    if (_scrollScheduled) return;
    if (!force && (!_scroll.hasClients || _scroll.position.extentAfter > 48)) {
      return;
    }
    _scrollScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollScheduled = false;
      if (mounted && _scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _chat,
      builder: (context, _) {
        final messages = _chat.messages;
        final busy = _chat.loading || _chat.generating;
        return Scaffold(
          appBar: AppBar(
            title: const Text('GGUF in DartPad'),
            actions: [
              TextButton(
                onPressed: messages.isEmpty || _chat.generating
                    ? null
                    : _chat.clearChat,
                child: const Text('Clear'),
              ),
            ],
          ),
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: Column(
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            ModelPicker(
                              selected: _chat.selectedModel,
                              enabled: !busy,
                              showWarning: !_chat.ready,
                              onSelected: _chat.selectModel,
                            ),
                            const SizedBox(height: 8),
                            FilledButton(
                              onPressed: _chat.loading || _chat.ready
                                  ? null
                                  : _chat.load,
                              child: const Text('Load'),
                            ),
                            if (_chat.loading) ...[
                              const SizedBox(height: 8),
                              ValueListenableBuilder<double?>(
                                valueListenable: _chat.progress,
                                builder: (context, progress, _) =>
                                    LinearProgressIndicator(
                                      value: progress,
                                      semanticsLabel: 'Loading model',
                                    ),
                              ),
                            ],
                            if (_chat.ready) ...[
                              const SizedBox(height: 8),
                              StatsBar(
                                stats: _chat.stats,
                                generating: _chat.generating,
                              ),
                            ],
                            const SizedBox(height: 8),
                            SettingsPanel(chat: _chat, enabled: !busy),
                            const SizedBox(height: 8),
                            PresetChips(
                              onSelect: (text) {
                                _prompt.value = TextEditingValue(
                                  text: text,
                                  selection: TextSelection.collapsed(
                                    offset: text.length,
                                  ),
                                );
                                _promptFocus.requestFocus();
                              },
                            ),
                            const Divider(height: 24),
                            TranscriptList(
                              messages: messages,
                              streamingText: _chat.streamingText,
                            ),
                          ],
                        ),
                      ),
                    ),
                    ComposerBar(
                      chat: _chat,
                      prompt: _prompt,
                      promptFocus: _promptFocus,
                      onSend: () {
                        _chat.send(_prompt.text);
                        _prompt.clear();
                        _followTranscript(force: true);
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
