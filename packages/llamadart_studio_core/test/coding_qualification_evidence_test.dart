import 'dart:convert';
import 'dart:io';

import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:test/test.dart';

import 'support/coding_qualification_evidence.dart';
import 'support/coding_qualification_project.dart';

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('coding_evidence_guard_');
    addTearDown(() => root.delete(recursive: true));
  });

  const targets = <String>['lib/shipping.dart', 'lib/order_total.dart'];
  const probe = CodingQualificationProject.analysisProbePath;
  const symbol = CodingQualificationProject.analysisProbeSymbol;
  const analyzeName = 'mcp_dart_analyze_files';

  StudioToolInvocation analysis({
    List<String> paths = const <String>[...targets, probe],
    String? rootUri,
    String? text,
    bool emptyResult = false,
  }) => StudioToolInvocation(
    id: 'analysis-evidence',
    name: analyzeName,
    argumentsJson: jsonEncode(<String, Object?>{
      'roots': <Map<String, Object?>>[
        <String, Object?>{
          'root': rootUri ?? root.uri.toString(),
          'paths': paths,
        },
      ],
    }),
    resultJson: jsonEncode(<String, Object?>{
      if (!emptyResult)
        'text':
            text ??
            '# Diagnostics for root ${root.uri}\n'
                'error • $probe:2:3 • The function \'$symbol\' isn\'t defined. '
                '• undefined_function',
    }),
  );

  List<StudioToolInvocation> verify(Iterable<StudioToolInvocation> calls) =>
      requireOwnedAnalysisEvidence(
        calls: calls,
        toolName: analyzeName,
        ownedRoot: root.path,
        changedPaths: targets,
        probePath: probe,
        probeSymbol: symbol,
      );

  test('accepts owned target coverage with the protected diagnostic', () {
    final call = analysis();
    expect(verify(<StudioToolInvocation>[call]), <StudioToolInvocation>[call]);
  });

  test('rejects empty, unrelated, and falsely clean analysis evidence', () {
    final invalid = <StudioToolInvocation>[
      analysis(emptyResult: true),
      analysis(text: ''),
      analysis(text: 'No errors'),
      analysis(paths: const <String>['lib/unrelated.dart'], text: 'No errors'),
      analysis(paths: const <String>['lib/shipping.dart', probe]),
      analysis(paths: targets),
      analysis(rootUri: root.parent.uri.toString()),
      analysis(
        text:
            '# Diagnostics for root ${root.parent.uri}\n'
            'error • $probe:2:3 • The function \'$symbol\' isn\'t defined. '
            '• undefined_function',
      ),
      analysis(text: 'Request accepted'),
    ];
    for (final call in invalid) {
      expect(
        () => verify(<StudioToolInvocation>[call]),
        throwsStateError,
        reason: '${call.argumentsJson} => ${call.resultJson}',
      );
    }
  });

  test(
    'a real protected probe emits the diagnostic the verifier requires',
    () async {
      final project = await CodingQualificationProject.create();
      addTearDown(project.dispose);
      await project.enableAnalysisProbe();
      final result = await Process.run(Platform.resolvedExecutable, <String>[
        'analyze',
        '--format',
        'machine',
        probe,
      ], workingDirectory: project.root.path);
      expect(result.exitCode, isNot(0));
      expect('${result.stdout}', contains('UNDEFINED_FUNCTION'));
      expect('${result.stdout}', contains(symbol));
      expect(
        await project.file(probe).readAsString(),
        CodingQualificationProject.analysisProbeSource,
      );
    },
  );

  for (final cancelled in <bool>[false, true]) {
    test('denied probe evidence requires exact approval and bash command '
        '(cancelled=$cancelled)', () {
      const command = "'/controlled/dart' run tool/approval_probe.dart";
      Map<String, Object?> decision(String value) => <String, Object?>{
        'command': value,
        'workspaceRoot': root.path,
        'approved': false,
        'cancelled': cancelled,
      };
      StudioToolInvocation call(String value) => StudioToolInvocation(
        id: 'probe',
        name: 'bash',
        argumentsJson: jsonEncode(<String, String>{'command': value}),
      );
      void verifyApproval(
        List<Map<String, Object?>> decisions,
        List<StudioToolInvocation> calls,
      ) => requireExactProbeApproval(
        decisions: decisions,
        calls: calls,
        ownedRoot: root.path,
        expectedCommand: command,
        cancelled: cancelled,
      );

      verifyApproval(
        <Map<String, Object?>>[decision(command)],
        <StudioToolInvocation>[call(command)],
      );
      expect(
        () => verifyApproval(
          <Map<String, Object?>>[decision('true')],
          <StudioToolInvocation>[call('true')],
        ),
        throwsStateError,
      );
      expect(
        () => verifyApproval(
          <Map<String, Object?>>[decision('true')],
          <StudioToolInvocation>[call(command)],
        ),
        throwsStateError,
      );
      expect(
        () => verifyApproval(
          <Map<String, Object?>>[decision(command)],
          <StudioToolInvocation>[call('true')],
        ),
        throwsStateError,
      );
      expect(
        () => verifyApproval(<Map<String, Object?>>[], <StudioToolInvocation>[
          call(command),
        ]),
        throwsStateError,
      );
    });
  }
}
