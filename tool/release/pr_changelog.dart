import 'dart:convert';
import 'dart:io';

const changelogPackages = {
  'packages/llamadart_llama_cpp_flutter',
  'packages/llamadart_litert_lm_flutter',
  'packages/llamadart_stable_diffusion_flutter',
  'packages/genkit_llamadart',
  'packages/llamadart_model_store',
};

final coreReleaseVersion = RegExp(
  r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)'
  r'(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$',
);

typedef ChangelogBullet = ({String target, String text});

class PrChangelog {
  PrChangelog._(this.bullets, this.reason, this.outsideLines);

  final List<ChangelogBullet> bullets;
  final String? reason;
  final List<String> outsideLines;
}

final _heading = RegExp(r'^ {0,3}(#{1,2})(?:[ \t]+(.*)|$)');
final _closingHashes = RegExp(r'[ \t]+#+[ \t]*$');
final _fence = RegExp(r'^ {0,3}(`{3,}|~{3,})(.*)$');
final _listMarker = RegExp(r'^ {0,3}(?:[-+*]|[0-9]{1,9}[.)]) +(?=\S)');
final _quote = RegExp(r'^ {0,3}>');
final _backticks = RegExp(r'`+');
final _commentToken = RegExp(r'`+|<!--');
final _scope = RegExp(r'^\[(core|packages/[^\]]*)\](?![([])');
final _checkBox = RegExp(r'^\[[ xX]\](?:\s|$)');
final _notApplicable = RegExp(r'^N/A\s*(?::|$)', caseSensitive: false);
final _invisibleText = RegExp(
  r'[\p{Cf}\p{Default_Ignorable_Code_Point}\u2800\s*_~`\[\]]',
  unicode: true,
);
final _placeholder = RegExp(
  r'^\s*(?:tbd|todo|placeholder|fill (?:me|this) in|insert (?:text|reason) here|<[^>]+>)[.!]?\s*$',
  caseSensitive: false,
);

/// Parses a PR description or a commit body after Git trailer removal.
PrChangelog parsePrChangelog(String body) {
  final bullets = <ChangelogBullet>[];
  final outside = <String>[];
  String? reason;
  var found = false;
  var inSection = false;
  var inComment = false;
  for (final row in _markdownLines(body)) {
    final (
      index: _,
      :line,
      :visible,
      :heading,
      :nested,
      :example,
      inComment: commentContinues,
    ) = row;
    inComment = commentContinues;
    if (example != null) {
      if (inSection) _invalid('$example content is not an entry.');
      continue;
    }
    if (heading != null) {
      inSection = _isSection(heading, 'Changelog');
      if (inSection) {
        if (found) _invalid('provide exactly one section.');
        found = true;
        continue;
      }
    }
    if (!inSection) {
      if (visible == line && !nested) {
        outside.add(line);
      }
      continue;
    }
    if (visible.trim().isEmpty) continue;
    if (visible != line) _invalid('put guidance comments on their own lines.');
    if (line.startsWith('N/A: ')) {
      if (reason != null || bullets.isNotEmpty) {
        _invalid('N/A must stand alone.');
      }
      reason = line.substring(5).trim();
      _validateText(reason);
      continue;
    }
    if (!line.startsWith('- ')) {
      _invalid('use a column-zero "- " bullet or "N/A: <specific reason>".');
    }
    if (reason != null) _invalid('N/A must stand alone.');
    var text = line.substring(2);
    var target = 'core';
    final scope = _scope.firstMatch(text);
    if (scope != null) {
      target = scope[1]!;
      if (!text.substring(scope.end).startsWith(' ')) {
        _invalid('put a space after the target prefix.');
      }
      if (target != 'core' && !changelogPackages.contains(target)) {
        _invalid('unknown package target.');
      }
      text = text.substring(scope.end + 1);
    }
    text = text.trim();
    _validateText(text);
    bullets.add((target: target, text: text));
  }
  if (!found) _invalid('add a top-level "## Changelog" section.');
  if (inSection && inComment) _invalid('close the guidance comment.');
  if (bullets.isEmpty && reason == null) {
    _invalid('add a bullet or a specific N/A reason.');
  }
  return PrChangelog._(
    List.unmodifiable(bullets),
    reason,
    List.unmodifiable(outside),
  );
}

