import 'dart:convert';

import 'package:highlighting/highlighting.dart' as syntax_highlight;
import 'package:highlighting/languages/all.dart' show builtinLanguages;
import 'package:nocterm/nocterm.dart';

import 'coding_agent_theme.dart';

const int _maximumHighlightedCharacters = 64 * 1024;

const Map<String, String> _languageAliases = <String, String>{
  'c++': 'cpp',
  'c#': 'csharp',
  'cs': 'csharp',
  'console': 'bash',
  'docker': 'dockerfile',
  'golang': 'go',
  'html': 'xml',
  'js': 'javascript',
  'jsx': 'javascript',
  'jsonc': 'json',
  'kt': 'kotlin',
  'md': 'markdown',
  'objective-c': 'objectivec',
  'objc': 'objectivec',
  'ps1': 'powershell',
  'py': 'python',
  'rb': 'ruby',
  'rs': 'rust',
  'sh': 'bash',
  'shell': 'bash',
  'text': 'plaintext',
  'toml': 'ini',
  'tsx': 'typescript',
  'ts': 'typescript',
  'txt': 'plaintext',
  'xhtml': 'xml',
  'yml': 'yaml',
  'zsh': 'bash',
};

/// Converts fenced source code into Nocterm spans using Highlight.js grammars.
abstract final class CodingAgentSyntaxHighlighter {
  /// Highlights [code] when [language] is known, otherwise returns plain code.
  ///
  /// Unlabelled JSON, diffs, shell scripts, and common Dart snippets are
  /// detected cheaply. Very large blocks stay plain to keep streamed rendering
  /// responsive.
  static InlineSpan highlightCode(
    String code, {
    String? language,
    bool thinking = false,
  }) {
    final baseStyle = TextStyle(
      color: thinking ? CodingAgentTheme.dimText : Colors.brightWhite,
    );
    if (code.length > _maximumHighlightedCharacters) {
      return TextSpan(text: code, style: baseStyle);
    }
    final languageId = _resolveLanguage(language, code);
    if (languageId == null) {
      return TextSpan(text: code, style: baseStyle);
    }

    try {
      final result = syntax_highlight.highlight.parse(
        code,
        languageId: languageId,
      );
      return TextSpan(
        style: baseStyle,
        children: <InlineSpan>[
          for (final node in result.rootNode.children)
            _spanForNode(node, thinking: thinking),
        ],
      );
    } on Object {
      return TextSpan(text: code, style: baseStyle);
    }
  }

  static InlineSpan _spanForNode(
    syntax_highlight.Node node, {
    required bool thinking,
  }) {
    final value = node.value;
    if (value != null) {
      return TextSpan(text: value);
    }
    return TextSpan(
      style: _styleForScope(node.className, thinking: thinking),
      children: <InlineSpan>[
        for (final child in node.children)
          _spanForNode(child, thinking: thinking),
      ],
    );
  }

  static TextStyle? _styleForScope(String? scope, {required bool thinking}) {
    if (scope == null || scope.isEmpty) {
      return null;
    }
    final name = scope.toLowerCase();
    if (name.contains('deletion')) {
      return const TextStyle(color: Colors.brightRed);
    }
    if (name.contains('addition')) {
      return const TextStyle(color: Colors.brightGreen);
    }
    if (name.contains('comment') || name.contains('quote')) {
      return TextStyle(
        color: thinking ? CodingAgentTheme.dimText : Colors.brightBlack,
        fontStyle: FontStyle.italic,
      );
    }
    if (name.contains('string') ||
        name.contains('regexp') ||
        name.contains('template-tag')) {
      return const TextStyle(color: Colors.brightGreen);
    }
    if (name.contains('number') ||
        name.contains('literal') ||
        name.contains('symbol') ||
        name.contains('bullet')) {
      return const TextStyle(color: Colors.brightYellow);
    }
    if (name.contains('keyword') ||
        name.contains('operator') ||
        name.contains('selector-tag')) {
      return const TextStyle(
        color: Colors.brightMagenta,
        fontWeight: FontWeight.bold,
      );
    }
    if (name.contains('title') ||
        name.contains('type') ||
        name.contains('class') ||
        name.contains('built_in') ||
        name.contains('built-in')) {
      return const TextStyle(color: Colors.brightCyan);
    }
    if (name.contains('meta') ||
        name.contains('tag') ||
        name.contains('name') ||
        name.contains('attr')) {
      return const TextStyle(color: Colors.brightBlue);
    }
    if (name.contains('section')) {
      return const TextStyle(
        color: Colors.brightYellow,
        fontWeight: FontWeight.bold,
      );
    }
    return TextStyle(
      color: thinking ? CodingAgentTheme.dimText : Colors.brightWhite,
    );
  }

  static String? _resolveLanguage(String? language, String code) {
    final requested = language?.trim().toLowerCase();
    if (requested != null && requested.isNotEmpty) {
      final withoutPrefix = requested.startsWith('language-')
          ? requested.substring('language-'.length)
          : requested;
      var normalized = withoutPrefix.split(RegExp(r'\s+')).first;
      if (normalized.startsWith('{') && normalized.endsWith('}')) {
        normalized = normalized.substring(1, normalized.length - 1);
      }
      if (normalized.startsWith('.')) {
        normalized = normalized.substring(1);
      }
      final canonical = _languageAliases[normalized] ?? normalized;
      return builtinLanguages.containsKey(canonical) ? canonical : null;
    }

    final trimmed = code.trimLeft();
    if (trimmed.startsWith('diff --git ') || trimmed.startsWith('@@ ')) {
      return 'diff';
    }
    if (trimmed.startsWith('#!') &&
        (trimmed.contains('/sh') || trimmed.contains('/bash'))) {
      return 'bash';
    }
    if (trimmed.startsWith("import 'package:") ||
        trimmed.contains('void main(')) {
      return 'dart';
    }
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      final completeContainer = trimmed.startsWith('{')
          ? trimmed.endsWith('}')
          : trimmed.endsWith(']');
      if (completeContainer) {
        try {
          jsonDecode(trimmed);
          return 'json';
        } on FormatException {
          // It resembles JSON but is another language.
        }
      }
    }
    return null;
  }
}
