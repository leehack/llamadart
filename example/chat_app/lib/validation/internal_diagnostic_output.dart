import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:llamadart_validation/llamadart_validation.dart';
import 'package:path/path.dart' as p;

/// Opt-in diagnostic storage. This does not qualify a runtime or passing case.
/// The app-private directory and attempt id must come from the admitted build.
class InternalDiagnosticOutput {
  InternalDiagnosticOutput._(this.directory, this.binding);

  static const totalLimit = 8 * 1024 * 1024;
  static const fileLimit = 2 * 1024 * 1024;
  static const preparationLimit = 256 * 1024;
  static const recordLimit = 64 * 1024;
  static const _sealReserve = 64 * 1024;
  static const _names = {
    'events.jsonl',
    'preparation.jsonl',
    'manifest.json',
    'results.json',
    'junit.xml',
    'samples.csv',
    'summary.html',
    'diagnostic-seal.json',
  };

  final Directory directory;
  final Map<String, dynamic> binding;
  bool _manifestSeen = false;
  bool _finished = false;

  /// Reserves a fresh directory; links, existing runs and invalid identities fail.
  static InternalDiagnosticOutput open(
    Directory support,
    Map<String, dynamic> binding,
  ) {
    final immutable = jsonDecode(jsonEncode(binding)) as Map<String, dynamic>;
    final id = immutable['run_id'];
    final cases = immutable['expected_case_ids'];
    if (immutable.length != 10 ||
        !immutable.keys.toSet().containsAll({
          'run_id',
          'profile_hash',
          'model_sha256',
          'model_bytes',
          'source_commit',
          'source_snapshot_sha256',
          'source_dirty',
          'hook_sha256',
          'litert_tag',
          'expected_case_ids',
        }) ||
        id is! String ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$').hasMatch(id) ||
        cases is! List ||
        cases.isEmpty ||
        cases.length > 256 ||
        cases.any(
          (e) =>
              e is! String ||
              !RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,79}$').hasMatch(e),
        ) ||
        cases.toSet().length != cases.length ||
        immutable['model_bytes'] is! int ||
        (immutable['model_bytes'] as int) <= 0 ||
        immutable['source_dirty'] is! bool ||
        immutable['litert_tag'] is! String ||
        !RegExp(
          r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$',
        ).hasMatch(immutable['litert_tag'] as String) ||
        !RegExp(r'^[a-f0-9]{40}$').hasMatch('${immutable['source_commit']}') ||
        [
          'profile_hash',
          'model_sha256',
          'hook_sha256',
          'source_snapshot_sha256',
        ].any(
          (key) => !RegExp(r'^[a-f0-9]{64}$').hasMatch('${immutable[key]}'),
        )) {
      throw const FormatException('Invalid internal diagnostic binding');
    }
    if (!p.isAbsolute(support.path) ||
        FileSystemEntity.typeSync(support.path, followLinks: false) !=
            FileSystemEntityType.directory) {
      throw const FileSystemException(
        'Support directory must be a real absolute directory',
      );
    }
    immutable['expected_case_ids'] = List<String>.unmodifiable(
      cases.cast<String>(),
    );
    final root = support.resolveSymbolicLinksSync();
    var current = root;
    for (final segment in ['validation', 'runs']) {
      current = p.join(current, segment);
      final type = FileSystemEntity.typeSync(current, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        Directory(current).createSync();
      }
      if (FileSystemEntity.typeSync(current, followLinks: false) !=
              FileSystemEntityType.directory ||
          Directory(current).resolveSymbolicLinksSync() != current) {
        throw const FileSystemException(
          'Diagnostic parent is not a confined directory',
        );
      }
    }
    final run = Directory(p.join(current, id));
    if (FileSystemEntity.typeSync(run.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw StateError('Diagnostic run already exists');
    }
    run.createSync();
    return InternalDiagnosticOutput._(run, Map.unmodifiable(immutable));
  }

  void _checkDirectory() {
    // Recheck parents on every write, not just when the run is reserved.
    for (var dir = directory; ; dir = dir.parent) {
      if (FileSystemEntity.typeSync(dir.path, followLinks: false) !=
              FileSystemEntityType.directory ||
          dir.resolveSymbolicLinksSync() != dir.path) {
        throw const FileSystemException(
          'Diagnostic directory changed or escaped',
        );
      }
      if (dir.parent.path == dir.path) break;
    }
    for (final entry in directory.listSync(followLinks: false)) {
      if (!_names.contains(p.basename(entry.path)) ||
          FileSystemEntity.typeSync(entry.path, followLinks: false) !=
              FileSystemEntityType.file) {
        throw const FileSystemException('Unexpected diagnostic entry or link');
      }
    }
  }

  File _file(String name) {
    _checkDirectory();
    if (!_names.contains(name)) {
      throw const FormatException('Invalid diagnostic filename');
    }
    final file = File(p.join(directory.path, name));
    final type = FileSystemEntity.typeSync(file.path, followLinks: false);
    if (type != FileSystemEntityType.file &&
        type != FileSystemEntityType.notFound) {
      throw const FileSystemException(
        'Diagnostic target is not a regular file',
      );
    }
    return file;
  }

