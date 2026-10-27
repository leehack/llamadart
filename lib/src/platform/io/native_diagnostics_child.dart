import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'native_diagnostics.dart';
import 'native_diagnostics_probe.dart';

/// Private source entry point. Native stdout/stderr are discarded by its owner.
Future<void> main() async {
  try {
    final bytes = <int>[];
    await for (final chunk in stdin) {
      if (bytes.length + chunk.length > 32 * 1024) {
        exitCode = 1;
        return;
      }
      bytes.addAll(chunk);
    }
    final request = decodeNativeDiagnosticJson(utf8.decode(bytes));
    if (request is! Map ||
        request.keys.join(',') != 'runtime,nonce,output,phase,target' ||
        !nativeDiagnosticRuntimes.contains(request['runtime']) ||
        request['nonce'] is! String ||
        !RegExp(r'^[a-f0-9]{48}$').hasMatch(request['nonce'] as String) ||
        request['output'] is! String ||
        request['phase'] is! String) {
      exitCode = 1;
      return;
    }
    final target = NativeDiagnosticTarget.fromJson(request['target']);
    final output = File(request['output'] as String);
    final phase = File(request['phase'] as String);
    if (!path.isAbsolute(output.path) ||
        !path.isAbsolute(phase.path) ||
        output.path.length > 4096 ||
        phase.path.length > 4096 ||
        path.basename(output.path) != 'result.json' ||
        path.basename(phase.path) != 'phase' ||
        path.dirname(output.path) != path.dirname(phase.path) ||
        !path
            .basename(path.dirname(output.path))
            .startsWith('llamadart_native_diagnostic_')) {
      exitCode = 1;
      return;
    }
    final observation = probeNativeDiagnostic(
      request['runtime'] as String,
      target,
      onPhase: (value) => phase.writeAsStringSync(value, flush: true),
    );
    await output.writeAsString(
      jsonEncode({
        'runtime': request['runtime'],
        'nonce': request['nonce'],
        'code': observation['code'],
        'phase': observation['phase'],
        'marker': observation['abi_marker'],
      }),
      flush: true,
    );
  } catch (_) {
    exitCode = 1;
  }
}
