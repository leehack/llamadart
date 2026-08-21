/// Shared media-placeholder normalization for multimodal prompts.
///
/// Both the chat-template handlers and the llama.cpp service normalize, so the
/// table lives here to keep them in step.
library;

/// The mtmd marker the native tokenizer matches media parts against.
///
/// The llama.cpp service prefers the runtime-reported marker and falls back to
/// this when the symbol is unavailable.
const String mtmdMediaMarker = '<__media__>';

/// Model-specific media placeholders rewritten to [mtmdMediaMarker].
const List<String> mtmdMediaPlaceholders = <String>[
  '<image>', // SmolVLM, InternVL, etc.
  '[IMG]', // Some CLIP-based models
  '<|image|>', // Phi-3 vision
  '<|audio|>',
  '<|video|>',
  '<img>',
  '<|img|>',
  '<start_of_image>', // Gemma
  '<image_soft_token>',
  '<audio_soft_token>',
  '<video_soft_token>',
];

/// Indexed image placeholders such as `<|image_1|>`, used by some VLM templates.
final RegExp mtmdIndexedImagePlaceholder = RegExp(r'<\|image_\d+\|>');

/// Rewrites every known media placeholder in [prompt] to [marker].
String normalizeMediaPlaceholders(
  String prompt, {
  String marker = mtmdMediaMarker,
}) {
  var normalized = prompt;
  for (final placeholder in mtmdMediaPlaceholders) {
    normalized = normalized.replaceAll(placeholder, marker);
  }
  return normalized.replaceAll(mtmdIndexedImagePlaceholder, marker);
}
