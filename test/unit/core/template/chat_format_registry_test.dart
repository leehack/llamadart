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

  test('detection falls back to content-only', () {
    expect(detectChatFormat(null), ChatFormat.contentOnly);
    expect(detectChatFormat(''), ChatFormat.contentOnly);
    expect(detectChatFormat('{{ messages }}'), ChatFormat.contentOnly);
  });
}
