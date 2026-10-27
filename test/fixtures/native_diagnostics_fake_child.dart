import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> arguments) async {
  final request = jsonDecode(await stdin.transform(utf8.decoder).join()) as Map;
  final mode = arguments.single;
  final output = File(request['output'] as String);
  final phase = File(request['phase'] as String);
  final payload = <String, Object?>{
    'runtime': request['runtime'],
    'nonce': request['nonce'],
    'code': 'SURFACE_OBSERVED',
    'phase': 'complete',
    'marker': 'tts_v1',
  };
  const secret =
      'PRIVATE_DIAGNOSTIC_TOKEN /Users/private-user/key https://private.invalid/?token=SECRET \u001b[31m';
  switch (mode) {
    case 'fifo-result':
    case 'fifo-phase':
    case 'link-result':
    case 'link-phase':
      final destination = mode.endsWith('result') ? output.path : phase.path;
      final fifo = mode.startsWith('link') ? '$destination.pipe' : destination;
      final created = await Process.run('mkfifo', [fifo]);
      if (created.exitCode != 0) {
        exitCode = 1;
        return;
      }
      if (mode.startsWith('link')) await Link(destination).create(fifo);
      return;
    case 'hang':
      await Future<void>.delayed(const Duration(minutes: 5));
    case 'fail':
      stderr.writeln(secret);
      exitCode = 7;
      return;
    case 'phase-fail':
      await phase.writeAsString('open');
      stderr.writeln(secret);
      exitCode = 7;
      return;
    case 'stdout-only':
      stdout.writeln(jsonEncode(payload));
      return;
    case 'malformed':
      await output.writeAsString(secret);
      return;
    case 'oversized':
      await output.writeAsString(secret * 1000);
      return;
    case 'duplicate':
      await output.writeAsString(
        '{"runtime":"PRIVATE_DIAGNOSTIC_TOKEN",${jsonEncode(payload).substring(1)}',
      );
      return;
    case 'extra':
      payload['secret'] = secret;
    case 'wrong-nonce':
      payload['nonce'] = secret;
    case 'wrong-runtime':
      payload['runtime'] = 'litert_lm';
    case 'inconsistent':
      payload['phase'] = 'open';
    case 'flood':
      for (var i = 0; i < 3000; i++) {
        stdout.writeln(secret);
        stderr.writeln(secret);
      }
    case 'success':
      break;
  }
  await output.writeAsString(jsonEncode(payload), flush: true);
}