  int get _used => directory
      .listSync(followLinks: false)
      .fold(0, (n, e) => n + File(e.path).lengthSync());

  void _write(
    String name,
    String text, {
    bool append = false,
    bool seal = false,
  }) {
    final file = _file(name);
    final bytes = utf8.encode(text);
    final prior = file.existsSync() ? file.lengthSync() : 0;
    if (!append && prior != 0) {
      throw StateError('Diagnostic file already exists');
    }
    final limit = name == 'preparation.jsonl' ? preparationLimit : fileLimit;
    if ((append ? prior : 0) + bytes.length > limit ||
        _used + bytes.length > totalLimit - (seal ? 0 : _sealReserve)) {
      throw StateError('Diagnostic storage budget exceeded');
    }
    file.writeAsBytesSync(
      bytes,
      mode: append ? FileMode.append : FileMode.write,
      flush: true,
    );
    _checkDirectory();
  }

  void _checkManifest(Map<String, dynamic> event) {
    final profile = event['profile'];
    final environment = event['environment'];
    final preparation = event['preparation'];
    if (_manifestSeen ||
        event['run_id'] != binding['run_id'] ||
        profile is! Map<String, dynamic> ||
        environment is! Map ||
        preparation is! Map ||
        jsonHash(profile) != binding['profile_hash'] ||
        event['profile_hash'] != binding['profile_hash'] ||
        (profile['model'] as Map?)?['sha256'] != binding['model_sha256'] ||
        (profile['model'] as Map?)?['bytes'] != binding['model_bytes'] ||
        preparation['verified'] != true ||
        preparation['sha256'] != binding['model_sha256'] ||
        preparation['bytes'] != binding['model_bytes'] ||
        environment['source_snapshot_sha256'] !=
            binding['source_snapshot_sha256'] ||
        environment['source_commit'] != binding['source_commit'] ||
        environment['source_dirty'] != binding['source_dirty'] ||
        environment['hook_sha256'] != binding['hook_sha256'] ||
        environment['litert_tag'] != binding['litert_tag'] ||
        canonicalJson(event['case_ids']) !=
            canonicalJson(binding['expected_case_ids'])) {
      throw StateError('Diagnostic manifest identity mismatch');
    }
  }

  /// Keeps failed terminal records unchanged; a binding mismatch fails before writing.
  Future<void> emit(Map<String, dynamic> event) async {
    if (_finished) throw StateError('Diagnostic output is finished');
    final line = jsonEncode(event);
    if (utf8.encode(line).length + 1 > recordLimit) {
      throw StateError('Diagnostic record budget exceeded');
    }
    if (event['type'] == 'manifest') _checkManifest(event);
    _write('events.jsonl', '$line\n', append: true);
    if (event['type'] == 'manifest') {
      _write('manifest.json', line);
      _manifestSeen = true;
    }
  }

  Future<void> emitPreparation(Map<String, dynamic> event) async {
    if (_finished) throw StateError('Diagnostic output is finished');
    final line = jsonEncode(event);
    if (utf8.encode(line).length + 1 > recordLimit) {
      throw StateError('Diagnostic record budget exceeded');
    }
    _write('preparation.jsonl', '$line\n', append: true);
  }

  /// Produces the same reports, plus an inventory seal, even for functional FAIL.
  /// Partial journals stay incomplete; the seal never promotes them to success.
  ValidationReport finish() {
    if (_finished) throw StateError('Diagnostic output is finished');
    final journal = _file('events.jsonl');
    final report = ValidationReport.parse(
      journal.existsSync() ? journal.readAsStringSync() : '',
    );
    final rendered = {
      'results.json': const JsonEncoder.withIndent(
        '  ',
      ).convert(report.toJson()),
      'junit.xml': report.toJUnit(),
      'samples.csv': report.toCsv(),
      'summary.html': report.toHtml(),
    };
    final lengths = rendered.values.map((v) => utf8.encode(v).length);
    if (lengths.any((n) => n > fileLimit) ||
        _used + lengths.fold(0, (a, b) => a + b) > totalLimit - _sealReserve) {
      throw StateError('Diagnostic rendered report budget exceeded');
    }
    for (final entry in rendered.entries) {
      _write(entry.key, entry.value);
    }
    final inventory = <String, dynamic>{};
    for (final entry in directory.listSync(followLinks: false)) {
      final name = p.basename(entry.path);
      final file = _file(name);
      inventory[name] = {
        'bytes': file.lengthSync(),
        'sha256': sha256.convert(file.readAsBytesSync()).toString(),
      };
    }
    _write(
      'diagnostic-seal.json',
      jsonEncode({
        'schema_version': 1,
        'binding': binding,
        'complete':
            _manifestSeen &&
            report.problems.isEmpty &&
            report.finished &&
            report.cleanupPassed,
        'assertions_passed': report.assertionsPassed,
        'files': inventory,
      }),
      seal: true,
    );
    _finished = true;
    return report;
  }
}
