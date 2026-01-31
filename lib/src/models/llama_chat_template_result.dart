/// The result of applying a chat template to a conversation history.
class LlamaChatTemplateResult {
  /// The formatted prompt string ready for inference.
  final String prompt;

  /// Automatically detected stop sequences associated with this template.
  final List<String> stopSequences;

  /// Creates a new template result.
  LlamaChatTemplateResult({required this.prompt, required this.stopSequences});
}
