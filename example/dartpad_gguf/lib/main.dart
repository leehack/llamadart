import 'package:flutter/material.dart';
import 'package:llamadart/llamadart.dart';

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

  @override
  void dispose() {
    _chat.dispose();
    _prompt.dispose();
    _promptFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _followTranscript({bool force = false}) {
    if (!force && (!_scroll.hasClients || _scroll.position.extentAfter > 48)) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _chat,
      builder: (context, _) {
        if (_chat.generating) _followTranscript();
        final messages = _chat.messages;
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
            child: Column(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        FilledButton(
                          onPressed: _chat.loading || _chat.ready
                              ? null
                              : _chat.load,
                          child: const Text('Load'),
                        ),
                        if (_chat.loading)
                          LinearProgressIndicator(
                            value: _chat.progress,
                            semanticsLabel: 'Loading model',
                          ),
                        StatsBar(
                          stats: _chat.stats,
                          generating: _chat.generating,
                        ),
                        SettingsPanel(chat: _chat),
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
                        TranscriptList(messages: messages),
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
        );
      },
    );
  }
}
