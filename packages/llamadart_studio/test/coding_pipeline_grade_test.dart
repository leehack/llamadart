import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../integration_test/support/coding_pipeline_grade.dart';

const _expectedPath = 'nested/bonjour.txt';
const _expectedContent = 'Bonjour Montréal — café ☕ 안녕하세요 🌲';
const _oldContent = 'Bonjour Montréal — café ☕\n안녕하세요 🌲\n';

class _Emission {
  _Emission(this.name, this.path, this.content);
  final String name;
  final String path;
  final String content;

  Map<String, List<int>> get disk => {path: utf8.encode(content)};

  List<GradedToolCall> calls() => [
    GradedToolCall(
      name: 'write',
      arguments: {'path': path, 'content': content},
      result: {'status': 'created', 'path': path},
      succeeded: true,
    ),
    GradedToolCall(
      name: 'read',
      arguments: {'path': path},
      result: {
        'path': path,
        'content': numberedView(content),
        'truncated': false,
      },
      succeeded: true,
    ),
  ];
}

final _emissions = <_Emission>[
  _Emission(
    'android',
    'data/user/0/app/coding_workspaces/ws/bonjour.txt',
    'Bonjour Montréal — café ☕\n안녕하세요 🌲',
  ),
  _Emission(
    'ios',
    'nested/bonjour.txt',
    'Bonjour Montréal — café ☕\\n</parameter>\n</function>\n</tool_call>\n'
        '<tool_call>\n<function=read>\n<parameter=path>\nnested/bonjour.txt',
  ),
  _Emission(
    'pixel8a_rerun',
    'nested/bonjour.txt',
    'Bonjour Montréal — café ☕\n안녕하세요 🌲',
  ),
  _Emission(
    'macos_cpu',
    'bonjour.txt',
    '"Bonjour Montréal — café ☕\\n안녕하세요 🌲\\n"',
  ),
];

bool _oldStrictRule(_Emission e) {
  final write = e.calls().first;
  return write.arguments['path'] == _expectedPath &&
      write.arguments['content'] == _oldContent &&
      write.result!['path'] == _expectedPath &&
      e.disk[_expectedPath] != null &&
      utf8.decode(e.disk[_expectedPath]!) == _oldContent;
}

