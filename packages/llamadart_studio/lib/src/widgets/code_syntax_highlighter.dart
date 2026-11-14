// Keep Material types compatible with flutter_markdown (see README).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../app/studio_theme.dart';

/// Multi-language syntax tokenizer producing colored [TextSpan] trees harmonized
/// with [StudioPalette] for both light and dark modes.
abstract final class CodeSyntaxTokenizer {
  /// Infers a normalized language key from a file path or fence tag.
  static String detectLanguage({String? filePath, String? language}) {
    final hint = (language ?? '').trim().toLowerCase();
    if (hint.isNotEmpty) {
      return _normalizeLang(hint);
    }
    if (filePath != null && filePath.isNotEmpty) {
      final dot = filePath.lastIndexOf('.');
      if (dot >= 0 && dot < filePath.length - 1) {
        return _normalizeLang(filePath.substring(dot + 1).toLowerCase());
      }
      final lowerName = filePath.split('/').last.toLowerCase();
      if (lowerName == 'makefile' || lowerName == 'dockerfile') {
        return 'bash';
      }
    }
    return 'auto';
  }

  static String _normalizeLang(String raw) => switch (raw) {
    'dart' => 'dart',
    'json' || 'arb' => 'json',
    'yaml' || 'yml' => 'yaml',
    'sh' || 'bash' || 'zsh' || 'shell' || 'console' => 'bash',
    'py' || 'python' => 'python',
    'js' || 'jsx' || 'ts' || 'tsx' || 'javascript' || 'typescript' => 'js',
    'sql' => 'sql',
    'html' || 'xml' || 'svg' || 'plist' => 'xml',
    'diff' || 'patch' => 'diff',
    'md' || 'markdown' => 'markdown',
    _ => 'generic',
  };

  static final RegExp _pythonHintPattern = RegExp(
    r'^(def |class .*:|from .+ import )',
    multiLine: true,
  );
  static final RegExp _jsHintPattern = RegExp(
    r'^(const |let |function |export |import .* from )',
    multiLine: true,
  );

