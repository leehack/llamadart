@TestOn('vm')
library;

import 'dart:io';

import 'package:llamadart/src/core/template/chat_format.dart';
import 'package:llamadart/src/core/template/chat_format_registry.dart';
import 'package:llamadart/src/core/template/chat_template_engine.dart';
import 'package:test/test.dart';

void main() {
  test('registers every ChatFormat exactly once', () {
    final registered = chatFormatRegistrations.map((r) => r.format).toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    expect(registered, ChatFormat.values);
  });

  test('leaves only engine-selected formats without a detector', () {
    expect(
      chatFormatRegistrations
          .where((registration) => registration.detect == null)
          .map((registration) => registration.format)
          .toSet(),
      {
        ChatFormat.contentOnly,
        ChatFormat.generic,
        ChatFormat.llama3BuiltinTools,
        ChatFormat.pegSimple,
        ChatFormat.pegNative,
        ChatFormat.pegConstructed,
      },
    );
  });

  test('each handler reports the format it is registered for', () {
    for (final registration in chatFormatRegistrations) {
      final expected = registration.format == ChatFormat.llama3BuiltinTools
          ? ChatFormat.llama3
          : registration.format;
      expect(
        registration.createHandler().format,
        expected,
        reason: registration.format.name,
      );
    }
  });

  test('every concrete handler class in handlers/ is registered', () {
    final declared = <String>{
      for (final file in Directory(
        'lib/src/core/template/handlers',
      ).listSync().whereType<File>())
        for (final match in RegExp(
          r'^class ([A-Z]\w*Handler) extends',
          multiLine: true,
        ).allMatches(file.readAsStringSync()))
          match.group(1)!,
    };
    final registered = {
      for (final registration in chatFormatRegistrations)
        registration.createHandler().runtimeType.toString(),
    };
    expect(declared, isNotEmpty);
    expect(declared.difference(registered), isEmpty);
  });

  test('handlerFor caches the registered handler', () {
    for (final format in ChatFormat.values) {
      final handler = ChatTemplateEngine.handlerFor(format);
      expect(
        handler.runtimeType,
        chatFormatRegistration(format).createHandler().runtimeType,
        reason: format.name,
      );
      expect(ChatTemplateEngine.handlerFor(format), same(handler));
    }
  });

  test('format tables live only in the registry', () {
    for (final path in const [
      'lib/src/core/engine/chat_completion_stream_parser.dart',
      'lib/src/core/template/chat_template_engine.dart',
    ]) {
      expect(
        _formatTables(File(path).readAsStringSync()),
        isEmpty,
        reason: path,
      );
    }
  });

  test('the table scan finds each kind of format table', () {
    expect(_formatTables('const Set<ChatFormat> lazy = {};'), isNotEmpty);
    expect(_formatTables('const generic = {ChatFormat.gemma};'), isNotEmpty);
    expect(
      _formatTables(
        'const supported = {ChatFormat.generic, ChatFormat.hermes};',
      ),
      isNotEmpty,
    );
    expect(
      _formatTables(
        'switch (format) { ChatFormat.hermes => true, _ => false }',
      ),
      isNotEmpty,
    );
    expect(
      _formatTables(
        'f == ChatFormat.gemma.index || f == ChatFormat.lfm2.index || '
        'f == ChatFormat.kimiK2.index;',
      ),
      isNotEmpty,
    );
    expect(
      _formatTables(
        'final isLlama3 = f == ChatFormat.llama3.index || '
        'f == ChatFormat.llama3BuiltinTools.index;',
      ),
      isEmpty,
    );
  });

  test('detection falls back to content-only', () {
    expect(detectChatFormat(null), ChatFormat.contentOnly);
    expect(detectChatFormat(''), ChatFormat.contentOnly);
    expect(detectChatFormat('{{ messages }}'), ChatFormat.contentOnly);
  });
}

/// Per-format tables in [source]: a `ChatFormat` set or collection literal,
/// a switch arm on a format, or one statement naming three or more formats.
List<String> _formatTables(String source) => [
  if (source.contains('Set<ChatFormat>')) 'Set<ChatFormat>',
  for (final match in RegExp(
    r'[\[{]\s*ChatFormat\.\w+\s*[,}\]]',
  ).allMatches(source))
    'literal: ${match[0]}',
  for (final match in RegExp(r'ChatFormat\.\w+\s*=>').allMatches(source))
    'switch arm: ${match[0]}',
  for (final statement in source.split(';'))
    if ({
          for (final match in RegExp(
            r'ChatFormat\.(?!values\b)(\w+)',
          ).allMatches(statement))
            match[1],
        }.length >=
        3)
      'statement: ${statement.trim()}',
];
