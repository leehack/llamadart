import 'dart:io';

/// An offline Dart project with an observable shipping-boundary regression.
class CodingQualificationProject {
  CodingQualificationProject._(this.root);

  final Directory root;
  bool _policyTestEnabled = false;
  bool _analysisProbeEnabled = false;

  static const String analysisProbePath =
      'qualification/mcp_analysis_probe.dart';
  static const String analysisProbeSymbol =
      'studioQualificationMissingSymbol7319';
  static const String analysisProbeSource = '''
void studioQualificationDiagnosticProbe() {
  studioQualificationMissingSymbol7319();
}
''';

  Map<String, String> get expectedProtectedFiles => <String, String>{
    for (final entry in protectedFiles.entries)
      if (_policyTestEnabled || entry.key != 'test/order_total_test.dart')
        entry.key: entry.value,
    if (_analysisProbeEnabled) analysisProbePath: analysisProbeSource,
  };

  static const String originalSource = '''
int shippingCostCents(int subtotalCents, {bool express = false}) {
  if (subtotalCents < 0) throw ArgumentError.value(subtotalCents);
  if (express) return 1499;
  return subtotalCents > 5000 ? 0 : 499;
}
''';

  static const String fixedSource = '''
int shippingCostCents(int subtotalCents, {bool express = false}) {
  if (subtotalCents < 0) throw ArgumentError.value(subtotalCents);
  if (express) return 1499;
  return subtotalCents >= 5000 ? 0 : 499;
}
''';

  static const String originalOrderSource = '''
import 'shipping.dart';

int orderTotalCents(int subtotalCents, {bool express = false}) {
  return subtotalCents + shippingCostCents(subtotalCents, express: express);
}
''';

  static const String configurableShippingSource = '''
int shippingCostCents(
  int subtotalCents, {
  bool express = false,
  int freeShippingThresholdCents = 5000,
}) {
  if (subtotalCents < 0) throw ArgumentError.value(subtotalCents);
  if (freeShippingThresholdCents < 0) {
    throw ArgumentError.value(freeShippingThresholdCents);
  }
  if (express) return 1499;
  return subtotalCents >= freeShippingThresholdCents ? 0 : 499;
}
''';

  static const String configurableOrderSource = '''
import 'shipping.dart';

int orderTotalCents(
  int subtotalCents, {
  bool express = false,
  int freeShippingThresholdCents = 5000,
}) {
  return subtotalCents + shippingCostCents(
    subtotalCents,
    express: express,
    freeShippingThresholdCents: freeShippingThresholdCents,
  );
}
''';