  static String _inferFromSource(String source) {
    final trimmed = source.trimLeft();
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      if (trimmed.contains('":')) {
        return 'json';
      }
    }
    if (trimmed.startsWith('diff --git') ||
        trimmed.startsWith('--- ') ||
        trimmed.startsWith('@@ ')) {
      return 'diff';
    }
    if (trimmed.startsWith('#!') ||
        trimmed.startsWith(r'$ ') ||
        trimmed.startsWith('dart ') ||
        trimmed.startsWith('flutter ')) {
      return 'bash';
    }
    if (trimmed.contains("import 'package:") ||
        trimmed.contains('Widget build(') ||
        trimmed.contains('Future<') ||
        trimmed.contains('late final ')) {
      return 'dart';
    }
    if (trimmed.startsWith('<') && trimmed.contains('>')) {
      return 'xml';
    }
    if (_pythonHintPattern.hasMatch(trimmed)) {
      return 'python';
    }
    if (_jsHintPattern.hasMatch(trimmed)) {
      return 'js';
    }
    return 'generic';
  }

  static const Set<String> _dartKeywords = <String>{
    'abstract',
    'as',
    'assert',
    'async',
    'await',
    'base',
    'break',
    'case',
    'catch',
    'class',
    'const',
    'continue',
    'covariant',
    'default',
    'deferred',
    'do',
    'dynamic',
    'else',
    'enum',
    'export',
    'extends',
    'extension',
    'external',
    'factory',
    'false',
    'final',
    'finally',
    'for',
    'Function',
    'get',
    'hide',
    'if',
    'implements',
    'import',
    'in',
    'interface',
    'is',
    'late',
    'library',
    'mixin',
    'new',
    'null',
    'on',
    'operator',
    'part',
    'required',
    'rethrow',
    'return',
    'sealed',
    'set',
    'show',
    'static',
    'super',
    'switch',
    'sync',
    'this',
    'throw',
    'true',
    'try',
    'type',
    'typedef',
    'var',
    'void',
    'when',
    'while',
    'with',
    'yield',
  };

  static const Set<String> _genericKeywords = <String>{
    ..._dartKeywords,
    'def',
    'from',
    'None',
    'True',
    'False',
    'self',
    'pass',
    'raise',
    'elif',
    'lambda',
    'nonlocal',
    'global',
    'function',
    'let',
    'undefined',
    'typeof',
    'instanceof',
    'SELECT',
    'FROM',
    'WHERE',
    'INSERT',
    'INTO',
    'UPDATE',
    'DELETE',
    'JOIN',
    'LEFT',
    'RIGHT',
    'ORDER',
    'BY',
    'GROUP',
    'LIMIT',
    'CREATE',
    'TABLE',
    'select',
    'where',
    'echo',
    'cd',
    'grep',
    'awk',
    'sed',
    'git',
    'dart',
    'flutter',
    'pub',
    'mcp',
    'npx',
  };

  static const int _maxHighlightChars = 24000;

  static final RegExp _tokenPattern = RegExp(
    r'(///?.*$|#.*$|/\*[\s\S]*?\*/|'
    r'"""[\s\S]*?"""|'
    r"'''[\s\S]*?'''|"
    r'"(?:\\.|[^"\\\n])*"|'
    r"'(?:\\.|[^'\\\n])*'|"
    r'`(?:\\.|[^`\\\n])*`|'
    r'@[A-Za-z_][A-Za-z0-9_]*|'
    r'\b0x[0-9A-Fa-f]+\b|'
    r'\b\d+(?:\.\d+)?\b|'
    r'\b[A-Za-z_][A-Za-z0-9_]*\b)',
    multiLine: true,
  );

  static final RegExp _numberPattern = RegExp(
    r'^(?:0x[0-9A-Fa-f]+|\d+(?:\.\d+)?)$',
  );

  static bool _isFollowedByColon(String source, int start) {
    for (var i = start; i < source.length; i++) {
      final code = source.codeUnitAt(i);
      if (code == 0x20 || code == 0x09 || code == 0x0D || code == 0x0A) {
        continue;
      }
      return code == 0x3A; // ':'
    }
    return false;
  }

  /// Highlights [source] into a colored [TextSpan] tree.
  static TextSpan highlight(
    String source, {
    required StudioPalette palette,
    required Brightness brightness,
    String? filePath,
    String? language,
    TextStyle? baseStyle,
  }) {
    final defaultStyle =
        baseStyle ??
        TextStyle(
          fontSize: 12,
          height: 1.5,
          color: palette.textPrimary,
          fontFamilyFallback: StudioTheme.monoFontFallback,
        );

    if (source.isEmpty) {
      return TextSpan(style: defaultStyle, text: '');
    }
    if (source.length > _maxHighlightChars) {
      return TextSpan(style: defaultStyle, text: source);
    }

    var lang = detectLanguage(filePath: filePath, language: language);
    if (lang == 'auto') {
      lang = _inferFromSource(source);
    }

    final isDark = brightness == Brightness.dark;
    final keywordColor = isDark
        ? const Color(0xFF93C5FD)
        : const Color(0xFF3730A3);
    final typeColor = isDark
        ? const Color(0xFFFBBF24)
        : const Color(0xFFB45309);
    final stringColor = isDark
        ? const Color(0xFF5EEAD4)
        : const Color(0xFF0F766E);
    final numberColor = isDark
        ? const Color(0xFFC4B5FD)
        : const Color(0xFF6D28D9);
    final commentColor = palette.textMuted;
    final annotationColor = isDark
        ? const Color(0xFFF472B6)
        : const Color(0xFFBE185D);
    final diffAddColor = palette.teal;
    final diffDelColor = palette.danger;

    if (lang == 'diff') {
      final spans = <InlineSpan>[];
      final lines = source.split('\n');
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        final suffix = i < lines.length - 1 ? '\n' : '';
        TextStyle lineStyle = defaultStyle;
        if (line.startsWith('+') && !line.startsWith('+++')) {
          lineStyle = defaultStyle.copyWith(
            color: diffAddColor,
            backgroundColor: diffAddColor.withValues(alpha: 0.10),
          );
        } else if (line.startsWith('-') && !line.startsWith('---')) {
          lineStyle = defaultStyle.copyWith(
            color: diffDelColor,
            backgroundColor: diffDelColor.withValues(alpha: 0.10),
          );
        } else if (line.startsWith('@@') ||
            line.startsWith('diff ') ||
            line.startsWith('+++') ||
            line.startsWith('---')) {
          lineStyle = defaultStyle.copyWith(
            color: keywordColor,
            fontWeight: FontWeight.w600,
          );
        }
        spans.add(TextSpan(text: '$line$suffix', style: lineStyle));
      }
      return TextSpan(style: defaultStyle, children: spans);
    }

    final spans = <InlineSpan>[];
    var cursor = 0;
    final keywords = lang == 'dart' ? _dartKeywords : _genericKeywords;

    for (final match in _tokenPattern.allMatches(source)) {
      if (match.start > cursor) {
        spans.add(TextSpan(text: source.substring(cursor, match.start)));
      }
      final token = match.group(0)!;
      TextStyle? tokenStyle;

      if (token.startsWith('//') ||
          token.startsWith('/*') ||
          (token.startsWith('#') && lang != 'markdown')) {
        tokenStyle = defaultStyle.copyWith(
          color: commentColor,
          fontStyle: FontStyle.italic,
        );
      } else if (token.startsWith('"') ||
          token.startsWith("'") ||
          token.startsWith('`')) {
        // Distinguish JSON keys `"key":` when highlighting JSON.
        if (lang == 'json' && _isFollowedByColon(source, match.end)) {
          tokenStyle = defaultStyle.copyWith(
            color: keywordColor,
            fontWeight: FontWeight.w600,
          );
        } else {
          tokenStyle = defaultStyle.copyWith(color: stringColor);
        }
      } else if (token.startsWith('@')) {
        tokenStyle = defaultStyle.copyWith(color: annotationColor);
      } else if (_numberPattern.hasMatch(token)) {
        tokenStyle = defaultStyle.copyWith(color: numberColor);
      } else if (keywords.contains(token)) {
        tokenStyle = defaultStyle.copyWith(
          color: keywordColor,
          fontWeight: FontWeight.w600,
        );
      } else if (token.isNotEmpty &&
          token[0] == token[0].toUpperCase() &&
          token[0] != token[0].toLowerCase()) {
        tokenStyle = defaultStyle.copyWith(color: typeColor);
      }

      spans.add(TextSpan(text: token, style: tokenStyle));
      cursor = match.end;
    }

    if (cursor < source.length) {
      spans.add(TextSpan(text: source.substring(cursor)));
    }

    return TextSpan(style: defaultStyle, children: spans);
  }
}

