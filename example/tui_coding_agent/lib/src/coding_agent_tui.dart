import 'dart:async';

import 'package:llamadart/llamadart.dart' show ModelDownloadProgress;
import 'package:nocterm/nocterm.dart';

import 'assistant_draft_rows.dart';
import 'coding_agent_config.dart';
import 'coding_agent_markdown.dart';
import 'coding_agent_session.dart';
import 'coding_agent_theme.dart';
import 'session_event.dart';
import 'session_event_coalescer.dart';

/// Minimal single-screen terminal UI for the local coding agent.
class CodingAgentTui extends StatefulComponent {
  /// Runtime configuration used to create the coding-agent session.
  final CodingAgentConfig config;

  /// Creates the coding-agent terminal UI.
  const CodingAgentTui({required this.config, super.key});

  @override
  State<CodingAgentTui> createState() => _CodingAgentTuiState();
}

class _CodingAgentTuiState extends State<CodingAgentTui> {
  late final CodingAgentSession _session;
  final TextEditingController _inputController = TextEditingController();
  final AutoScrollController _scrollController = AutoScrollController();
  final List<_TranscriptMessage> _messages = <_TranscriptMessage>[];
  final AssistantDraftRows _draftRows = AssistantDraftRows();
  late final SessionEventCoalescer _eventCoalescer;

  bool _busy = true;
  bool _ready = false;
  bool _exitArmed = false;
  bool _quitting = false;
  bool _cancelling = false;
  String _status = 'Starting...';
  DateTime? _lastProgressUpdate;

  @override
  void initState() {
    super.initState();
    _eventCoalescer = SessionEventCoalescer(onBatch: _applySessionEvents);
    _session = CodingAgentSession(component.config);
    _messages.add(
      _TranscriptMessage(
        role: _TranscriptRole.system,
        text: 'Loading ${component.config.modelSource}...',
      ),
    );
    unawaited(_bootstrap());
  }

  @override
  void dispose() {
    _eventCoalescer.dispose();
    _inputController.dispose();
    _scrollController.dispose();
    unawaited(_disposeSessionSilently());
    super.dispose();
  }

  Future<void> _disposeSessionSilently() async {
    try {
      await _session.dispose();
    } catch (_) {
      // The component is already leaving the terminal; teardown cannot be
      // surfaced safely here.
    }
  }

  Future<void> _bootstrap() async {
    try {
      await _session.initialize(
        onStatus: _setStatus,
        onProgress: _handleDownloadProgress,
      );
      if (!mounted || _quitting) {
        return;
      }
      setState(() {
        _ready = true;
        _status = 'Ready';
        _messages.add(
          _TranscriptMessage(
            role: _TranscriptRole.system,
            text: 'Ready. Type /help for commands.',
          ),
        );
      });
    } catch (error) {
      if (!mounted || _quitting) {
        return;
      }
      setState(() {
        _status = 'Initialization failed';
        _messages.add(
          _TranscriptMessage(
            role: _TranscriptRole.error,
            text: 'Failed to initialize: $error',
          ),
        );
      });
    } finally {
      if (mounted && !_quitting) {
        setState(() {
          _busy = false;
          _cancelling = false;
        });
      }
    }
  }

  void _setStatus(String status) {
    if (!mounted || _quitting || _cancelling) {
      return;
    }
    setState(() {
      _status = status;
    });
  }

  void _handleDownloadProgress(ModelDownloadProgress progress) {
    final now = DateTime.now();
    final last = _lastProgressUpdate;
    if (last != null &&
        now.difference(last) < const Duration(milliseconds: 100) &&
        progress.fraction != 1) {
      return;
    }
    _lastProgressUpdate = now;

    final fraction = progress.fraction;
    if (fraction == null) {
      final megabytes = progress.receivedBytes / (1024 * 1024);
      _setStatus('Downloading ${megabytes.toStringAsFixed(1)} MB');
    } else {
      _setStatus('Downloading ${(fraction * 100).toStringAsFixed(1)}%');
    }
  }

