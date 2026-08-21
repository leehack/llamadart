/// Shared media-placeholder normalization for multimodal prompts.
///
/// Model templates emit their own image/audio/video placeholders, which must be
/// rewritten to the mtmd marker so the native tokenizer can bind bitmaps to
/// positions in the prompt. Two layers do this — the chat-template handlers and
/// the llama.cpp service — and a marker added to only one of them makes the
/// result depend on which path rendered the prompt. Keep the table here so both
/// stay in step.
library;

/// The mtmd marker the native tokenizer matches media parts against.
///
/// The llama.cpp service prefers the marker reported by the runtime and falls
/// back to this value when the symbol is unavailable.
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
