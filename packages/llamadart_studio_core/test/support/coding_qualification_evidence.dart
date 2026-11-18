import 'dart:convert';
import 'dart:io';

import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:path/path.dart' as p;

/// Requires analysis of owned targets and an observable diagnostic in that root.
List<StudioToolInvocation> requireOwnedAnalysisEvidence({
  required Iterable<StudioToolInvocation> calls,
  required String toolName,
  required String ownedRoot,
  required List<String> changedPaths,
  required String probePath,
  required String probeSymbol,
}) {
  final canonicalRoot = Directory(ownedRoot).resolveSymbolicLinksSync();
  final covered = <String>{};
  final accepted = <StudioToolInvocation>[];
  var observedProbe = false;
  for (final call in calls.where((call) => call.name == toolName)) {
    if (call.isError || call.isRunning || call.resultJson == null) continue;
    final result = jsonDecode(call.resultJson!) as Map<String, dynamic>;
    if (result['isError'] == true) continue;
    final text = result['text'];
    if (text is! String || text.trim().isEmpty) continue;
    if (text.trim() != 'No errors' &&
        !(text.contains('# Diagnostics for root ') &&
            RegExp(r'(error|warning|info) • .+:\d+:\d+ • ').hasMatch(text))) {
      continue;
    }
    final args = jsonDecode(call.argumentsJson) as Map<String, dynamic>;
    if (args['applyFixes'] == true) {
      throw StateError('Review analysis must not apply fixes.');
    }
    final roots = args['roots'];
    if (roots is! List || roots.isEmpty) continue;
    final requestedPaths = <String>[];
    var ownsEveryRoot = true;
    for (final entry in roots) {
      if (entry is! Map || entry['root'] is! String) {
        ownsEveryRoot = false;
        break;
      }
      final uri = Uri.tryParse(entry['root'] as String);
      if (uri == null || uri.scheme != 'file') {
        ownsEveryRoot = false;
        break;
      }
      final directory = Directory.fromUri(uri);
      if (!directory.existsSync() ||
          !p.equals(directory.resolveSymbolicLinksSync(), canonicalRoot)) {
        ownsEveryRoot = false;
        break;
      }
      final paths = entry['paths'];
      if (paths == null || paths is List && paths.isEmpty) {
        requestedPaths.add(canonicalRoot);
      } else if (paths is List && paths.every((path) => path is String)) {
        for (final path in paths.cast<String>()) {
          final uri = Uri.tryParse(path);
          final absolute = uri?.scheme == 'file'
              ? p.normalize(uri!.toFilePath())
              : p.normalize(p.join(canonicalRoot, path));
          if (!p.equals(absolute, canonicalRoot) &&
              !p.isWithin(canonicalRoot, absolute)) {
            ownsEveryRoot = false;
            break;
          }
          requestedPaths.add(absolute);
        }
      } else {
        ownsEveryRoot = false;
      }
    }
    if (!ownsEveryRoot) continue;
    for (final path in <String>[...changedPaths, probePath]) {
      final absolute = p.join(canonicalRoot, path);
      if (requestedPaths.any(
        (requested) =>
            p.equals(requested, absolute) || p.isWithin(requested, absolute),
      )) {
        covered.add(path);
      }
    }
    final probeRequested = requestedPaths.any((requested) {
      final absolute = p.join(canonicalRoot, probePath);
      return p.equals(requested, absolute) || p.isWithin(requested, absolute);
    });
    if (probeRequested &&
        _hasOwnedDiagnosticRoot(text, canonicalRoot) &&
        text.contains('$probePath:') &&
        text.contains(probeSymbol) &&
        text.contains('undefined_function')) {
      observedProbe = true;
    }
    accepted.add(call);
  }
  final missing = <String>[
    ...changedPaths,
    probePath,
  ].where((path) => !covered.contains(path));
  if (missing.isNotEmpty || !observedProbe) {
    throw StateError(
      'Owned analysis is unproven: missing paths ${missing.toList()}, '
      'observed protected diagnostic=$observedProbe.',
    );
  }
  return accepted;
}

bool _hasOwnedDiagnosticRoot(String text, String canonicalRoot) {
  final headers = RegExp(
    r'^# Diagnostics for root (\S+)',
    multiLine: true,
  ).allMatches(text);
  return headers.any((header) {
    final uri = Uri.tryParse(header.group(1)!);
    if (uri?.scheme != 'file') return false;
    final root = Directory.fromUri(uri!);
    return root.existsSync() &&
        p.equals(root.resolveSymbolicLinksSync(), canonicalRoot);
  });
}

/// Connects a denied/cancelled approval to the exact marker-producing tool call.
void requireExactProbeApproval({
  required List<Map<String, Object?>> decisions,
  required Iterable<StudioToolInvocation> calls,
  required String ownedRoot,
  required String expectedCommand,
  required bool cancelled,
}) {
  if (decisions.length != 1) {
    throw StateError('Exactly one probe approval must be observed.');
  }
  final decision = decisions.single;
  if (decision['command'] != expectedCommand ||
      decision['workspaceRoot'] != ownedRoot ||
      decision['approved'] != false ||
      decision['cancelled'] != cancelled) {
    throw StateError('The exact owned probe command did not reach approval.');
  }
  final shellCalls = calls.where((call) => call.name == 'bash').toList();
  if (shellCalls.length != 1 ||
      (jsonDecode(shellCalls.single.argumentsJson) as Map)['command'] !=
          expectedCommand) {
    throw StateError('The bash invocation does not match the approved probe.');
  }
}
