import 'dart:convert';

import 'package:llamadart/llamadart.dart' hide ModelDownloadProgress;

import 'coding_agent_config.dart';
import 'model_source_resolver.dart';
import 'session_event.dart';
import 'text_tool_call_parser.dart';
import 'tool_call_gate.dart';
import 'tool_usage_policy.dart';
import 'workspace_tools.dart';

const String defaultModelSource = 'unsloth/GLM-4.7-Flash-GGUF:UD-Q4_K_XL';

final RegExp _compactWhitespacePattern = RegExp(r'\s+');
final RegExp _toolCallMarkupPattern = RegExp(
  r'<tool_call>\s*[\s\S]*?\s*</tool_call>',
  caseSensitive: false,
);
final RegExp _toolResultMarkupPattern = RegExp(
  r'<tool_result>\s*[\s\S]*?\s*</tool_result>',
  caseSensitive: false,
);
final RegExp _toolCallTagPattern = RegExp(
  r'</?tool_call>',
  caseSensitive: false,
);
final RegExp _toolResultTagPattern = RegExp(
  r'</?tool_result>',
  caseSensitive: false,
);
final RegExp _toolArgMarkupPattern = RegExp(
  r'</?(arg_key|arg_value|arguments|arg\b[^>]*)>',
  caseSensitive: false,
);
final RegExp _collapsedBlankLinesPattern = RegExp(r'\n{3,}');

class CodingAgentSession {
  static const int _loopRecoveryHintThreshold = 2;
  static const int _maxToolCallsPerRound = 4;
  static const int _maxConsecutiveIdenticalToolRounds = 5;
  static const int _maxRepeatedToolSignatureOccurrences = 10;
  static const Duration _maxToolLoopDuration = Duration(minutes: 8);

  final CodingAgentConfig _config;
  final LlamaEngine _engine = LlamaEngine(LlamaBackend());
  final ToolUsagePolicy _toolUsagePolicy = const ToolUsagePolicy();
  late final ModelSourceResolver _modelResolver;
  late final WorkspaceTools _workspaceTools;

  ChatSession? _session;
  List<ToolDefinition> _tools = const <ToolDefinition>[];
  Map<String, ToolDefinition> _toolsByName = const <String, ToolDefinition>{};
  TextToolCallParser? _textToolCallParser;

  String _modelSource;
  String? _loadedModelPath;

  CodingAgentSession(this._config) : _modelSource = _config.modelSource {
    _modelResolver = ModelSourceResolver(
      workspaceRoot: _config.workspaceRoot,
      cacheDirectory: _config.modelCacheDirectory,
    );
    _workspaceTools = WorkspaceTools(workspaceRoot: _config.workspaceRoot);
  }

  String get modelSource => _modelSource;

  String? get loadedModelPath => _loadedModelPath;

  String get workspaceRoot => _workspaceTools.workspaceRoot;

  bool get enableNativeToolCalling => _config.enableNativeToolCalling;

  Future<void> initialize({
    void Function(String status)? onStatus,
    void Function(ModelDownloadProgress progress)? onProgress,
  }) async {
    await _engine.setDartLogLevel(LlamaLogLevel.none);
    await _engine.setNativeLogLevel(LlamaLogLevel.none);
    await _loadModel(_modelSource, onStatus: onStatus, onProgress: onProgress);
  }

  Future<void> switchModel(
    String newSource, {
    void Function(String status)? onStatus,
    void Function(ModelDownloadProgress progress)? onProgress,
  }) async {
    final trimmed = newSource.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('Model source cannot be empty.');
    }