  void _handleSessionEvent(SessionEvent event) {
    _eventCoalescer.add(event);
  }

  void _applySessionEvents(List<SessionEvent> events) {
    if (!mounted || _quitting) {
      return;
    }

    setState(() {
      for (final event in events) {
        _applySessionEvent(event);
      }
    });
  }

  void _applySessionEvent(SessionEvent event) {
    switch (event.type) {
      case SessionEventType.status:
        _draftRows.commit();
        if (!_cancelling) {
          _status = event.message;
        }
        break;
      case SessionEventType.assistantToken:
        _draftRows.finishThinkingRow();
        if (!_cancelling) {
          _status = 'Responding...';
        }
        final index = _draftRows.activeAssistantRow;
        if (index == null || index >= _messages.length) {
          _messages.add(
            _TranscriptMessage(
              role: _TranscriptRole.assistant,
              text: event.message,
            ),
          );
          _draftRows.startAssistantRow(_messages.length - 1);
        } else {
          _messages[index].append(event.message);
        }
        break;
      case SessionEventType.thinkingToken:
        if (!_cancelling) {
          _status = 'Reasoning...';
        }
        final index = _draftRows.activeThinkingRow;
        if (index == null || index >= _messages.length) {
          _messages.add(
            _TranscriptMessage(
              role: _TranscriptRole.thinking,
              text: event.message,
            ),
          );
          _draftRows.startThinkingRow(_messages.length - 1);
        } else {
          _messages[index].append(event.message);
        }
        break;
      case SessionEventType.assistantDraftReset:
        for (final index in _draftRows.takeRowsForReset()) {
          if (index >= 0 && index < _messages.length) {
            _messages.removeAt(index);
          }
        }
        break;
      case SessionEventType.toolCall:
        _draftRows.commit();
        if (!_cancelling) {
          _status = 'Running tool...';
        }
        _messages.add(
          _TranscriptMessage(
            role: _TranscriptRole.tool,
            text: '→ ${event.message}',
          ),
        );
        break;
      case SessionEventType.toolResult:
        _draftRows.commit();
        _messages.add(
          _TranscriptMessage(
            role: _TranscriptRole.tool,
            text: '← ${event.message}',
          ),
        );
        break;
      case SessionEventType.warning:
        _draftRows.commit();
        _cancelling = false;
        _status = event.message;
        _messages.add(
          _TranscriptMessage(
            role: _TranscriptRole.warning,
            text: event.message,
          ),
        );
        break;
      case SessionEventType.error:
        _draftRows.commit();
        _cancelling = false;
        _messages.add(
          _TranscriptMessage(role: _TranscriptRole.error, text: event.message),
        );
        break;
    }
  }

  Future<void> _submitInput() async {
    if (_quitting) {
      return;
    }
    final input = _inputController.text.trim();
    if (input.isEmpty) {
      return;
    }

    if (input.startsWith('/')) {
      _inputController.clear();
      _exitArmed = false;
      _handleCommand(input);
      return;
    }

    if (!_ready) {
      _appendMessage(_TranscriptRole.error, 'The model is not ready yet.');
      return;
    }
    if (_busy || _session.isRunning) {
      _appendMessage(
        _TranscriptRole.system,
        'The agent is working. Use /cancel or press Esc.',
      );
      return;
    }

    _inputController.clear();
    _exitArmed = false;
    setState(() {
      _messages.add(
        _TranscriptMessage(role: _TranscriptRole.user, text: input),
      );
      _busy = true;
      _cancelling = false;
      _status = 'Thinking...';
      _draftRows.commit();
    });

    try {
      await _session.runPrompt(input, onEvent: _handleSessionEvent);
    } catch (error) {
      _appendMessage(_TranscriptRole.error, 'Request failed: $error');
    } finally {
      _eventCoalescer.flush();
      if (mounted && !_quitting) {
        setState(() {
          _busy = false;
          _cancelling = false;
          _status = _ready ? 'Ready' : _status;
          _draftRows.commit();
        });
      }
    }
  }