/// `flutter_markdown` [SyntaxHighlighter] wired into Studio's palette.
class StudioMarkdownSyntaxHighlighter extends SyntaxHighlighter {
  /// Creates a [StudioMarkdownSyntaxHighlighter].
  StudioMarkdownSyntaxHighlighter({
    required this.palette,
    required this.brightness,
    this.baseStyle,
  });

  /// Active Studio color palette.
  final StudioPalette palette;

  /// Active theme brightness.
  final Brightness brightness;

  /// Optional base monospace text style.
  final TextStyle? baseStyle;

  @override
  TextSpan format(String source) {
    return CodeSyntaxTokenizer.highlight(
      source,
      palette: palette,
      brightness: brightness,
      baseStyle: baseStyle,
    );
  }
}

/// Scrollable syntax-highlighted code viewer with optional line numbers,
/// language pill header, and copy button.
class SyntaxCodeView extends StatelessWidget {
  /// Creates a [SyntaxCodeView].
  const SyntaxCodeView({
    super.key,
    required this.code,
    this.filePath,
    this.language,
    this.startLine = 1,
    this.showLineNumbers = true,
    this.showHeader = false,
    this.fontSize = 11.5,
    this.padding = const EdgeInsets.all(10),
  });

  /// Source code text to display.
  final String code;

  /// Optional file path used for extension-based language inference.
  final String? filePath;

  /// Optional explicit language override.
  final String? language;

  /// Starting 1-based line number for gutter display.
  final int startLine;

  /// Whether to render a line-number gutter.
  final bool showLineNumbers;

  /// Whether to show a compact language/copy bar above the code.
  final bool showHeader;

  /// Code font size.
  final double fontSize;

  /// Content padding inside the scroll viewport.
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final palette = StudioPalette.of(context);
    final brightness = Theme.of(context).brightness;
    final resolvedLang = CodeSyntaxTokenizer.detectLanguage(
      filePath: filePath,
      language: language,
    );

    final lines = code.split('\n');
    final gutterWidth = '${startLine + lines.length - 1}'.length.clamp(3, 8);
    final baseStyle = TextStyle(
      fontSize: fontSize,
      height: 1.5,
      color: palette.textPrimary,
      fontFamilyFallback: StudioTheme.monoFontFallback,
    );

    final highlighted = CodeSyntaxTokenizer.highlight(
      code,
      palette: palette,
      brightness: brightness,
      filePath: filePath,
      language: language,
      baseStyle: baseStyle,
    );

    final lineGutter = showLineNumbers
        ? Padding(
            padding: const EdgeInsets.only(right: 12),
            child: SelectableText(
              List<String>.generate(
                lines.length,
                (int i) => '${startLine + i}'.padLeft(gutterWidth),
              ).join('\n'),
              style: baseStyle.copyWith(
                color: palette.textMuted.withValues(alpha: 0.72),
              ),
            ),
          )
        : null;

    final codeViewport = SingleChildScrollView(
      padding: padding,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[?lineGutter, SelectableText.rich(highlighted)],
        ),
      ),
    );

    if (!showHeader) {
      return codeViewport;
    }

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final header = Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: palette.surfaceElevated,
            border: Border(bottom: BorderSide(color: palette.borderSubtle)),
          ),
          child: Row(
            children: <Widget>[
              Text(
                resolvedLang == 'generic' || resolvedLang == 'auto'
                    ? 'CODE'
                    : resolvedLang.toUpperCase(),
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                  color: palette.textMuted,
                  fontFamilyFallback: StudioTheme.monoFontFallback,
                ),
              ),
              const Spacer(),
              InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: () async {
                  await Clipboard.setData(ClipboardData(text: code));
                  if (context.mounted) {
                    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                      const SnackBar(content: Text('Copied code to clipboard')),
                    );
                  }
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Icon(
                        Icons.copy_rounded,
                        size: 13,
                        color: palette.textSecondary,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'Copy',
                        style: TextStyle(
                          fontSize: 11,
                          color: palette.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: constraints.hasBoundedHeight
              ? MainAxisSize.max
              : MainAxisSize.min,
          children: <Widget>[
            header,
            if (constraints.hasBoundedHeight)
              Expanded(child: codeViewport)
            else
              codeViewport,
          ],
        );
      },
    );
  }
}
