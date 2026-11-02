@TestOn('vm')
library;

import 'dart:io';
import 'dart:mirrors';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/core/template/chat_format.dart';
import 'package:llamadart/src/core/template/chat_format_registry.dart';
import 'package:test/test.dart';

import '../../../support/raw_tool_schema_fixture.dart';

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
        'const byFormat = {ChatFormat.gemma: 1, ChatFormat.lfm2: 2};',
      ),
      isNotEmpty,
    );
    expect(
      _formatTables('switch (format) { case ChatFormat.hermes: return true; }'),
      isNotEmpty,
    );
    expect(
      _formatTables(
        'final chosen = pegOnly ? ChatFormat.hermes : ChatFormat.generic;',
      ),
      isEmpty,
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

  test('generic reads an incomplete call outside a forced-open thinking '
      'block only', () {
    final leavesIncomplete = chatFormatRegistration(
      ChatFormat.generic,
    ).traits.leavesIncompleteToolCall!;
    const call = '{"tool_calls": [{"name": "f"';
    const parsed = ChatParseResult();

    expect(leavesIncomplete(parsed, call, thinkingForcedOpen: false), isTrue);
    expect(leavesIncomplete(parsed, call, thinkingForcedOpen: true), isFalse);
    expect(
      leavesIncomplete(parsed, 'plan</think>$call', thinkingForcedOpen: true),
      isTrue,
    );
  });

  test('only Hermes renders tool-result content', () {
    expect(
      [
        for (final registration in chatFormatRegistrations)
          if (registration.traits.rendersToolResultContent) registration.format,
      ],
      [ChatFormat.hermes],
    );
  });

  test('an incomplete-call callback does not grant schema admission', () {
    final originalCheck = chatFormatRegistration(
      ChatFormat.hermes,
    ).traits.leavesIncompleteToolCall!;
    var checks = 0;
    bool check(
      ChatParseResult result,
      String output, {
      required bool thinkingForcedOpen,
    }) {
      checks++;
      return originalCheck(
        result,
        output,
        thinkingForcedOpen: thinkingForcedOpen,
      );
    }

    _withHermesTraits(
      ChatFormatTraits(
        qualifiesJsonSchemaTools: false,
        leavesIncompleteToolCall: check,
      ),
      () {
        expect(_renderSchemaTool, throwsA(isA<LlamaUnsupportedException>()));
        expect(checks, 0);
        expect(
          _parseIncompleteSchemaCall,
          throwsA(isA<LlamaInferenceException>()),
        );
        expect(checks, 1);
      },
    );
  });

  test('schema admission does not install an incomplete-call callback', () {
    _withHermesTraits(
      const ChatFormatTraits(qualifiesJsonSchemaTools: true),
      () {
        final rendered = _renderSchemaTool();
        expect(rendered.format, ChatFormat.hermes.index);
        expect(rendered.grammar, isNotEmpty);
        final parsed = _parseIncompleteSchemaCall();
        expect(parsed.toolCalls, isEmpty);
        expect(parsed.content, contains('<tool_call>'));
      },
    );
  });

  test('detection falls back to content-only', () {
    expect(detectChatFormat(null), ChatFormat.contentOnly);
    expect(detectChatFormat(''), ChatFormat.contentOnly);
    expect(detectChatFormat('{{ messages }}'), ChatFormat.contentOnly);
  });
}

LlamaChatTemplateResult _renderSchemaTool() => ChatTemplateEngine.render(
  templateSource: '<tool_call>',
  messages: [
    LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'Inspect'),
  ],
  metadata: const {},
  tools: [rawSchemaTool()],
);

ChatParseResult _parseIncompleteSchemaCall() => ChatTemplateEngine.parse(
  ChatFormat.hermes.index,
  '<tool_call>{"name":"inspect"',
  tools: [rawSchemaTool()],
);

/// Exercise independent traits through production consumers without a runtime
/// registration API. Restore the private registry even when an assertion fails.
void _withHermesTraits(ChatFormatTraits traits, void Function() body) {
  final library = reflectClass(ChatFormatTraits).owner as LibraryMirror;
  final registrations =
      library
              .getField(
                MirrorSystem.getSymbol('_registrationsByFormat', library),
              )
              .reflectee
          as Map<ChatFormat, ChatFormatRegistration>;
  final original = registrations[ChatFormat.hermes]!;
  registrations[ChatFormat.hermes] = ChatFormatRegistration(
    original.format,
    original.createHandler,
    detect: original.detect,
    traits: traits,
  );
  try {
    body();
  } finally {
    registrations[ChatFormat.hermes] = original;
  }
}

/// Per-format tables in [source]: a `ChatFormat` set, collection or map
/// literal, a switch or `case` arm on a format, or one statement naming three or more formats.
List<String> _formatTables(String source) => [
  if (source.contains('Set<ChatFormat>')) 'Set<ChatFormat>',
  for (final match in RegExp(
    r'[\[{]\s*ChatFormat\.\w+\s*[,}\]]',
  ).allMatches(source))
    'literal: ${match[0]}',
  for (final match in RegExp(r'ChatFormat\.\w+\s*=>').allMatches(source))
    'switch arm: ${match[0]}',
  for (final match in RegExp(
    r'[\[{,]\s*ChatFormat\.\w+\s*:',
  ).allMatches(source))
    'map key: ${match[0]}',
  for (final match in RegExp(
    r'\bcase\s+ChatFormat\.\w+\s*:',
  ).allMatches(source))
    'case arm: ${match[0]}',
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