  void _handleCommand(String rawCommand) {
    final command = rawCommand.trim().toLowerCase();
    switch (command) {
      case '/help':
        _appendMessage(
          _TranscriptRole.system,
          'Commands:\n'
          '/help       show this help\n'
          '/clear      clear the conversation\n'
          '/model      show the active model\n'
          '/workspace  show the workspace root\n'
          '/cancel     cancel current work\n'
          '/quit       exit\n'
          'Enter sends. Esc cancels while busy; otherwise press it twice to quit. '
          'Ctrl+C cancels while busy or quits while idle.',
        );
        return;
      case '/clear':
        _clearConversation();
        return;
      case '/model':
        final loadedModelName = _session.loadedModelName;
        _appendMessage(
          _TranscriptRole.system,
          'Source: ${_session.modelSource}\n'
          'Loaded: ${loadedModelName ?? 'not loaded'}\n'
          'Reasoning: ${_session.isThinkingEnabled ? 'on' : 'off'}',
        );
        return;
      case '/workspace':
        _appendMessage(_TranscriptRole.system, _session.workspaceRoot);
        return;
      case '/cancel':
        _cancel();
        return;
      case '/quit':
        unawaited(_quit());
        return;
      default:
        _appendMessage(
          _TranscriptRole.error,
          'Unknown command: $rawCommand. Type /help.',
        );
    }
  }

  void _clearConversation() {
    if (_busy || _session.isRunning) {
      _appendMessage(
        _TranscriptRole.system,
        'Cancel the active request before clearing.',
      );
      return;
    }
    if (!_ready || !_session.isReady) {
      _appendMessage(
        _TranscriptRole.error,
        'The model is not ready, so there is no conversation to clear.',
      );
      return;
    }
    _session.resetConversation();
    if (!mounted || _quitting) {
      return;
    }
    setState(() {
      _messages
        ..clear()
        ..add(
          _TranscriptMessage(
            role: _TranscriptRole.system,
            text: 'Conversation cleared.',
          ),
        );
      _draftRows.commit();
      _cancelling = false;
      _status = 'Ready';
    });
  }

  void _cancel() {
    if (!_busy && !_session.isRunning) {
      _appendMessage(_TranscriptRole.system, 'Nothing is running.');
      return;
    }
    _eventCoalescer.flush();
    if (mounted && !_quitting) {
      setState(() {
        _cancelling = true;
        _status = 'Cancelling...';
      });
    }
    _session.cancelActiveWork();
  }

  bool _handleInputKey(KeyboardEvent event) {
    if (event.matches(LogicalKey.keyC, ctrl: true)) {
      if (_quitting) {
        return true;
      }
      if (_busy || _session.isRunning) {
        _cancel();
      } else {
        unawaited(_quit());
      }
      return true;
    }
    if (!event.matches(LogicalKey.escape)) {
      if (_exitArmed && mounted) {
        setState(() {
          _exitArmed = false;
          _status = _ready ? 'Ready' : _status;
        });
      }
      return false;
    }

    if (_busy || _session.isRunning) {
      _cancel();
      return true;
    }
    if (_exitArmed) {
      unawaited(_quit());
      return true;
    }
    setState(() {
      _exitArmed = true;
      _status = 'Press Esc again to quit';
    });
    return true;
  }

  Future<void> _quit() async {
    if (_quitting) {
      return;
    }
    _quitting = true;
    if (mounted) {
      setState(() {
        _busy = true;
        _ready = false;
        _status = 'Shutting down...';
      });
    }
    _session.cancelActiveWork();
    var resultCode = 0;
    try {
      await _session.dispose();
    } catch (_) {
      resultCode = 1;
    } finally {
      shutdownApp(resultCode);
    }
  }

