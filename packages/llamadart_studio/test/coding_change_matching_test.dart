@TestOn('vm')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart_studio/llamadart_studio.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:path/path.dart' as p;

void main() {
  final windowsPath = p.Context(style: p.Style.windows);

  CodingFileChange makeChange(String relativePath) => CodingFileChange(
    id: 'chg_1',
    relativePath: relativePath,
    kind: CodingChangeKind.modified,
    beforePreview: 'old',
    afterPreview: 'new',
    unifiedDiff: '-old\n+new',
    timestamp: DateTime.utc(2026, 1, 1),
  );

  test(
    'matches nested Windows-style relativePath against POSIX tool call path',
    () {
      final winRelativePath = windowsPath.join('src', 'nested', 'main.dart');
      expect(winRelativePath, r'src\nested\main.dart');

      final change = makeChange(winRelativePath);
      const call = StudioToolInvocation(
        id: 'call_1',
        name: 'write',
        argumentsJson: '{"path":"src/nested/main.dart","content":"new"}',
      );

      final matched = matchingCodingChangeForCall(call, [change]);
      expect(matched, isNotNull);
      expect(matched!.id, 'chg_1');
    },
  );

  test(
    'matches nested Windows-style relativePath against ./ prefixed edit call',
    () {
      final change = makeChange(windowsPath.join('src', 'nested', 'main.dart'));
      const call = StudioToolInvocation(
        id: 'call_2',
        name: 'edit',
        argumentsJson: '{"path":"./src/nested/main.dart"}',
      );

      expect(matchingCodingChangeForCall(call, [change])?.id, 'chg_1');
    },
  );

  test('returns null for non-matching path or non-edit tool', () {
    final change = makeChange(windowsPath.join('src', 'nested', 'main.dart'));
    const otherFileCall = StudioToolInvocation(
      id: 'call_3',
      name: 'write',
      argumentsJson: '{"path":"src/other/main.dart"}',
    );
    const readCall = StudioToolInvocation(
      id: 'call_4',
      name: 'read',
      argumentsJson: '{"path":"src/nested/main.dart"}',
    );

    expect(matchingCodingChangeForCall(otherFileCall, [change]), isNull);
    expect(matchingCodingChangeForCall(readCall, [change]), isNull);
  });
}