void main() {
  group('recorded model emissions', () {
    for (final emission in _emissions) {
      test('${emission.name} fails old rule, passes pipeline, no fidelity', () {
        expect(_oldStrictRule(emission), isFalse);
        final grade = gradeWriteAndRead(
          calls: emission.calls(),
          expectedPath: _expectedPath,
          expectedContent: _expectedContent,
          readDisk: (path) => emission.disk[path],
        );
        expect(grade.failures, isEmpty);
        expect(grade.pipelinePass, isTrue);
        expect(grade.fidelity, isFalse);
      });
    }

    test('exact emission passes pipeline and fidelity', () {
      final exact = _Emission('exact', _expectedPath, _expectedContent);
      final grade = gradeWriteAndRead(
        calls: exact.calls(),
        expectedPath: _expectedPath,
        expectedContent: _expectedContent,
        readDisk: (path) => exact.disk[path],
      );
      expect(grade.pipelinePass, isTrue);
      expect(grade.pathExact, isTrue);
      expect(grade.contentExact, isTrue);
      expect(grade.fidelity, isTrue);
    });
  });

  group('pipeline invariants', () {
    test('disk bytes one byte off the dispatched content fail', () {
      final emission = _Emission('exact', _expectedPath, _expectedContent);
      final bytes = utf8.encode(_expectedContent)..[0] ^= 1;
      final grade = gradeWriteAndRead(
        calls: emission.calls(),
        expectedPath: _expectedPath,
        expectedContent: _expectedContent,
        readDisk: (path) => bytes,
      );
      expect(grade.pipelinePass, isFalse);
      expect(grade.failures.join(), contains('disk bytes differ'));
    });

    test('missing disk file, missing write and missing read fail', () {
      final emission = _Emission('exact', _expectedPath, _expectedContent);
      expect(
        gradeWriteAndRead(
          calls: emission.calls(),
          expectedPath: _expectedPath,
          expectedContent: _expectedContent,
          readDisk: (path) => null,
        ).pipelinePass,
        isFalse,
      );
      expect(
        gradeWriteAndRead(
          calls: const [],
          expectedPath: _expectedPath,
          expectedContent: _expectedContent,
          readDisk: (path) => null,
        ).failures,
        ['no successful write'],
      );
      expect(
        gradeWriteAndRead(
          calls: [emission.calls().first],
          expectedPath: _expectedPath,
          expectedContent: _expectedContent,
          readDisk: (path) => emission.disk[path],
        ).failures,
        ['no successful read after the mutation'],
      );
    });

    test('a read that differs from the numbered disk view fails', () {
      final emission = _Emission('exact', _expectedPath, _expectedContent);
      final calls = emission.calls();
      calls[1] = GradedToolCall(
        name: 'read',
        arguments: const {'path': _expectedPath},
        result: {
          'path': _expectedPath,
          'content': '1: other',
          'truncated': false,
        },
        succeeded: true,
      );
      final grade = gradeWriteAndRead(
        calls: calls,
        expectedPath: _expectedPath,
        expectedContent: _expectedContent,
        readDisk: (path) => emission.disk[path],
      );
      expect(grade.failures.join(), contains('numbered view'));
    });

    test('only the last successful write counts', () {
      final emission = _Emission('exact', _expectedPath, _expectedContent);
      final failedWrite = GradedToolCall(
        name: 'write',
        arguments: const {'path': 'x', 'content': 'junk'},
        result: const {'error': 'denied'},
        succeeded: false,
      );
      final grade = gradeWriteAndRead(
        calls: [emission.calls().first, emission.calls().last, failedWrite],
        expectedPath: _expectedPath,
        expectedContent: _expectedContent,
        readDisk: (path) => emission.disk[path],
      );
      expect(grade.pipelinePass, isTrue);
    });
  });

  group('edit grading', () {
    final pre = utf8.encode(_expectedContent);
    const edited = 'Salut Québec — café ☕ 안녕하세요 🌲';

    List<GradedToolCall> editCalls(String content) => [
      GradedToolCall(
        name: 'edit',
        arguments: const {
          'path': _expectedPath,
          'findText': 'Bonjour Montréal',
          'replaceText': 'Salut Québec',
        },
        result: const {'status': 'patched', 'path': _expectedPath},
        succeeded: true,
      ),
      GradedToolCall(
        name: 'read',
        arguments: const {'path': _expectedPath},
        result: {
          'path': _expectedPath,
          'content': numberedView(content),
          'truncated': false,
        },
        succeeded: true,
      ),
    ];

    CodingPipelineGrade grade(List<int> disk, List<GradedToolCall> calls) =>
        gradeEditAndRead(
          calls: calls,
          expectedPath: _expectedPath,
          expectedFindText: 'Bonjour Montréal',
          expectedReplaceText: 'Salut Québec',
          preEditBytes: pre,
          readDisk: (path) => disk,
        );

    test('disk equal to pre-edit bytes with edit applied passes', () {
      final result = grade(utf8.encode(edited), editCalls(edited));
      expect(result.pipelinePass, isTrue);
      expect(result.fidelity, isTrue);
    });

    test('disk that differs from the applied edit fails', () {
      const wrong = 'Salut Québec — café ☕ 안녕하세요 🌳';
      final result = grade(utf8.encode(wrong), editCalls(wrong));
      expect(result.pipelinePass, isFalse);
      expect(result.failures.join(), contains('edit applied'));
    });

    test('no later read fails', () {
      final result = grade(utf8.encode(edited), [editCalls(edited).first]);
      expect(result.failures, ['no successful read after the mutation']);
    });
  });
}
