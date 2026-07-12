import 'package:nocterm/nocterm.dart';

/// Compact TurboVision-inspired palette used by the single-screen agent.
abstract final class CodingAgentTheme {
  /// Desktop blue.
  static const Color desktop = Color.fromRGB(0, 0, 170);

  /// Dark blue used inside the active session window.
  static const Color panel = Color.fromRGB(0, 0, 128);

  /// Darker code-block background.
  static const Color codeBackground = Color.fromRGB(0, 0, 102);

  /// Classic gray menu/status chrome.
  static const Color chrome = Color.fromRGB(192, 192, 192);

  /// Black text used on gray chrome.
  static const Color chromeText = Color.fromRGB(0, 0, 0);

  /// Dim text used on blue panels.
  static const Color dimText = Color.fromRGB(170, 170, 170);

  /// Cyan selection and scrollbar track.
  static const Color accent = Color.fromRGB(0, 170, 170);

  /// White active-window frame and scrollbar thumb.
  // Nocterm reserves exact white as its theme-color sentinel for borders.
  static const Color frame = Color.fromRGB(255, 255, 254);

  /// Markdown styles for final assistant answers.
  static const MarkdownStyleSheet assistantMarkdown = MarkdownStyleSheet(
    h1Style: TextStyle(color: Colors.brightYellow, fontWeight: FontWeight.bold),
    h2Style: TextStyle(color: Colors.brightCyan, fontWeight: FontWeight.bold),
    h3Style: TextStyle(color: Colors.brightGreen, fontWeight: FontWeight.bold),
    h4Style: TextStyle(fontWeight: FontWeight.bold),
    h5Style: TextStyle(fontWeight: FontWeight.bold),
    h6Style: TextStyle(fontWeight: FontWeight.bold),
    paragraphStyle: TextStyle(color: Colors.brightWhite),
    boldStyle: TextStyle(
      color: Colors.brightWhite,
      fontWeight: FontWeight.bold,
    ),
    italicStyle: TextStyle(
      color: Colors.brightWhite,
      fontStyle: FontStyle.italic,
    ),
    strikethroughStyle: TextStyle(
      color: dimText,
      decoration: TextDecoration.lineThrough,
    ),
    codeStyle: TextStyle(
      color: Colors.brightYellow,
      backgroundColor: codeBackground,
    ),
    blockquoteStyle: TextStyle(
      color: Colors.brightCyan,
      fontStyle: FontStyle.italic,
    ),
    linkStyle: TextStyle(
      color: Colors.brightCyan,
      decoration: TextDecoration.underline,
    ),
    listBullet: '• ',
  );

  /// Subdued Markdown styles for streamed reasoning traces.
  static const MarkdownStyleSheet thinkingMarkdown = MarkdownStyleSheet(
    h1Style: TextStyle(color: dimText, fontWeight: FontWeight.bold),
    h2Style: TextStyle(color: dimText, fontWeight: FontWeight.bold),
    h3Style: TextStyle(color: dimText, fontWeight: FontWeight.bold),
    h4Style: TextStyle(color: dimText, fontWeight: FontWeight.bold),
    h5Style: TextStyle(color: dimText, fontWeight: FontWeight.bold),
    h6Style: TextStyle(color: dimText, fontWeight: FontWeight.bold),
    paragraphStyle: TextStyle(color: dimText, fontStyle: FontStyle.italic),
    boldStyle: TextStyle(color: Colors.brightCyan),
    italicStyle: TextStyle(color: dimText, fontStyle: FontStyle.italic),
    strikethroughStyle: TextStyle(
      color: dimText,
      decoration: TextDecoration.lineThrough,
    ),
    codeStyle: TextStyle(color: Colors.brightYellow),
    blockquoteStyle: TextStyle(color: dimText, fontStyle: FontStyle.italic),
    linkStyle: TextStyle(
      color: Colors.brightCyan,
      decoration: TextDecoration.underline,
    ),
    listBullet: '· ',
  );
}
