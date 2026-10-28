import 'package:llamadart/llamadart.dart' as llama;

/// Why [LlamaDartRuntimePromptCache.importPromptCache] refused an export.
enum LlamaDartPromptCacheImportFailure {
  /// The bytes are truncated, altered or not a prompt cache export.
  corrupt,

  /// The export uses a format version this package does not read.
  unsupportedVersion,

  /// The export was saved from a different model file (SHA-256).
  modelMismatch,

  /// The export was saved by a different native runtime build or with
  /// different context settings that shape the saved state, RoPE included.
  identityMismatch,

  /// The supplied prompt does not tokenize to the exported prompt tokens.
  tokenMismatch,

  /// The export does not fit the pool's prompt cache handle or byte limits.
  overBudget,
}

/// A refused prompt cache import. The message holds no path, prompt or token.
///
/// The importing owner stays open: nothing was restored into its context.
final class LlamaDartPromptCacheImportException
    extends llama.LlamaStateException {
  /// Creates an import refusal for [failure].
  LlamaDartPromptCacheImportException(this.failure, super.message);

  /// Why the import was refused.
  final LlamaDartPromptCacheImportFailure failure;
}