  void _appendMessage(_TranscriptRole role, String text) {
    if (!mounted || _quitting) {
      return;
    }
    _eventCoalescer.flush();
    setState(() {
      _messages.add(_TranscriptMessage(role: role, text: text));
    });
  }

  String get _modelLabel {
    final loadedModelName = _session.loadedModelName;
    if (loadedModelName != null && loadedModelName.isNotEmpty) {
      return loadedModelName;
    }
    return _session.modelDisplayName;
  }

  @override
  Component build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 1),
      decoration: const BoxDecoration(color: CodingAgentTheme.desktop),
      child: Column(
        children: <Component>[
          _buildHeader(),
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 1),
              decoration: BoxDecoration(
                color: CodingAgentTheme.panel,
                border: BoxBorder.all(
                  color: CodingAgentTheme.frame,
                  style: BoxBorderStyle.double,
                ),
                title: const BorderTitle(
                  text: ' llamadart coding agent ',
                  alignment: TitleAlignment.center,
                  style: TextStyle(
                    color: Colors.brightYellow,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              child: _buildTranscript(),
            ),
          ),
          _buildInput(),
          _buildStatusLine(),
        ],
      ),
    );
  }

  Component _buildHeader() {
    return LayoutBuilder(
      builder: (context, constraints) {
        const fixedWidth = 16;
        final compact = constraints.maxWidth < 48;
        final thinkingBadge = _session.isThinkingEnabled
            ? (compact ? ' [T]' : ' [thinking]')
            : null;
        final readOnlyBadge = _session.isReadOnly
            ? (compact ? ' [RO]' : ' [read-only]')
            : null;
        final badgeWidth =
            (thinkingBadge?.length ?? 0) + (readOnlyBadge?.length ?? 0);
        final modelWidth =
            (constraints.maxWidth.toInt() - fixedWidth - badgeWidth)
                .clamp(0, 80)
                .toInt();
        final modelLabel = _ellipsize(_modelLabel, modelWidth);
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 1),
          decoration: const BoxDecoration(color: CodingAgentTheme.chrome),
          child: Row(
            children: <Component>[
              const Text(
                'llamadart',
                style: TextStyle(
                  color: CodingAgentTheme.chromeText,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Text(
                '  m: ',
                style: TextStyle(color: CodingAgentTheme.chromeText),
              ),
              Expanded(
                child: Text(
                  modelLabel,
                  maxLines: 1,
                  softWrap: false,
                  style: const TextStyle(
                    color: CodingAgentTheme.panel,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              if (thinkingBadge != null)
                Text(
                  thinkingBadge,
                  style: const TextStyle(
                    color: CodingAgentTheme.panel,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              if (readOnlyBadge != null)
                Text(
                  readOnlyBadge,
                  style: const TextStyle(
                    color: Color.fromRGB(170, 0, 0),
                    fontWeight: FontWeight.bold,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Component _buildTranscript() {
    if (_messages.isEmpty) {
      return const Center(
        child: Text(
          'Ask a coding question.',
          style: TextStyle(color: Colors.gray),
        ),
      );
    }
    return Scrollbar(
      controller: _scrollController,
      thumbVisibility: true,
      trackColor: CodingAgentTheme.accent,
      thumbColor: CodingAgentTheme.frame,
      child: ListView.builder(
        controller: _scrollController,
        lazy: true,
        padding: const EdgeInsets.symmetric(horizontal: 1),
        itemCount: _messages.length,
        itemBuilder: (BuildContext context, int index) {
          return _TranscriptRow(message: _messages[index]);
        },
      ),
    );
  }

  Component _buildStatusLine() {
    final indicatorColor = _ready ? CodingAgentTheme.panel : Colors.red;
    final indicator = _busy ? 'BUSY' : (_ready ? 'READY' : 'ERROR');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 1),
      decoration: const BoxDecoration(color: CodingAgentTheme.chrome),
      child: Row(
        children: <Component>[
          Text(
            '[$indicator] ',
            style: TextStyle(
              color: indicatorColor,
              fontWeight: FontWeight.bold,
            ),
          ),
          Expanded(
            child: Text(
              _status,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: CodingAgentTheme.chromeText),
            ),
          ),
          Expanded(
            child: const Text(
              '│ Esc/Ctrl+C cancel/quit  /help',
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: CodingAgentTheme.chromeText),
            ),
          ),
        ],
      ),
    );
  }

  Component _buildInput() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 1),
      decoration: const BoxDecoration(
        color: CodingAgentTheme.panel,
        border: BoxBorder(top: BorderSide(color: CodingAgentTheme.accent)),
      ),
      child: Row(
        children: <Component>[
          const Text(
            '> ',
            style: TextStyle(
              color: Colors.brightYellow,
              fontWeight: FontWeight.bold,
            ),
          ),
          Expanded(
            child: TextField(
              controller: _inputController,
              focused: true,
              enabled: !_quitting,
              placeholder: 'Message the agent; /cancel works while busy',
              placeholderStyle: const TextStyle(
                color: CodingAgentTheme.dimText,
              ),
              style: const TextStyle(color: Colors.brightWhite),
              cursorColor: Colors.brightCyan,
              selectionColor: CodingAgentTheme.accent,
              onKeyEvent: _handleInputKey,
              onSubmitted: (_) => unawaited(_submitInput()),
            ),
          ),
        ],
      ),
    );
  }
}

String _ellipsize(String value, int maxCharacters) {
  if (maxCharacters <= 0) {
    return '';
  }
  if (value.length <= maxCharacters) {
    return value;
  }
  if (maxCharacters == 1) {
    return '…';
  }
  var end = maxCharacters - 1;
  final last = value.codeUnitAt(end - 1);
  if (last >= 0xd800 && last <= 0xdbff) {
    end -= 1;
  }
  return '${value.substring(0, end)}…';
}

enum _TranscriptRole { system, user, assistant, thinking, tool, warning, error }

class _TranscriptMessage {
  final _TranscriptRole role;
  final StringBuffer _text;

  _TranscriptMessage({required this.role, required String text})
    : _text = StringBuffer(text);

  String get text => _text.toString();

  void append(String delta) => _text.write(delta);
}

class _TranscriptRow extends StatelessComponent {
  final _TranscriptMessage message;

  const _TranscriptRow({required this.message});

  @override
  Component build(BuildContext context) {
    final (label, color) = switch (message.role) {
      _TranscriptRole.system => ('system', Colors.brightYellow),
      _TranscriptRole.user => ('you', Colors.brightGreen),
      _TranscriptRole.assistant => ('agent', Colors.brightCyan),
      _TranscriptRole.thinking => ('think', CodingAgentTheme.dimText),
      _TranscriptRole.tool => ('tool', Colors.brightMagenta),
      _TranscriptRole.warning => ('warning', Colors.brightYellow),
      _TranscriptRole.error => ('error', Colors.brightRed),
    };

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Component>[
        SizedBox(
          width: 10,
          child: Text(
            '[$label] ',
            style: TextStyle(color: color, fontWeight: FontWeight.bold),
          ),
        ),
        Expanded(
          child: switch (message.role) {
            _TranscriptRole.assistant => CodingAgentMarkdownText(
              data: message.text,
            ),
            _TranscriptRole.thinking => CodingAgentMarkdownText(
              data: message.text,
              thinking: true,
            ),
            _ => Text(
              message.text,
              style: TextStyle(
                color: message.role == _TranscriptRole.error
                    ? Colors.brightRed
                    : Colors.brightWhite,
              ),
            ),
          },
        ),
      ],
    );
  }
}
