part of 'notebook_controller.dart';

/// Editor text that remains available until its note is saved successfully.
@immutable
class NotebookDraft {
  /// Creates an unsaved note draft.
  const NotebookDraft({
    required this.title,
    required this.content,
    required this.tags,
    required this.transcript,
  });

  /// Unnormalized title text from the editor.
  final String title;

  /// Note body text.
  final String content;

  /// Comma-separated tags, including unfinished input.
  final String tags;

  /// Editable audio transcript.
  final String transcript;
}
