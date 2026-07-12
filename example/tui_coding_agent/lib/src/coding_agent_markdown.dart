import 'package:markdown/markdown.dart' as md;
import 'package:nocterm/nocterm.dart';

import 'coding_agent_syntax_highlighter.dart';
import 'coding_agent_theme.dart';

/// Compact Markdown renderer for assistant answers and reasoning traces.
class CodingAgentMarkdownText extends StatefulComponent {
  /// Markdown source to render.
  final String data;

  /// Whether to use the subdued reasoning style.
  final bool thinking;

  /// Creates coding-agent Markdown text.
  const CodingAgentMarkdownText({
    required this.data,
    this.thinking = false,
    super.key,
  });

  @override
  State<CodingAgentMarkdownText> createState() =>
      _CodingAgentMarkdownTextState();
}

class _CodingAgentMarkdownTextState extends State<CodingAgentMarkdownText> {
  String? _lastData;
  bool? _lastThinking;
  List<Component> _blocks = const <Component>[];

  @override
  Component build(BuildContext context) {
    if (_lastData != component.data || _lastThinking != component.thinking) {
      _lastData = component.data;
      _lastThinking = component.thinking;
      _blocks = _CompactMarkdownRenderer(
        thinking: component.thinking,
      ).render(component.data);
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: _blocks,
    );
  }
}

class _CompactMarkdownRenderer {
  _CompactMarkdownRenderer({required this.thinking})
    : styleSheet = thinking
          ? CodingAgentTheme.thinkingMarkdown
          : CodingAgentTheme.assistantMarkdown;

  final bool thinking;
  final MarkdownStyleSheet styleSheet;
  late final _InlineMarkdownRenderer _inline = _InlineMarkdownRenderer(
    styleSheet,
  );

  List<Component> render(String data) {
    final document = md.Document(
      extensionSet: md.ExtensionSet.gitHubFlavored,
      encodeHtml: false,
    );
    return <Component>[
      for (final node in document.parse(data)) _renderBlock(node),
    ];
  }

  Component _renderBlock(md.Node node) {
    if (node is! md.Element) {
      return Text(node.textContent, style: styleSheet.paragraphStyle);
    }

    return switch (node.tag) {
      'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6' => _renderHeading(node),
      'p' => _renderInlineBlock(node, styleSheet.paragraphStyle),
      'pre' => _renderCodeBlock(node),
      'ul' || 'ol' => _renderList(node),
      'blockquote' => _renderBlockquote(node),
      'hr' => _CompactHorizontalRule(
        character: styleSheet.horizontalRule,
        color: thinking ? CodingAgentTheme.dimText : Colors.brightBlack,
      ),
      'table' => _renderTable(node),
      _ => _renderInlineBlock(node, styleSheet.paragraphStyle),
    };
  }

  Component _renderHeading(md.Element element) {
    final level = int.tryParse(element.tag.substring(1)) ?? 1;
    final style = switch (level) {
      1 => styleSheet.h1Style,
      2 => styleSheet.h2Style,
      3 => styleSheet.h3Style,
      4 => styleSheet.h4Style,
      5 => styleSheet.h5Style,
      _ => styleSheet.h6Style,
    };
    return RichText(
      text: TextSpan(
        style: style,
        children: <InlineSpan>[
          TextSpan(text: '${'#' * level} '),
          ..._inline.renderChildren(element),
        ],
      ),
    );
  }

  Component _renderInlineBlock(md.Element element, TextStyle? style) {
    return RichText(
      text: TextSpan(style: style, children: _inline.renderChildren(element)),
    );
  }

  Component _renderCodeBlock(md.Element element) {
    final codeElement = element.children?.whereType<md.Element>().firstOrNull;
    final rawCode = codeElement?.textContent ?? element.textContent;
    final code = rawCode.endsWith('\n')
        ? rawCode.substring(0, rawCode.length - 1)
        : rawCode;
    final className = codeElement?.attributes['class'];
    final language = className?.startsWith('language-') == true
        ? className!.substring('language-'.length)
        : className;
    return _SyntaxCodeBlock(code: code, language: language, thinking: thinking);
  }

  Component _renderList(md.Element element) {
    return RichText(
      text: TextSpan(
        style: styleSheet.paragraphStyle,
        children: _listSpans(element, depth: 0),
      ),
    );
  }

  List<InlineSpan> _listSpans(md.Element list, {required int depth}) {
    final items = list.children?.whereType<md.Element>().where(
      (child) => child.tag == 'li',
    );
    if (items == null) {
      return const <InlineSpan>[];
    }

    final ordered = list.tag == 'ol';
    final start = int.tryParse(list.attributes['start'] ?? '') ?? 1;
    final spans = <InlineSpan>[];
    var itemIndex = 0;
    for (final item in items) {
      if (itemIndex > 0) {
        spans.add(const TextSpan(text: '\n'));
      }
      final marker = ordered ? '${start + itemIndex}. ' : styleSheet.listBullet;
      spans.add(TextSpan(text: '${'  ' * depth}$marker'));

      for (final child in item.children ?? const <md.Node>[]) {
        if (child is md.Element && (child.tag == 'ul' || child.tag == 'ol')) {
          spans
            ..add(const TextSpan(text: '\n'))
            ..addAll(_listSpans(child, depth: depth + 1));
        } else {
          spans.add(_inline.renderNode(child));
        }
      }
      itemIndex++;
    }
    return spans;
  }

  Component _renderBlockquote(md.Element element) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Component>[
        Text('│ ', style: styleSheet.blockquoteStyle),
        Expanded(
          child: RichText(
            text: TextSpan(
              style: styleSheet.blockquoteStyle,
              children: _inline.renderChildren(element),
            ),
          ),
        ),
      ],
    );
  }

  Component _renderTable(md.Element table) {
    final rows = <List<String>>[];
    _collectTableRows(table, rows);
    if (rows.isEmpty) {
      return const SizedBox();
    }

    final columnCount = rows.fold<int>(
      0,
      (maximum, row) => row.length > maximum ? row.length : maximum,
    );
    final widths = List<int>.filled(columnCount, 0);
    for (final row in rows) {
      for (var column = 0; column < row.length; column++) {
        if (row[column].length > widths[column]) {
          widths[column] = row[column].length;
        }
      }
    }

    String renderRow(List<String> row) {
      final cells = <String>[
        for (var column = 0; column < columnCount; column++)
          (column < row.length ? row[column] : '').padRight(widths[column]),
      ];
      return '│ ${cells.join(' │ ')} │';
    }

    final separator = '├─${widths.map((width) => '─' * width).join('─┼─')}─┤';
    final lines = <String>[];
    for (var row = 0; row < rows.length; row++) {
      lines.add(renderRow(rows[row]));
      if (row == 0 && rows.length > 1) {
        lines.add(separator);
      }
    }
    return Text(lines.join('\n'), style: styleSheet.paragraphStyle);
  }

  void _collectTableRows(md.Element element, List<List<String>> rows) {
    if (element.tag == 'tr') {
      rows.add(<String>[
        for (final cell
            in element.children?.whereType<md.Element>() ??
                const Iterable<md.Element>.empty())
          if (cell.tag == 'th' || cell.tag == 'td') cell.textContent.trim(),
      ]);
      return;
    }
    for (final child
        in element.children?.whereType<md.Element>() ??
            const Iterable<md.Element>.empty()) {
      _collectTableRows(child, rows);
    }
  }
}

