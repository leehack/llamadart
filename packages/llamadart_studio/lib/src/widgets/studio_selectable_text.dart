// Keep Material types compatible with flutter_markdown (see README).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';

/// Selectable output exposed to accessibility as static text.
///
/// Flutter 3.50's macOS bridge sends editing messages to read-only text fields
/// when their value changes. SelectionArea keeps selection and copy available
/// without giving output the semantics of an editable control.
class StudioSelectableText extends StatelessWidget {
  /// Creates selectable plain text.
  const StudioSelectableText(String this.data, {super.key, this.style})
    : textSpan = null;

  /// Creates selectable styled text.
  const StudioSelectableText.rich(
    InlineSpan this.textSpan, {
    super.key,
    this.style,
  }) : data = null;

  /// Plain text to display.
  final String? data;

  /// Styled text to display.
  final InlineSpan? textSpan;

  /// Default text style.
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return SelectionArea(
      child: textSpan == null
          ? Text(data!, style: style)
          : Text.rich(textSpan!, style: style),
    );
  }
}