Never _invalid(String problem) => throw FormatException('Changelog: $problem');

void _validateText(String text) {
  if (!_specificText(text)) {
    _invalid('write visible text and replace placeholders and checkboxes.');
  }
}

bool _specificText(String text) =>
    text.replaceAll(_invisibleText, '').isNotEmpty &&
    !_checkBox.hasMatch(text) &&
    !_notApplicable.hasMatch(text) &&
    !_placeholder.hasMatch(text) &&
    text != '...';

bool _isSection(Match heading, String title) =>
    heading[1] == '##' &&
    (heading[2] ?? '').replaceFirst(_closingHashes, '').trim() == title;

typedef _MarkdownLine = ({
  int index,
  String line,
  String visible,
  Match? heading,
  bool nested,
  String? example,
  bool inComment,
});

Iterable<_MarkdownLine> _markdownLines(String body) sync* {
  var inComment = false;
  String? fence;
  var listIndent = 0;
  for (final (index, line) in const LineSplitter().convert(body).indexed) {
    final fenceMatch = _fence.firstMatch(line);
    if (fence != null) {
      if (fenceMatch != null &&
          fenceMatch[1]!.startsWith(fence) &&
          fenceMatch[2]!.trim().isEmpty) {
        fence = null;
      }
      continue;
    }
    if (!inComment && _quote.hasMatch(line)) {
      yield (
        index: index,
        line: line,
        visible: '',
        heading: null,
        nested: false,
        example: 'quoted',
        inComment: false,
      );
      continue;
    }
    if (!inComment && fenceMatch != null) {
      final marker = fenceMatch[1]!;
      if (!marker.startsWith('`') || !fenceMatch[2]!.contains('`')) {
        yield (
          index: index,
          line: line,
          visible: '',
          heading: null,
          nested: false,
          example: 'fenced',
          inComment: false,
        );
        fence = marker;
        continue;
      }
    }

    final (visible, commentContinues) = _withoutComments(line, inComment);
    inComment = commentContinues;
    final indent = line.length - line.trimLeft().length;
    final nested = listIndent != 0 && indent >= listIndent;
    if (!nested && visible.trim().isNotEmpty) {
      listIndent = _listMarker.firstMatch(visible)?.end ?? 0;
    }
    final heading = nested ? null : _heading.firstMatch(line);
    yield (
      index: index,
      line: line,
      visible: visible,
      heading: heading != null && visible.startsWith(heading[0]!)
          ? heading
          : null,
      nested: nested,
      example: null,
      inComment: inComment,
    );
  }
}

/// Zero-based lines that can supply visible release bullets in committed Markdown.
Set<int> visibleReleaseBulletLines(String body) => {
  for (final row in _markdownLines(body))
    if (!row.nested &&
        row.line.startsWith('- ') &&
        row.visible.startsWith('- '))
      row.index,
};

/// The independently resolved identifiers written into a release prep body.
typedef ReleaseNotesInput = ({
  String previousTag,
  String previousSha,
  String through,
  String inputSha256,
});

final _previousField = RegExp(r'^Previous-tag: (v[^@ ]+)@([a-f0-9]{40})$');
final _throughField = RegExp(r'^Through: ([a-f0-9]{40})$');
final _inputDigestField = RegExp(r'^Input-SHA256: ([a-f0-9]{64})$');
final _reviewRow = RegExp(r'^- ([a-f0-9]{40}) (\S.*)$');
final _genericReview = RegExp(
  r'^(?:ack(?:nowledged)?|reviewed|done|ok|omit(?:ted)?|drop(?:ped)?|keep|kept|combine(?:d)?)[.!]?$',
  caseSensitive: false,
);

