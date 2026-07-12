import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart_tui_coding_agent/src/workspace_tools.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('WorkspaceTools', () {
    late Directory workspace;
    late WorkspaceTools tools;

    setUp(() async {
      workspace = await Directory.systemTemp.createTemp('workspace_tools_');
      tools = WorkspaceTools(workspaceRoot: workspace.path);
    });

    tearDown(() async {
      tools.cancelActiveTool();
      if (workspace.existsSync()) {
        await workspace.delete(recursive: true);
      }
    });

    test('exposes exactly the four Pi-style tools', () {
      final definitions = tools.buildToolDefinitions();

      expect(definitions.map((definition) => definition.name), <String>[
        'read',
        'write',
        'edit',
        'bash',
      ]);
      expect(
        definitions.singleWhere((tool) => tool.name == 'bash').description,
        contains('NOT SANDBOXED'),
      );
      expect(
        definitions
            .singleWhere((tool) => tool.name == 'read')
            .parameters
            .map((parameter) => parameter.name),
        <String>['path', 'offset', 'limit'],
      );
    });

    test(
      'read returns a bounded line window with continuation metadata',
      () async {
        await File(
          p.join(workspace.path, 'notes.txt'),
        ).writeAsString('one\ntwo\nthree\nfour\n');

        final result = await tools.read(
          const ToolParams(<String, dynamic>{
            'path': 'notes.txt',
            'offset': 2,
            'limit': 2,
          }),
        );

        final map = result as Map<String, Object?>;
        expect(map['ok'], isTrue);
        expect(map['path'], 'notes.txt');
        expect(map['content'], 'two\nthree');
        expect(map['line_count'], 2);
        expect(map['total_lines'], 4);
        expect(map['next_offset'], 4);
        expect(map['truncated'], isTrue);
      },
    );

    test(
      'read trims surrounding whitespace from model path arguments',
      () async {
        await File(
          p.join(workspace.path, 'notes.txt'),
        ).writeAsString('one\ntwo\n');

        final result = await tools.read(
          const ToolParams(<String, dynamic>{'path': ' \nnotes.txt\t '}),
        );

        final map = result as Map<String, Object?>;
        expect(map['path'], 'notes.txt');
        expect(map['content'], 'one\ntwo');
      },
    );

    test('read handles empty and out-of-range windows', () async {
      await File(p.join(workspace.path, 'empty.txt')).writeAsString('');
      await File(p.join(workspace.path, 'short.txt')).writeAsString('one\n');

      final empty = await tools.read(
        const ToolParams(<String, dynamic>{'path': 'empty.txt'}),
      );
      final pastEnd = await tools.read(
        const ToolParams(<String, dynamic>{'path': 'short.txt', 'offset': 20}),
      );

      expect((empty as Map)['content'], '');
      expect(empty['total_lines'], 0);
      expect((pastEnd as Map)['content'], '');
      expect(pastEnd['truncated'], isFalse);
    });

    test('read bounds UTF-8 output without splitting a code point', () async {
      final content = List<String>.filled(5000, '😀').join();
      await File(p.join(workspace.path, 'unicode.txt')).writeAsString(content);

      final result = await tools.read(
        const ToolParams(<String, dynamic>{'path': 'unicode.txt'}),
      );

      final map = result as Map<String, Object?>;
      final returned = map['content']! as String;
      expect(map['content_bytes'], lessThanOrEqualTo(12000));
      expect(utf8.encode(returned).length, map['content_bytes']);
      expect(returned.runes.every((rune) => rune == 0x1f600), isTrue);
      expect(map['truncated'], isTrue);
    });

    test(
      'read validates ranges, UTF-8, file type, and workspace scope',
      () async {
        await File(
          p.join(workspace.path, 'invalid.txt'),
        ).writeAsBytes(<int>[0xff]);
        await Directory(p.join(workspace.path, 'folder')).create();

        for (final params in <ToolParams>[
          const ToolParams(<String, dynamic>{'path': 'invalid.txt'}),
          const ToolParams(<String, dynamic>{'path': 'folder'}),
          const ToolParams(<String, dynamic>{'path': '../outside.txt'}),
          const ToolParams(<String, dynamic>{
            'path': 'invalid.txt',
            'offset': 0,
          }),
          const ToolParams(<String, dynamic>{
            'path': 'invalid.txt',
            'limit': 801,
          }),
        ]) {
          await expectLater(tools.read(params), throwsA(anything));
        }
      },
    );

    test(
      'write creates parents and overwrites complete UTF-8 content',
      () async {
        final first = await tools.write(
          const ToolParams(<String, dynamic>{
            'path': 'nested/note.txt',
            'content': 'héllo',
          }),
        );
        await tools.write(
          const ToolParams(<String, dynamic>{
            'path': 'nested/note.txt',
            'content': 'replacement',
          }),
        );

        expect((first as Map)['path'], p.join('nested', 'note.txt'));
        expect(first['bytes_written'], utf8.encode('héllo').length);
        expect(
          await File(
            p.join(workspace.path, 'nested', 'note.txt'),
          ).readAsString(),
          'replacement',
        );
      },
    );

    test('write rejects directory and outside targets', () async {
      await Directory(p.join(workspace.path, 'folder')).create();

      await expectLater(
        tools.write(
          const ToolParams(<String, dynamic>{
            'path': 'folder',
            'content': 'no',
          }),
        ),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        tools.write(
          const ToolParams(<String, dynamic>{
            'path': '../outside.txt',
            'content': 'no',
          }),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('edit replaces exactly one literal occurrence', () async {
      final file = File(p.join(workspace.path, 'value.txt'));
      await file.writeAsString('before old after');

      final result = await tools.edit(
        const ToolParams(<String, dynamic>{
          'path': 'value.txt',
          'old_text': 'old',
          'new_text': 'new',
        }),
      );

      expect((result as Map)['replacements'], 1);
      expect(await file.readAsString(), 'before new after');
    });

    test(
      'edit leaves the file unchanged for zero, multiple, or empty matches',
      () async {
        final file = File(p.join(workspace.path, 'value.txt'));
        await file.writeAsString('old and old');

        for (final oldText in <String>['missing', 'old', '']) {
          await expectLater(
            tools.edit(
              ToolParams(<String, dynamic>{
                'path': 'value.txt',
                'old_text': oldText,
                'new_text': 'new',
              }),
            ),
            throwsA(anything),
          );
          expect(await file.readAsString(), 'old and old');
        }
      },
    );

    test(
      'file tools allow internal symlinks but reject external symlink escapes',
      () async {
        final actual = Directory(p.join(workspace.path, 'actual'));
        await actual.create();
        final target = await File(
          p.join(actual.path, 'note.txt'),
        ).writeAsString('old');
        await Link(p.join(workspace.path, 'alias')).create(actual.path);
        final outside = await Directory.systemTemp.createTemp('tools_outside_');
        addTearDown(() async => outside.delete(recursive: true));
        final outsideFile = await File(
          p.join(outside.path, 'outside.txt'),
        ).writeAsString('outside');
        await Link(
          p.join(workspace.path, 'outside-link'),
        ).create(outsideFile.path);

        final read = await tools.read(
          const ToolParams(<String, dynamic>{'path': 'alias/note.txt'}),
        );
        await tools.write(
          const ToolParams(<String, dynamic>{
            'path': 'alias/note.txt',
            'content': 'inside',
          }),
        );

        expect((read as Map)['path'], p.join('actual', 'note.txt'));
        expect(await target.readAsString(), 'inside');
        await expectLater(
          tools.write(
            const ToolParams(<String, dynamic>{
              'path': 'outside-link',
              'content': 'escaped',
            }),
          ),
          throwsA(isA<ArgumentError>()),
        );
        expect(await outsideFile.readAsString(), 'outside');
      },
      skip: Platform.isWindows
          ? 'Creating symbolic links requires elevated Windows privileges.'
          : false,
    );

    test(
      'bash runs shell syntax from the workspace and discloses isolation',
      () async {
        final command = Platform.isWindows
            ? 'echo alpha>shell.txt && echo beta'
            : "printf alpha > shell.txt && printf beta";

        final result = await tools.bash(
          ToolParams(<String, dynamic>{'command': command}),
        );

        final map = result as Map<String, Object?>;
        expect(map['ok'], isTrue);
        expect(map['executed'], isTrue);
        expect(map['sandboxed'], isFalse);
        expect((map['stdout']! as String).trim(), 'beta');
        expect(
          (await File(
            p.join(workspace.path, 'shell.txt'),
          ).readAsString()).trim(),
          'alpha',
        );
      },
    );

    test(
      'bash validates timeout and bounds combined stdout and stderr',
      () async {
        await File(p.join(workspace.path, 'noisy.dart')).writeAsString(
          "import 'dart:io';\n"
          "void main() {\n"
          "  stdout.write(List<String>.filled(9000, 'o').join());\n"
          "  stderr.write(List<String>.filled(9000, 'e').join());\n"
          "}\n",
        );
        final command =
            '${_shellQuote(Platform.resolvedExecutable)} noisy.dart';

        final result = await tools.bash(
          ToolParams(<String, dynamic>{'command': command}),
        );

        final map = result as Map<String, Object?>;
        expect(map['ok'], isTrue);
        expect(map['output_truncated'], isTrue);
        expect(
          (map['stdout']! as String).length + (map['stderr']! as String).length,
          lessThanOrEqualTo(12000),
        );
        await expectLater(
          tools.bash(
            const ToolParams(<String, dynamic>{
              'command': 'echo x',
              'timeout': 0,
            }),
          ),
          throwsA(isA<ArgumentError>()),
        );
        await expectLater(
          tools.bash(
            const ToolParams(<String, dynamic>{
              'command': 'echo x',
              'timeout': 121,
            }),
          ),
          throwsA(isA<ArgumentError>()),
        );
      },
    );

    test('bash times out and can be cancelled', () async {
      await File(p.join(workspace.path, 'sleep.dart')).writeAsString(
        "import 'dart:async';\n"
        'Future<void> main() async {\n'
        '  await Future<void>.delayed(const Duration(seconds: 30));\n'
        '}\n',
      );
      final command = '${_shellQuote(Platform.resolvedExecutable)} sleep.dart';

      final timedOut = await tools.bash(
        ToolParams(<String, dynamic>{'command': command, 'timeout': 1}),
      );
      expect((timedOut as Map)['timed_out'], isTrue);
      expect(timedOut['ok'], isFalse);

      final running = tools.bash(
        ToolParams(<String, dynamic>{'command': command, 'timeout': 120}),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(tools.cancelActiveTool(), isTrue);
      final cancelled = await running as Map<String, Object?>;
      expect(cancelled['cancelled'], isTrue);
      expect(cancelled['ok'], isFalse);
      expect(tools.cancelActiveTool(), isFalse);
    });

    test('rejects a second tool while bash is active', () async {
      await File(p.join(workspace.path, 'sleep.dart')).writeAsString(
        "import 'dart:async';\n"
        'Future<void> main() => Future<void>.delayed('
        'const Duration(seconds: 30));\n',
      );
      await File(p.join(workspace.path, 'note.txt')).writeAsString('note');
      final command = '${_shellQuote(Platform.resolvedExecutable)} sleep.dart';
      final running = tools.bash(
        ToolParams(<String, dynamic>{'command': command, 'timeout': 120}),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));

      await expectLater(
        tools.read(const ToolParams(<String, dynamic>{'path': 'note.txt'})),
        throwsA(isA<StateError>()),
      );
      tools.cancelActiveTool();
      await running;
    });
  });
}

String _shellQuote(String value) {
  if (Platform.isWindows) {
    return '"${value.replaceAll('"', '""')}"';
  }
  return "'${value.replaceAll("'", "'\"'\"'")}'";
}