    onStatus?.call('Unloading current model...');
    await _engine.unloadModel();
    await _loadModel(trimmed, onStatus: onStatus, onProgress: onProgress);
  }

  void resetConversation() {
    _session?.reset();
  }

  /// Returns a snapshot of the current conversation history.
  ///
  /// If the chat session is not initialized yet, returns an empty list.
  List<LlamaChatMessage> snapshotConversationHistory() {
    final session = _session;
    if (session == null) {
      return const <LlamaChatMessage>[];
    }
    return List<LlamaChatMessage>.from(session.history);
  }

  /// Replaces the current conversation history with [history].
  ///
  /// If the chat session is not initialized yet, this call is ignored.
  void restoreConversationHistory(List<LlamaChatMessage> history) {
    final session = _session;
    if (session == null) {
      return;
    }

    session.reset();
    for (final message in history) {
      session.addMessage(message);
    }
  }

  void cancelGeneration() {
    _engine.cancelGeneration();
  }

  Future<void> runPrompt(
    String prompt, {
    required void Function(SessionEvent event) onEvent,
  }) async {
    final session = _session;
    if (session == null) {
      throw StateError('Session is not initialized.');
    }

    var round = 0;
    var isFirstRound = true;
    String? followupMessage;
    final usageDecision = _toolUsagePolicy.decideForPrompt(prompt);
    final toolsAllowedForPrompt = usageDecision.allowTools;
    final requiresWorkspaceInspection =
        usageDecision.requiresWorkspaceInspection;
    var toolSuppressionHintSent = false;
    var workspaceInspectionHintSent = false;
    final loopStopwatch = Stopwatch()..start();
    String? previousLoopSignature;
    var consecutiveSameLoopSignatureCount = 0;
    final loopSignatureCounts = <String, int>{};
    var loopRecoveryHintIssued = false;

    while (true) {
      final requestParts = isFirstRound
          ? <LlamaContentPart>[
              LlamaTextContent(
                toolsAllowedForPrompt
                    ? prompt
                    : _toolUsagePolicy.buildDirectAnswerRequestPrompt(prompt),
              ),
            ]
          : (followupMessage == null
                ? const <LlamaContentPart>[]
                : <LlamaContentPart>[LlamaTextContent(followupMessage)]);
      followupMessage = null;
      final roundTextBuffer = StringBuffer();

      try {
        await for (final chunk in session.create(
          requestParts,
          params: _config.generationParams,
          tools: _config.enableNativeToolCalling && toolsAllowedForPrompt
              ? _tools
              : null,
          toolChoice: _config.enableNativeToolCalling && toolsAllowedForPrompt
              ? ToolChoice.auto
              : ToolChoice.none,
          parallelToolCalls: false,
          enableThinking: false,
        )) {
          final delta = chunk.choices.first.delta;
          final content = delta.content;
          if (content != null && content.isNotEmpty) {
            roundTextBuffer.write(content);
          }
        }
      } catch (error) {
        _emitEvent(
          onEvent,
          SessionEvent.error('Generation round failed: $error'),
        );
        return;
      }

      final history = session.history;
      if (history.isEmpty) {
        _emitEvent(
          onEvent,
          SessionEvent.error('No assistant response available.'),
        );
        return;
      }

      final assistantMessage = history.last;
      final assistantRawContent = assistantMessage.content.isNotEmpty
          ? assistantMessage.content
          : roundTextBuffer.toString();
      final assistantDisplayContent = _stripToolProtocolMarkup(
        assistantRawContent,
      );

      final nativeToolCalls = assistantMessage.parts
          .whereType<LlamaToolCallContent>()
          .toList(growable: false);
      final textToolCalls = _config.enableNativeToolCalling
          ? const <TextToolCall>[]
          : _extractTextToolCalls(assistantRawContent);

      final hasToolCalls = _config.enableNativeToolCalling
          ? nativeToolCalls.isNotEmpty
          : textToolCalls.isNotEmpty;

      if (!toolsAllowedForPrompt && hasToolCalls) {
        if (assistantDisplayContent.isNotEmpty) {
          _emitEvent(
            onEvent,
            SessionEvent.assistantToken(assistantDisplayContent),
          );
          _emitEvent(onEvent, SessionEvent.status('Ready.'));
          return;
        }

        if (!toolSuppressionHintSent) {
          toolSuppressionHintSent = true;
          followupMessage = _toolUsagePolicy
              .buildToolSuppressionFollowupPrompt();
          isFirstRound = false;
          _emitEvent(
            onEvent,
            SessionEvent.status('Requested a direct answer without tools.'),
          );
          continue;
        }

        _emitEvent(
          onEvent,
          SessionEvent.error(
            'Model kept requesting tools for a direct question. '
            'Ask with explicit workspace context if you want file inspection.',
          ),
        );
        return;
      }

      if (!hasToolCalls) {
        if (toolsAllowedForPrompt && requiresWorkspaceInspection) {
          if (!workspaceInspectionHintSent) {
            workspaceInspectionHintSent = true;
            followupMessage = _toolUsagePolicy
                .buildWorkspaceInspectionFollowupPrompt(prompt);
            isFirstRound = false;
            _emitEvent(
              onEvent,
              SessionEvent.status(
                'Requested workspace inspection before final answer...',
              ),
            );
            continue;
          }

          if (assistantDisplayContent.isEmpty ||
              _toolUsagePolicy.looksLikeToolAccessDeflection(
                assistantDisplayContent,
              )) {
            _emitEvent(
              onEvent,
              SessionEvent.error(
                'Model did not inspect workspace even though this request '
                'requires repository context. Try again or specify a target '
                'file/path to force inspection.',
              ),
            );
            return;
          }
        }

        if (assistantDisplayContent.isNotEmpty) {
          _emitEvent(
            onEvent,
            SessionEvent.assistantToken(assistantDisplayContent),
          );
        }
        _emitEvent(onEvent, SessionEvent.status('Ready.'));
        return;
      }

      round += 1;
      final configuredMaxRounds = _config.maxToolRounds;
      if (configuredMaxRounds != null && round > configuredMaxRounds) {
        _emitEvent(
          onEvent,
          SessionEvent.error(
            'Tool loop stopped after $configuredMaxRounds rounds.',
          ),
        );
        return;
      }

      if (loopStopwatch.elapsed >= _maxToolLoopDuration) {
        _emitEvent(
          onEvent,
          SessionEvent.error(
            'Tool loop stopped after ${_maxToolLoopDuration.inMinutes} minutes without convergence.',
          ),
        );
        return;
      }

      final roundExecutions = <_ToolExecutionRecord>[];

      if (_config.enableNativeToolCalling) {
        final toolCallGate = ToolCallGate(
          maxToolCallsPerRound: _maxToolCallsPerRound,
        );
        var limitStatusEmitted = false;

        for (final toolCall in nativeToolCalls) {
          final toolName = toolCall.name;
          final arguments = toolCall.arguments.isNotEmpty
              ? toolCall.arguments
              : _decodeArguments(toolCall.rawJson);

          final signature = _buildSingleToolCallSignature(toolName, arguments);
          final gateDecision = toolCallGate.evaluate(signature);
          if (!gateDecision.shouldExecute) {
            if (gateDecision.skipReason == ToolCallSkipReason.duplicateCall) {
              _emitEvent(
                onEvent,
                SessionEvent.status('Skipped duplicate tool call: $toolName.'),
              );
            } else if (gateDecision.skipReason ==
                ToolCallSkipReason.perRoundLimit) {
              if (!limitStatusEmitted) {
                _emitEvent(
                  onEvent,
                  SessionEvent.status(
                    'Tool call limit reached ($_maxToolCallsPerRound per round). '
                    'Skipping additional calls.',
                  ),
                );
                limitStatusEmitted = true;
              }
            }

            session.addMessage(
              LlamaChatMessage.withContent(
                role: LlamaChatRole.tool,
                content: <LlamaContentPart>[
                  LlamaToolResultContent(
                    id: toolCall.id,
                    name: toolName,
                    result: _resultForModel(
                      buildSkippedToolCallResult(
                        gateDecision.skipReason ??
                            ToolCallSkipReason.duplicateCall,
                        limit: _maxToolCallsPerRound,
                      ),
                    ),
                  ),
                ],
              ),
            );
            continue;
          }
          _emitEvent(
            onEvent,
            SessionEvent.toolCall(
              '$toolName(${_safeFormatToolArguments(arguments)})',
            ),
          );

          final result = await _executeToolCall(
            name: toolName,
            arguments: arguments,
          );
          final summary = _summarizeToolResult(toolName, result);
          _emitEvent(onEvent, SessionEvent.toolResult(summary));
          roundExecutions.add(
            _ToolExecutionRecord(
              toolName: toolName,
              arguments: arguments,
              summary: summary,
            ),
          );

          session.addMessage(
            LlamaChatMessage.withContent(
              role: LlamaChatRole.tool,
              content: <LlamaContentPart>[
                LlamaToolResultContent(
                  id: toolCall.id,
                  name: toolName,
                  result: _resultForModel(result),
                ),
              ],
            ),
          );
        }
      } else {
        final resultRecords = <Map<String, dynamic>>[];
        final toolCallGate = ToolCallGate(
          maxToolCallsPerRound: _maxToolCallsPerRound,
        );
        var limitStatusEmitted = false;

        for (final call in textToolCalls) {
          final signature = _buildSingleToolCallSignature(
            call.name,
            call.arguments,
          );
          final gateDecision = toolCallGate.evaluate(signature);
          if (!gateDecision.shouldExecute) {
            if (gateDecision.skipReason == ToolCallSkipReason.duplicateCall) {
              _emitEvent(
                onEvent,
                SessionEvent.status(
                  'Skipped duplicate tool call: ${call.name}.',
                ),
              );
            } else if (gateDecision.skipReason ==
                ToolCallSkipReason.perRoundLimit) {
              if (!limitStatusEmitted) {
                _emitEvent(
                  onEvent,
                  SessionEvent.status(
                    'Tool call limit reached ($_maxToolCallsPerRound per round). '
                    'Skipping additional calls.',
                  ),
                );
                limitStatusEmitted = true;
              }
            }

            resultRecords.add(<String, dynamic>{
              'name': call.name,
              'arguments': call.arguments,
              'result': buildSkippedToolCallResult(
                gateDecision.skipReason ?? ToolCallSkipReason.duplicateCall,
                limit: _maxToolCallsPerRound,
              ),
            });
            continue;
          }
          _emitEvent(
            onEvent,
            SessionEvent.toolCall(
              '${call.name}(${_safeFormatToolArguments(call.arguments)})',
            ),
          );

          final result = await _executeToolCall(
            name: call.name,
            arguments: call.arguments,
          );
          final summary = _summarizeToolResult(call.name, result);
          _emitEvent(onEvent, SessionEvent.toolResult(summary));
          roundExecutions.add(
            _ToolExecutionRecord(
              toolName: call.name,
              arguments: call.arguments,
              summary: summary,
            ),
          );

          resultRecords.add(<String, dynamic>{
            'name': call.name,
            'arguments': call.arguments,
            'result': _resultForModel(result),
          });
        }

        followupMessage = _buildTextToolResultPrompt(resultRecords);
        if (followupMessage.isEmpty) {
          _emitEvent(onEvent, SessionEvent.status('Ready.'));
          return;
        }
      }

      final loopSignature = _buildToolLoopSignature(roundExecutions);
      if (loopSignature.isNotEmpty) {
        final updatedCount = (loopSignatureCounts[loopSignature] ?? 0) + 1;
        loopSignatureCounts[loopSignature] = updatedCount;

        if (loopSignature == previousLoopSignature) {
          consecutiveSameLoopSignatureCount += 1;
        } else {
          previousLoopSignature = loopSignature;
          consecutiveSameLoopSignatureCount = 1;
          loopRecoveryHintIssued = false;
        }

        if (!loopRecoveryHintIssued &&
            consecutiveSameLoopSignatureCount >= _loopRecoveryHintThreshold) {
          final recoveryHint = _buildLoopRecoveryHint(roundExecutions);
          if (_config.enableNativeToolCalling) {
            session.addMessage(
              LlamaChatMessage.fromText(
                role: LlamaChatRole.user,
                text: recoveryHint,
              ),
            );
          } else {
            followupMessage = _appendLoopRecoveryHint(
              followupMessage,
              recoveryHint,
            );
          }
          loopRecoveryHintIssued = true;
          _emitEvent(
            onEvent,
            SessionEvent.status(
              'Detected repeated tool plan, requesting a different strategy...',
            ),
          );
        }

        if (consecutiveSameLoopSignatureCount >=
            _maxConsecutiveIdenticalToolRounds) {
          _emitEvent(
            onEvent,
            SessionEvent.error(
              'Stopped repetitive tool loop: same tool plan repeated '
              '$consecutiveSameLoopSignatureCount times consecutively. '
              'Try narrowing the target path or using a different tool.',
            ),
          );
          return;
        }

        if (updatedCount >= _maxRepeatedToolSignatureOccurrences) {
          _emitEvent(
            onEvent,
            SessionEvent.error(
              'Stopped cyclic tool loop: repeated tool plan observed '
              '$updatedCount times.',
            ),
          );
          return;
        }
      }

      isFirstRound = false;
    }
  }

  Future<void> dispose() async {
    _modelResolver.dispose();
    await _engine.dispose();
  }

  Future<void> _loadModel(
    String source, {
    void Function(String status)? onStatus,
    void Function(ModelDownloadProgress progress)? onProgress,
  }) async {
    onStatus?.call('Resolving model source...');
    final resolved = await _modelResolver.resolve(
      source,
      onStatus: onStatus,
      onProgress: onProgress,
    );

    onStatus?.call('Loading model...');
    await _engine.loadModel(
      resolved.localPath,
      modelParams: _config.modelParams,
    );

    _modelSource = source;
    _loadedModelPath = resolved.localPath;
    _tools = _workspaceTools.buildToolDefinitions();
    _toolsByName = <String, ToolDefinition>{
      for (final tool in _tools) tool.name: tool,
    };
    _textToolCallParser = TextToolCallParser(
      knownToolNames: _toolsByName.keys.toSet(),
    );

    _session = ChatSession(
      _engine,
      maxContextTokens: _config.modelParams.contextSize,
      systemPrompt: _buildSystemPrompt(
        _workspaceTools.workspaceRoot,
        tools: _tools,
        enableNativeToolCalling: _config.enableNativeToolCalling,
      ),
    );

    onStatus?.call('Model loaded.');
  }

  Future<Object?> _executeToolCall({
    required String name,
    required Map<String, dynamic> arguments,
  }) async {
    final tool = _toolsByName[name];
    if (tool == null) {
      return <String, dynamic>{'ok': false, 'error': 'Unknown tool: $name'};
    }

    try {
      return await tool.invoke(arguments);
    } catch (error) {
      return <String, dynamic>{
        'ok': false,
        'error': 'Tool execution failed for $name',
        'details': '$error',
      };
    }
  }

  String _buildTextToolResultPrompt(List<Map<String, dynamic>> resultRecords) {
    if (resultRecords.isEmpty) {
      return '';
    }

    final payload = jsonEncode(<String, dynamic>{
      'tool_results': resultRecords,
    });
    return 'Tool execution results:\n'
        '<tool_result>$payload</tool_result>\n'
        'If additional tools are needed, respond with '
        '<tool_call>{"name":"...","arguments":{...}}</tool_call>. '
        'Do not repeat the same tool call with identical arguments in the '
        'same turn. Otherwise answer the user directly.';
  }

  List<TextToolCall> _extractTextToolCalls(String content) {
    final parser =
        _textToolCallParser ??
        TextToolCallParser(knownToolNames: _toolsByName.keys.toSet());
    return parser.extract(content);
  }

  Map<String, dynamic> _decodeArguments(String rawJson) {
    final trimmed = rawJson.trim();
    if (trimmed.isEmpty) {
      return const <String, dynamic>{};
    }

    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map) {
        return decoded.map(
          (Object? key, Object? value) =>
              MapEntry(key?.toString() ?? 'unknown', value),
        );
      }
    } catch (_) {
      return const <String, dynamic>{};
    }

    return const <String, dynamic>{};
  }

  String _resultToString(Object? value) {
    if (value == null) {
      return 'null';
    }
    if (value is String) {
      return value;
    }
    try {
      return jsonEncode(value);
    } catch (_) {
      return '$value';
    }
  }

  String _resultForModel(Object? value) {
    return _resultToString(value);
  }

  String _buildSingleToolCallSignature(
    String toolName,
    Map<String, dynamic> arguments,
  ) {
    final payload = <String, Object?>{
      'tool': toolName,
      'arguments': _normalizeSignatureValue(arguments),
    };
    try {
      return jsonEncode(payload);
    } catch (_) {
      return _truncateSingleLine('$payload', 300);
    }
  }

  String _appendLoopRecoveryHint(String? followupMessage, String hint) {
    final base = (followupMessage ?? '').trim();
    final guidance = 'Loop guard: $hint';
    if (base.isEmpty) {
      return guidance;
    }
    return '$base\n$guidance';
  }

  String _buildLoopRecoveryHint(List<_ToolExecutionRecord> executions) {
    if (executions.isEmpty) {
      return 'Do not repeat the same tool call with identical arguments. '
          'Choose a different tool or provide the best answer possible now.';
    }

    final allListFiles = executions.every(
      (execution) => execution.toolName == 'list_files',
    );
    if (allListFiles) {
      return 'You are repeating list_files. Do not call list_files with the '
          'same arguments again. Pick the most likely entry file from current '
          'results and call read_file on that path.';
    }

    final allSearchFiles = executions.every(
      (execution) => execution.toolName == 'search_files',
    );
    if (allSearchFiles) {
      return 'You are repeating search_files with the same pattern. Refine the '
          'query or narrow the path, or switch to read_file using the best hit.';
    }

    final tools =
        executions
            .map((execution) => execution.toolName)
            .toSet()
            .toList(growable: false)
          ..sort();
    final toolPreview = tools.join(', ');
    return 'Repeated tool plan detected ($toolPreview). Do not repeat the same '
        'tool calls with identical arguments. Change strategy or respond with '
        'current findings.';
  }

  String _buildToolLoopSignature(List<_ToolExecutionRecord> executions) {
    if (executions.isEmpty) {
      return '';
    }

    final normalized = executions
        .map(
          (execution) => <String, Object?>{
            'tool': execution.toolName,
            'arguments': _normalizeSignatureValue(execution.arguments),
            'summary': execution.summary,
          },
        )
        .toList(growable: false);

    try {
      return jsonEncode(normalized);
    } catch (_) {
      return _truncateSingleLine('$normalized', 400);
    }
  }

  Object? _normalizeSignatureValue(Object? value) {
    if (value is Map) {
      final entries = value.entries.toList(growable: false)
        ..sort((a, b) => a.key.toString().compareTo(b.key.toString()));
      return <String, Object?>{
        for (final entry in entries)
          entry.key.toString(): _normalizeSignatureValue(entry.value),
      };
    }

    if (value is List) {
      return value.map(_normalizeSignatureValue).toList(growable: false);
    }

    if (value == null || value is String || value is num || value is bool) {
      return value;
    }

    return '$value';
  }

  String _summarizeToolResult(String toolName, Object? result) {
    if (result is! Map) {
      return _truncateSingleLine(_resultToString(result), 180);
    }

    final map = result.map(
      (Object? key, Object? value) =>
          MapEntry(key?.toString() ?? 'unknown', value),
    );

    if (map['ok'] == false) {
      final error = map['error']?.toString() ?? 'failed';
      final details = map['details']?.toString();
      final detailSuffix = details == null || details.trim().isEmpty
          ? ''
          : ' ($details)';
      return _truncateSingleLine('$toolName failed: $error$detailSuffix', 180);
    }

    switch (toolName) {
      case 'list_files':
        final path = map['path']?.toString() ?? '.';
        final count = map['count']?.toString() ?? '0';
        final truncated = map['truncated'] == true ? ' (truncated)' : '';
        return 'list_files -> $count entries in $path$truncated';
      case 'read_file':
        final path = map['path']?.toString() ?? '';
        final start = map['start_line']?.toString() ?? '?';
        final end = map['end_line']?.toString() ?? '?';
        final count = map['line_count']?.toString() ?? '?';
        final truncated = map['truncated'] == true ? ', truncated' : '';
        return 'read_file -> $path lines $start-$end ($count)$truncated';
      case 'search_files':
        final query = map['query']?.toString() ?? '';
        final count = map['count']?.toString() ?? '0';
        final path = map['path']?.toString() ?? '.';
        final truncated = map['truncated'] == true ? ', truncated' : '';
        return _truncateSingleLine(
          'search_files -> $count matches for "$query" in $path$truncated',
          180,
        );
      case 'write_file':
        final path = map['path']?.toString() ?? '';
        final bytes = map['bytes_written']?.toString() ?? '0';
        final mode = map['mode']?.toString() ?? 'overwrite';
        return 'write_file -> wrote $bytes bytes to $path ($mode)';
      case 'run_command':
        final exitCode = map['exit_code']?.toString() ?? '?';
        final timedOut = map['timed_out'] == true ? ', timeout' : '';
        final ok = map['ok'] == true ? 'ok' : 'failed';
        return 'run_command -> $ok (exit $exitCode$timedOut)';
      default:
        final compact = _truncateSingleLine(_resultToString(map), 180);
        return '$toolName -> $compact';
    }
  }

  String _truncateSingleLine(String value, int maxChars) {
    final compact = value.replaceAll(_compactWhitespacePattern, ' ').trim();
    if (compact.length <= maxChars) {
      return compact;
    }
    return '${compact.substring(0, maxChars)}...';
  }

  String _safeFormatToolArguments(Map<String, dynamic> arguments) {
    try {
      return formatToolArguments(arguments);
    } catch (_) {
      return '<arguments unavailable>';
    }
  }

  String _stripToolProtocolMarkup(String content) {
    var cleaned = content;

    cleaned = cleaned.replaceAll(_toolCallMarkupPattern, '');
    cleaned = cleaned.replaceAll(_toolResultMarkupPattern, '');
    cleaned = cleaned.replaceAll(_toolCallTagPattern, '');
    cleaned = cleaned.replaceAll(_toolResultTagPattern, '');
    cleaned = cleaned.replaceAll(_toolArgMarkupPattern, '');

    cleaned = cleaned.replaceAll(_collapsedBlankLinesPattern, '\n\n').trim();
    return cleaned;
  }

  void _emitEvent(
    void Function(SessionEvent event) onEvent,
    SessionEvent event,
  ) {
    try {
      onEvent(event);
    } catch (_) {
      // Keep session alive even if UI handler throws.
    }
  }
}

