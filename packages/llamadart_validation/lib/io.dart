/// Native filesystem adapters; never imported by the shared/browser suite.
library;

import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'llamadart_validation.dart';

/// Verifies model bytes before reuse or load; download timing is separate.
Future<({String path, Map<String, dynamic> evidence})> prepareModel(
  ValidationProfile profile,
  Directory cache, {
  String? suppliedPath,
  Duration timeout = const Duration(minutes: 5),
  http.Client? client,
  Future<void> Function(Map<String, dynamic>)? onProgress,
}) async {
  profile.requireRunnable();
  final started = Stopwatch()..start();
  final target = suppliedPath == null
      ? File(p.join(cache.path, profile.modelHash, profile.filename))
      : File(suppliedPath);
  var hit = target.existsSync();
  Future<void> progress(String stage, int bytes, String state) async {
    await onProgress?.call({
      'type': 'preparation_progress',
      'profile_id': profile.id,
      'model_sha256': profile.modelHash,
      'stage': stage,
      'state': state,
      'bytes': bytes,
      'expected_bytes': profile.model['bytes'],
      'elapsed_ms': started.elapsedMilliseconds,
    });
  }

  Future<bool> valid(File file) async {
    final length = await file.length();
    await progress('checksum', 0, 'started');
    if (length != profile.model['bytes']) {
      await progress('checksum', length, 'rejected');
      return false;
    }
    var hashed = 0;
    var lastReport = started.elapsedMilliseconds;
    final hash = await sha256
        .bind(
          file.openRead().asyncMap((chunk) async {
            hashed += chunk.length;
            if (started.elapsedMilliseconds - lastReport >= 10000) {
              await progress('checksum', hashed, 'running');
              lastReport = started.elapsedMilliseconds;
            }
            return chunk;
          }),
        )
        .first;
    final matches = hash.toString() == profile.modelHash;
    await progress('checksum', hashed, matches ? 'verified' : 'rejected');
    return matches;
  }

  final checksum = Stopwatch()..start();
  if (hit && !await valid(target)) {
    if (suppliedPath != null) {
      throw const FormatException('Supplied model hash/size mismatch');
    }
    await target.delete();
    hit = false;
  }
  checksum.stop();
  var downloadMs = 0;
  if (!hit) {
    if (suppliedPath != null) {
      throw const FileSystemException('Supplied model is missing');
    }
    await target.parent.create(recursive: true);
    final temporary = File(
      '${target.path}.${DateTime.now().microsecondsSinceEpoch}.part',
    );
    final transport = client ?? http.Client();
    var lastReport = started.elapsedMilliseconds;
    var receivedBytes = 0;
    var deadlineExpired = false;
    final timer = Timer(timeout, () {
      deadlineExpired = true;
      transport.close();
    });
    IOSink? sink;
    final watch = Stopwatch()..start();
    try {
      await progress('download', 0, 'started');
      await (() async {
        final response = await transport.send(
          http.Request('GET', Uri.parse(profile.model['url'] as String)),
        );
        if (response.statusCode != 200) {
          throw HttpException('Model download HTTP ${response.statusCode}');
        }
        sink = temporary.openWrite();
        await for (final chunk in response.stream) {
          receivedBytes += chunk.length;
          if (receivedBytes > (profile.model['bytes'] as int)) {
            throw const FormatException(
              'Model download exceeded locked byte size',
            );
          }
          sink!.add(chunk);
          if (started.elapsedMilliseconds - lastReport >= 10000) {
            await progress('download', receivedBytes, 'running');
            lastReport = started.elapsedMilliseconds;
          }
        }
        await sink!.flush();
        await sink!.close();
        sink = null;
      })();
      if (deadlineExpired) throw TimeoutException('Model download deadline');
      timer.cancel();
      downloadMs = watch.elapsedMilliseconds;
      await progress('download', receivedBytes, 'finished');
      checksum.start();
      if (!await valid(temporary)) {
        throw const FormatException('Downloaded model hash/size mismatch');
      }
      checksum.stop();
      await temporary.rename(target.path);
    } catch (_) {
      if (deadlineExpired) {
        throw TimeoutException(
          'Model download deadline exceeded after receiving $receivedBytes '
          'of ${profile.model['bytes']} bytes',
          timeout,
        );
      }
      rethrow;
    } finally {
      timer.cancel();
      transport.close();
      await sink?.close();
      if (temporary.existsSync()) await temporary.delete();
    }
  }
  await progress('ready', profile.model['bytes'] as int, 'verified');
  return (
    path: target.absolute.path,
    evidence: {
      'sha256': profile.modelHash,
      'bytes': profile.model['bytes'],
      'verified': true,
      'cache_hit': hit,
      'download_timeout_ms': timeout.inMilliseconds,
      'download_ms': downloadMs,
      'checksum_ms': checksum.elapsedMilliseconds,
      'total_ms': started.elapsedMilliseconds,
    },
  );
}

/// Writes incremental records synchronously enough to survive a native crash.
class FileValidationJournal {
  FileValidationJournal(this.directory) {
    directory.createSync(recursive: true);
    final file = File(p.join(directory.path, 'events.jsonl'));
    if (file.existsSync()) {
      throw StateError('Run output already exists; use a new run/attempt');
    }
    _file = file.openSync(mode: FileMode.write);
  }
  final Directory directory;
  late final RandomAccessFile _file;

  Future<void> emit(Map<String, dynamic> event) async {
    final line = jsonEncode(event);
    _file.writeStringSync('$line\n');
    _file.flushSync();
    if (event['type'] == 'manifest') {
      File(
        p.join(directory.path, 'manifest.json'),
      ).writeAsStringSync(line, flush: true);
    }
    // Complete, bounded records provide a provider-log fallback.
    if (utf8.encode(line).length <= 32768) {
      stdout.writeln('LLAMADART_VALIDATION $line');
    }
  }

  /// Persists diagnostics separately from the manifest-first suite protocol.
  Future<void> emitPreparation(Map<String, dynamic> event) async {
    final line = jsonEncode(event);
    File(
      p.join(directory.path, 'preparation.jsonl'),
    ).writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
    stdout.writeln('LLAMADART_PREPARATION $line');
  }

  void close() => _file.closeSync();
}

/// Recomputes every report format from an existing run journal.
ValidationReport writeReports(Directory directory, {String? nativeLog}) {
  final report = ValidationReport.parse(
    File(p.join(directory.path, 'events.jsonl')).readAsStringSync(),
    nativeLog: nativeLog,
  );
  for (final entry in {
    'results.json': const JsonEncoder.withIndent('  ').convert(report.toJson()),
    'junit.xml': report.toJUnit(),
    'samples.csv': report.toCsv(),
    'summary.html': report.toHtml(),
  }.entries) {
    File(p.join(directory.path, entry.key)).writeAsStringSync(entry.value);
  }
  return report;
}

/// Simple strict long-option parser shared by the private CLI entry points.
Map<String, String> parseOptions(List<String> args, Set<String> allowed) {
  final values = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (!arg.startsWith('--')) {
      throw FormatException('Expected option, got $arg');
    }
    final parts = arg.substring(2).split('=');
    final key = parts.first;
    if (!allowed.contains(key) || values.containsKey(key)) {
      throw FormatException('Unknown/duplicate option --$key');
    }
    if (key == 'help' || key == 'list') {
      values[key] = 'true';
    } else if (parts.length > 1) {
      values[key] = parts.skip(1).join('=');
    } else {
      if (++i >= args.length || args[i].startsWith('--')) {
        throw FormatException('Missing --$key value');
      }
      values[key] = args[i];
    }
  }
  return values;
}