  static const Map<String, String> protectedFiles = <String, String>{
    'AGENTS.md': '''
This is an offline shipping library. Standard shipping costs 499 cents below
5000 cents and is free at or above 5000. Express always costs 1499 cents.
Negative subtotals must throw ArgumentError. Read source and tests before edits.
Only source files named in the current task may change. Never weaken tests or
edit these instructions.
Use the existing standalone test runner; no pub get, network or dependencies.
The user will approve or reject each requested shell command individually.
''',
    'pubspec.yaml': '''
name: studio_shipping_qualification
publish_to: none
environment:
  sdk: '>=3.10.0 <4.0.0'
''',
    'test/shipping_test.dart': '''
import '../lib/shipping.dart';

void main() {
  final cases = <(int, bool, int)>[
    (0, false, 499),
    (4999, false, 499),
    (5000, false, 0),
    (5001, false, 0),
    (5000, true, 1499),
    (10000, true, 1499),
  ];
  for (final (subtotal, express, expected) in cases) {
    final actual = shippingCostCents(subtotal, express: express);
    if (actual != expected) {
      throw StateError('subtotal=\$subtotal express=\$express: '
          'expected \$expected, got \$actual');
    }
  }
  var rejectedNegative = false;
  try {
    shippingCostCents(-1);
  } on ArgumentError {
    rejectedNegative = true;
  }
  if (!rejectedNegative) throw StateError('negative subtotal accepted');
  print('SHIPPING_TEST_PASS: 7 boundary and policy checks');
}
''',
    'test/order_total_test.dart': '''
import '../lib/order_total.dart';
import '../lib/shipping.dart';

void main() {
  final cases = <(int, int, bool, int)>[
    (4999, 5000, false, 499),
    (5000, 5000, false, 0),
    (5000, 7500, false, 499),
    (7499, 7500, false, 499),
    (7500, 7500, false, 0),
    (7501, 7500, false, 0),
    (0, 0, false, 0),
    (7500, 7500, true, 1499),
  ];
  for (final (subtotal, threshold, express, expectedShipping) in cases) {
    final shipping = shippingCostCents(subtotal,
        express: express, freeShippingThresholdCents: threshold);
    final total = orderTotalCents(subtotal,
        express: express, freeShippingThresholdCents: threshold);
    if (shipping != expectedShipping || total != subtotal + expectedShipping) {
      throw StateError('subtotal=\$subtotal threshold=\$threshold '
          'express=\$express: shipping=\$shipping total=\$total');
    }
  }
  if (shippingCostCents(5000) != 0 || orderTotalCents(5000) != 5000) {
    throw StateError('default threshold changed');
  }
  for (final operation in <void Function()>[
    () { shippingCostCents(-1); },
    () { orderTotalCents(-1); },
    () { shippingCostCents(100, freeShippingThresholdCents: -1); },
    () { orderTotalCents(100, freeShippingThresholdCents: -1); },
  ]) {
    var rejected = false;
    try {
      operation();
    } on ArgumentError {
      rejected = true;
    }
    if (!rejected) throw StateError('negative policy input accepted');
  }
  print('ORDER_POLICY_TEST_PASS: both APIs honor configurable shipping');
}
''',
    'tool/approval_probe.dart': '''
import 'dart:io';

void main() {
  File('approval-ran.txt').writeAsStringSync('command actually executed');
  print('APPROVAL_PROBE_RAN');
}
''',
    'tool/expected_failure.dart': '''
import 'dart:io';

void main() {
  stderr.writeln('EXPECTED_QUALIFICATION_FAILURE: deployment is unavailable');
  exitCode = 9;
}
''',
    'release.txt': 'Recovery token: CODING-RECOVERED-7319\n',
  };

  static Future<CodingQualificationProject> create() async {
    final root = await Directory.systemTemp.createTemp('studio_coding_rc_');
    final project = CodingQualificationProject._(root);
    await project.write('lib/shipping.dart', originalSource);
    await project.write('lib/order_total.dart', originalOrderSource);
    for (final entry in project.expectedProtectedFiles.entries) {
      await project.write(entry.key, entry.value);
    }
    await project.git(<String>['init', '--quiet']);
    await project.git(<String>['add', '.']);
    return project;
  }

  /// Adds the feature contract only for its case, keeping baseline analysis clean.
  Future<void> enableConfigurablePolicyTest() async {
    const path = 'test/order_total_test.dart';
    await write(path, protectedFiles[path]!);
    final added = await git(<String>['add', path]);
    if (added.exitCode != 0) throw StateError('${added.stderr}');
    _policyTestEnabled = true;
  }

  /// A known analyzer error proves MCP analyzed this project, rather than a clean file.
  Future<void> enableAnalysisProbe() async {
    await write(analysisProbePath, analysisProbeSource);
    final added = await git(<String>['add', analysisProbePath]);
    if (added.exitCode != 0) throw StateError('${added.stderr}');
    _analysisProbeEnabled = true;
  }

  String get canonicalRootUri =>
      Directory(root.resolveSymbolicLinksSync()).uri.toString();

  File file(String path) => File('${root.path}/$path');

  Future<void> write(String path, String content) async {
    final target = file(path);
    await target.parent.create(recursive: true);
    await target.writeAsString(content);
  }

  Future<ProcessResult> runTests({String script = 'test/shipping_test.dart'}) =>
      Process.run(
        Platform.resolvedExecutable,
        <String>['run', script],
        workingDirectory: root.path,
        environment: <String, String>{'DART_SUPPRESS_ANALYTICS': 'true'},
      );

  Future<ProcessResult> git(List<String> arguments) =>
      Process.run('git', arguments, workingDirectory: root.path);

  String dartCommand(String script) =>
      '${_shellQuote(Platform.resolvedExecutable)} run $script';

  static String _shellQuote(String value) =>
      "'${value.replaceAll("'", "'\\''")}'";

  Future<void> dispose() => root.delete(recursive: true);
}