String _buildSystemPrompt(
  String workspaceRoot, {
  required List<ToolDefinition> tools,
  required bool enableNativeToolCalling,
}) {
  final basePrompt =
      'You are a local coding agent running in a terminal UI. '
      'You can inspect, edit, and test code through tools. '
      'Before calling tools, decide if the user request can be answered from '
      'general knowledge or existing conversation context; if yes, answer '
      'directly without tools. '
      'If the user asks about this workspace/project/repository/files, you '
      'already have access through tools and should inspect files before '
      'answering. Do not claim lack of access. '
      'Use tools only when they materially improve correctness, and keep calls '
      'minimal. Never repeat identical tool calls with identical arguments in '
      'the same turn. Keep responses concise and explicit about changes. '
      'The workspace root is: $workspaceRoot. '
      'Never suggest actions outside this workspace.';

  if (enableNativeToolCalling) {
    return basePrompt;
  }

  final availableTools = tools
      .map((tool) => '- ${tool.name}: ${tool.description}')
      .join('\n');

  return '$basePrompt\n'
      'Use text-based tool protocol for stability:\n'
      '1) If no tool is needed, answer directly.\n'
      '2) If a tool is needed, respond with one or more blocks in this format:\n'
      '<tool_call>{"name":"tool_name","arguments":{...}}</tool_call>\n'
      '   If there are no arguments, this shorthand is also valid: <tool_call>tool_name</tool_call>\n'
      '   Always include the closing </tool_call> tag.\n'
      '3) Do not wrap tool-call blocks with extra prose.\n'
      '4) Avoid duplicate tool calls with the same arguments in the same turn.\n'
      '5) After tool results arrive in <tool_result>...</tool_result>, either emit another <tool_call> or provide final answer.\n'
      '6) Final user-facing answers must not contain literal <tool_call> or <tool_result> tags.\n'
      'Available tools:\n$availableTools';
}

class _ToolExecutionRecord {
  final String toolName;
  final Map<String, dynamic> arguments;
  final String summary;

  const _ToolExecutionRecord({
    required this.toolName,
    required this.arguments,
    required this.summary,
  });
}