/// Reads the receipt from a prep PR body or landed message.
ReleaseNotesInput parseReleaseNotesInput(String body) {
  const title = 'Release notes input';
  final lines = _metadataSection(body, title);
  if (lines == null) throw const FormatException('$title: add one section.');
  final fields = <String, Match>{};
  for (final line in lines) {
    if (_previousField.firstMatch(line) case final tag?
        when coreReleaseVersion.hasMatch(tag[1]!.substring(1)) &&
            !fields.containsKey('Previous-tag')) {
      fields['Previous-tag'] = tag;
    } else if (_throughField.firstMatch(line) case final through?
        when !fields.containsKey('Through')) {
      fields['Through'] = through;
    } else if (_inputDigestField.firstMatch(line) case final digest?
        when !fields.containsKey('Input-SHA256')) {
      fields['Input-SHA256'] = digest;
    } else {
      throw const FormatException('$title: duplicate or malformed field.');
    }
  }
  for (final field in ['Previous-tag', 'Through', 'Input-SHA256']) {
    if (!fields.containsKey(field)) {
      throw FormatException('$title: missing $field.');
    }
  }
  return (
    previousTag: fields['Previous-tag']![1]!,
    previousSha: fields['Previous-tag']![2]!,
    through: fields['Through']![1]!,
    inputSha256: fields['Input-SHA256']![1]!,
  );
}

/// Reads one editorial disposition per affected source commit.
Map<String, String> parseReleaseNotesReview(String body) {
  const title = 'Release notes review';
  final reviews = <String, String>{};
  for (final line in _metadataSection(body, title) ?? const <String>[]) {
    final row = _reviewRow.firstMatch(line);
    if (row == null) {
      throw const FormatException(
        '$title: use "- <SHA> <specific disposition>".',
      );
    }
    final sha = row[1]!;
    final text = row[2]!.trimRight();
    if (!_specificText(text) || _genericReview.hasMatch(text)) {
      throw FormatException('$title: provide a specific disposition for $sha.');
    }
    if (reviews.containsKey(sha)) {
      throw FormatException('$title: duplicate disposition for $sha.');
    }
    reviews[sha] = text;
  }
  return reviews;
}

List<String>? _metadataSection(String body, String title) {
  List<String>? lines;
  var inSection = false;
  for (final row in _markdownLines(body)) {
    if (row.heading case final heading?) {
      inSection = _isSection(heading, title);
      if (inSection) {
        if (lines != null) {
          throw FormatException('$title: provide exactly one section.');
        }
        lines = [];
        continue;
      }
    }
    if (!inSection || row.visible.trim().isEmpty) continue;
    if (row.nested || row.line != row.visible) {
      throw FormatException('$title: malformed field or review entry.');
    }
    lines!.add(row.line);
  }
  return lines;
}

(String, bool) _withoutComments(String line, bool inComment) {
  final visible = StringBuffer();
  var offset = 0;
  while (offset < line.length) {
    if (inComment) {
      final end = line.indexOf('-->', offset);
      if (end == -1) break;
      offset = end + 3;
      inComment = false;
      continue;
    }
    final token = _commentToken.matchAsPrefix(line, offset);
    if (token == null) {
      visible.write(line[offset++]);
    } else if (token[0] == '<!--') {
      inComment = true;
      offset = token.end;
    } else {
      final closing = _backticks
          .allMatches(line, token.end)
          .where((match) => match[0] == token[0])
          .firstOrNull;
      final next = closing?.end ?? token.end;
      visible.write(line.substring(offset, next));
      offset = next;
    }
  }
  return (visible.toString(), inComment);
}

/// Removes the subject from a commit message after Git trailer removal.
String landedPrBody(String message) {
  final lines = const LineSplitter().convert(message);
  final nonEmpty = lines.lastIndexWhere((line) => line.trim().isNotEmpty);
  if (nonEmpty <= 0) return '';
  return lines.sublist(1, nonEmpty + 1).join('\n');
}

void main(List<String> args) {
  if (args.length != 1 || args.single != '--event') {
    stderr.writeln('Usage: dart tool/release/pr_changelog.dart --event');
    exitCode = 64;
    return;
  }
  final eventPath = Platform.environment['GITHUB_EVENT_PATH'];
  try {
    if (eventPath == null || eventPath.isEmpty) {
      _invalid('GITHUB_EVENT_PATH is required.');
    }
    final event = jsonDecode(File(eventPath).readAsStringSync());
    if (event case {'pull_request': {'body': final String body}}) {
      parsePrChangelog(body);
      stdout.writeln('Changelog section is valid.');
    } else {
      _invalid('the event has no pull request description.');
    }
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    exitCode = 1;
  } on FileSystemException {
    stderr.writeln('Changelog: could not read GITHUB_EVENT_PATH.');
    exitCode = 1;
  }
}
