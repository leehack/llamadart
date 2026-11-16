// Fixture checkpoints are also visible in XCTest stdout.
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:llamadart_studio/llamadart_studio.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';

/// Fixture-only, bounded metadata journal. Callers supply no content or paths.
class ChatDiagnostics {
  ChatDiagnostics(this.file);
  final File file;
  final Stopwatch clock = Stopwatch()..start();
  int _bytes = 0;
  int _records = 0;
  static const maxBytes = 256 * 1024;
  static const maxRecords = 128;

  void record(String phase, [Map<String, Object?> fields = const {}]) {
    if (_records >= maxRecords) return;
    final line =
        '${jsonEncode({'schema': 1, 'phase': phase, 'elapsed_ms': clock.elapsedMilliseconds, ...fields})}\n';
    final size = utf8.encode(line).length;
    if (_bytes + size > maxBytes) return;
    _bytes += size;
    _records++;
    // Serialize and flush each checkpoint; diagnostics never replace a failure.
    try {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(line, mode: FileMode.append, flush: true);
    } catch (error) {
      print('chat diagnostic write failed: ${error.runtimeType}');
    }
    print('chat diagnostic: $phase (${clock.elapsedMilliseconds} ms)');
  }

  Future<void> flush() async {}
}

/// Observes one subscription without changing events, errors or cancellation.
class RecordingInferencePort implements StudioInferencePort {
  RecordingInferencePort(this.delegate, this.diagnostics);
  final StudioInferencePort delegate;
  final ChatDiagnostics diagnostics;
  @override
  ReadOnlyStore<StudioRuntimeSnapshot> get runtimeStore =>
      delegate.runtimeStore;
  @override
  Future<void> refreshHardwareDiagnostics() =>
      delegate.refreshHardwareDiagnostics();
  @override
  Future<void> loadModel({
    required ResolvedModelAssets assets,
    required StudioSettings settings,
    required bool isWeb,
  }) => delegate.loadModel(assets: assets, settings: settings, isWeb: isWeb);
  @override
  Future<void> loadCustomSource({
    required StudioModelDescriptor descriptor,
    required StudioSettings settings,
    required bool isWeb,
  }) => delegate.loadCustomSource(
    descriptor: descriptor,
    settings: settings,
    isWeb: isWeb,
  );
  @override
  Future<void> unloadModel() => delegate.unloadModel();
  @override
  Stream<StudioTurnEvent> streamTurn(StudioTurnRequest request) {
    diagnostics.record('stream_requested');
    var text = false;
    var thinking = false;
    final source = delegate.streamTurn(request);
    return Stream<StudioTurnEvent>.eventTransformed(source, (sink) {
      diagnostics.record('stream_subscribed');
      return _Observer(sink, diagnostics, (event) {
        if (event is StudioTextDeltaEvent && !text) {
          text = true;
          diagnostics.record('first_text');
        }
        if (event is StudioThinkingDeltaEvent && !thinking) {
          thinking = true;
          diagnostics.record('first_thinking');
        }
        if (event is StudioTurnCompletedEvent) {
          diagnostics.record('completion', {
            'tokens': event.result.metrics.generatedTokens,
          });
        }
      });
    });
  }

  @override
  void cancelGeneration() {
    diagnostics.record('cancel_requested');
    delegate.cancelGeneration();
  }

  @override
  Future<void> dispose() => delegate.dispose();
}

class _Observer implements EventSink<StudioTurnEvent> {
  _Observer(this.sink, this.diagnostics, this.observe);
  final EventSink<StudioTurnEvent> sink;
  final ChatDiagnostics diagnostics;
  final void Function(StudioTurnEvent) observe;
  @override
  void add(StudioTurnEvent event) {
    observe(event);
    sink.add(event);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    diagnostics.record('stream_error', {'type': error.runtimeType.toString()});
    sink.addError(error, stackTrace);
  }

  @override
  void close() {
    diagnostics.record('stream_closed');
    sink.close();
  }
}

Map<String, Object?> chatCheckpoint(StudioDependencies deps, String prompt) {
  final state = deps.chatController.state;
  final stream = deps.chatController.activeStreamStore.state;
  final branch = state.activeConversation?.activeBranch ?? [];
  final users = branch.where((m) => m.role == StudioRole.user);
  return {
    'conversation_id': state.activeConversationId,
    'roles': branch.map((m) => m.role.name).toList(),
    'branch_count': branch.length,
    'is_submitting': state.isSubmitting,
    'is_generating': stream.isGenerating,
    'latest_user_matches': users.isNotEmpty && users.last.text == prompt,
    'text_length': stream.text.length,
    'thinking_length': stream.thinkingText.length,
    'tokens': stream.tokensGenerated,
    'turn_elapsed_ms': stream.elapsedMs,
    'operation_present': stream.statusLabel != null,
    'last_error_length': state.lastTurnError?.length,
  };
}
