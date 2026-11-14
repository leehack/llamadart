import 'package:llamadart/llamadart.dart';
import 'package:meta/meta.dart';

import '../domain/studio_message.dart';
import '../domain/studio_model_descriptor.dart';
import '../domain/studio_runtime_snapshot.dart';
import '../domain/studio_settings.dart';
import '../reactive/state_store.dart';
import 'model_storage_port.dart';

/// Stateless turn execution request passed to a [StudioInferencePort].
///
/// Keeping turn inputs explicit (history + systemPrompt + jsonSchema + settings)
/// allows either `DirectLlamaInferencePort` (`ChatSession`/`LlamaEngine`) or a
/// future `GenkitStudioInferencePort` (`genkit_llamadart`) to execute turns
/// identically.
@immutable
class StudioTurnRequest {
  /// Creates a [StudioTurnRequest].
  const StudioTurnRequest({
    required this.history,
    required this.settings,
    this.systemPrompt = '',
    this.extraSystemContext = '',
    this.jsonSchema,
    this.extraTools = const <ToolDefinition>[],
    this.includeBuiltInTools = true,
    this.toolsEnabledOverride,
    this.maxToolRounds = 5,
  });

  /// Ordered conversation branch ending with the user turn to answer.
  final List<StudioMessage> history;

  /// Active Studio runtime & sampling settings.
  final StudioSettings settings;

  /// Optional system instruction for this conversation.
  final String systemPrompt;

  /// Optional contextual suffix appended to [systemPrompt] (such as active
  /// Agent Skills instructions or workspace context).
  final String extraSystemContext;

  /// Optional JSON Schema string enforcing structured output grammar.
  final String? jsonSchema;

  /// Additional executable tools (e.g., workspace file tools or MCP tools)
  /// merged with active built-in/custom Studio tools.
  final List<ToolDefinition> extraTools;

  /// Whether general Chat built-in/custom tools (`getWeather`, `evaluateMath`,
  /// etc.) are merged alongside [extraTools]. Coding turns set this to `false`
  /// to keep the tool surface focused on `pi.dev` + active MCP tools.
  final bool includeBuiltInTools;

  /// Optional per-turn override for `settings.toolsEnabled`.
  final bool? toolsEnabledOverride;

  /// Maximum automatic tool execution rounds before returning.
  final int maxToolRounds;
}

/// Final outcome of a completed assistant turn.
@immutable
class StudioTurnResult {
  /// Creates a [StudioTurnResult].
  const StudioTurnResult({
    required this.text,
    required this.metrics,
    this.thinkingText,
    this.thinkingDurationMs,
    this.toolInvocations = const <StudioToolInvocation>[],
    this.structuredJsonValid,
    this.structuredJsonError,
  });

  /// Final assistant response text.
  final String text;

  /// Collected telemetry for this turn.
  final StudioTurnMetrics metrics;

  /// Optional reasoning/chain-of-thought content.
  final String? thinkingText;

  /// Wall-clock reasoning phase duration in milliseconds.
  final int? thinkingDurationMs;

  /// Recorded tool calls and results executed during the turn.
  final List<StudioToolInvocation> toolInvocations;

  /// Whether [text] validated against `StudioTurnRequest.jsonSchema` when set.
  final bool? structuredJsonValid;

  /// Schema validation error details when `structuredJsonValid == false`.
  final String? structuredJsonError;
}

/// Streaming event emitted while a [StudioInferencePort] executes a turn.
@immutable
sealed class StudioTurnEvent {
  const StudioTurnEvent();
}

/// Incremental visible text delta.
final class StudioTextDeltaEvent extends StudioTurnEvent {
  /// Creates a [StudioTextDeltaEvent].
  const StudioTextDeltaEvent(this.delta);

  /// Newly decoded text chunk.
  final String delta;
}

/// Incremental chain-of-thought reasoning delta.
final class StudioThinkingDeltaEvent extends StudioTurnEvent {
  /// Creates a [StudioThinkingDeltaEvent].
  const StudioThinkingDeltaEvent(this.delta);

  /// Newly decoded reasoning chunk.
  final String delta;
}

/// Emitted when a tool call starts or finishes executing.
final class StudioToolInvocationEvent extends StudioTurnEvent {
  /// Creates a [StudioToolInvocationEvent].
  const StudioToolInvocationEvent(this.invocation);

  /// Updated tool invocation record.
  final StudioToolInvocation invocation;
}

/// Emitted once at the end of a turn with finalized text and metrics.
final class StudioTurnCompletedEvent extends StudioTurnEvent {
  /// Creates a [StudioTurnCompletedEvent].
  const StudioTurnCompletedEvent(this.result);

  /// Finalized turn result.
  final StudioTurnResult result;
}

/// Primary inference port decoupling Studio controllers from concrete engine
/// implementations (`LlamaEngine` vs `genkit_llamadart` vs test fakes).
abstract interface class StudioInferencePort {
  /// Reactive runtime/hardware/capability snapshot store.
  ReadOnlyStore<StudioRuntimeSnapshot> get runtimeStore;

  /// Probes host GPU devices and VRAM without loading a model.
  Future<void> refreshHardwareDiagnostics();

  /// Loads [assets] using [settings] onto the target host.
  Future<void> loadModel({
    required ResolvedModelAssets assets,
    required StudioSettings settings,
    required bool isWeb,
  });

  /// Loads a custom local path or remote URL directly.
  Future<void> loadCustomSource({
    required StudioModelDescriptor descriptor,
    required StudioSettings settings,
    required bool isWeb,
  });

  /// Unloads the active model and releases native/WebGPU buffers.
  Future<void> unloadModel();

  /// Streams incremental [StudioTurnEvent]s for [request].
  Stream<StudioTurnEvent> streamTurn(StudioTurnRequest request);

  /// Cooperatively cancels the active generation turn.
  void cancelGeneration();

  /// Disposes the underlying engine and native resources.
  Future<void> dispose();
}