class _InlineMarkdownRenderer {
  const _InlineMarkdownRenderer(this.styleSheet);

  final MarkdownStyleSheet styleSheet;

  List<InlineSpan> renderChildren(md.Element element) {
    return <InlineSpan>[
      for (final child in element.children ?? const <md.Node>[])
        renderNode(child),
    ];
  }

  InlineSpan renderNode(md.Node node) {
    if (node is md.Text) {
      return TextSpan(text: node.text);
    }
    if (node is! md.Element) {
      return TextSpan(text: node.textContent);
    }

    final children = renderChildren(node);
    return switch (node.tag) {
      'strong' ||
      'b' => TextSpan(style: styleSheet.boldStyle, children: children),
      'em' ||
      'i' => TextSpan(style: styleSheet.italicStyle, children: children),
      'del' ||
      's' => TextSpan(style: styleSheet.strikethroughStyle, children: children),
      'code' => TextSpan(text: node.textContent, style: styleSheet.codeStyle),
      'a' => _renderLink(node, children),
      'img' => TextSpan(
        text: '[Image: ${node.attributes['alt'] ?? 'image'}]',
        style: styleSheet.italicStyle,
      ),
      'input' => TextSpan(
        text: node.attributes.containsKey('checked') ? '[x] ' : '[ ] ',
      ),
      'br' => const TextSpan(text: '\n'),
      _ => TextSpan(children: children),
    };
  }

  InlineSpan _renderLink(md.Element element, List<InlineSpan> children) {
    final href = element.attributes['href'] ?? '';
    return TextSpan(
      children: <InlineSpan>[
        TextSpan(style: styleSheet.linkStyle, children: children),
        if (href.isNotEmpty && element.textContent != href)
          TextSpan(text: ' [$href]', style: styleSheet.linkStyle),
      ],
    );
  }
}

class _SyntaxCodeBlock extends StatefulComponent {
  const _SyntaxCodeBlock({
    required this.code,
    required this.language,
    required this.thinking,
  });

  final String code;
  final String? language;
  final bool thinking;

  @override
  State<_SyntaxCodeBlock> createState() => _SyntaxCodeBlockState();
}

class _SyntaxCodeBlockState extends State<_SyntaxCodeBlock> {
  String? _lastCode;
  String? _lastLanguage;
  bool? _lastThinking;
  InlineSpan _highlighted = const TextSpan();

  @override
  Component build(BuildContext context) {
    if (_lastCode != component.code ||
        _lastLanguage != component.language ||
        _lastThinking != component.thinking) {
      _lastCode = component.code;
      _lastLanguage = component.language;
      _lastThinking = component.thinking;
      _highlighted = CodingAgentSyntaxHighlighter.highlightCode(
        component.code.isEmpty ? ' ' : component.code,
        language: component.language,
        thinking: component.thinking,
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 1),
      color: CodingAgentTheme.codeBackground,
      child: RichText(text: _highlighted),
    );
  }
}

class _CompactHorizontalRule extends StatelessComponent {
  const _CompactHorizontalRule({required this.character, required this.color});

  final String character;
  final Color color;

  @override
  Component build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.toInt().clamp(1, 200);
        return Text(character * width, style: TextStyle(color: color));
      },
    );
  }
}
