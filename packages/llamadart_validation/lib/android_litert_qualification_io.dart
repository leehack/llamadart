/// IO capture for the private, source-bound S24 LiteRT qualifier.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';

import 'src/litert_gpu_failure_markers.dart';

Future<String> s24LiteRtFileHash(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

Future<void> requireS24LiteRtFile(File file, Map lock) async {
  if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
          FileSystemEntityType.file ||
      await file.length() != lock['bytes'] ||
      await s24LiteRtFileHash(file) != lock['sha256']) {
    throw const FormatException(
      'S24 input bytes differ from admitted identity',
    );
  }
}

/// Checks the complete installed native directory, including non-LiteRT payloads.
Future<void> requireS24LiteRtPayloads(Directory directory, Map binding) async {
  final inventory = binding['libraries'] as Map;
  final files = directory.listSync().whereType<File>().where(
    (file) => file.path.endsWith('.so'),
  );
  final names = {for (final file in files) file.uri.pathSegments.last};
  if (names.length != inventory.length || !names.containsAll(inventory.keys)) {
    throw const FormatException('Installed Android native inventory differs');
  }
  for (final entry in inventory.entries) {
    await requireS24LiteRtFile(
      File('${directory.path}/${entry.key}'),
      entry.value as Map,
    );
  }
}

/// Copies captured bytes before parsing or running an oracle.
Map<String, dynamic> captureS24LiteRtBytes(List<int> bytes) => {
  'bytes': bytes.length,
  'sha256': sha256.convert(bytes).toString(),
  'base64': base64Encode(bytes),
};

List<int> readS24LiteRtBytes(Map capture) {
  final bytes = base64Decode(capture['base64'] as String);
  if (bytes.length != capture['bytes'] ||
      sha256.convert(bytes).toString() != capture['sha256']) {
    throw const FormatException('Changed S24 captured bytes');
  }
  return bytes;
}

/// Actual process mappings plus file hashes; same-name substitutions are refused.
Future<Map<String, dynamic>> captureS24LiteRtMappings(
  Directory directory,
  Map binding,
) async {
  final raw = await File('/proc/self/maps').readAsBytes();
  final observed = <String, String>{};
  for (final line in utf8.decode(raw).split('\n')) {
    final match = RegExp(r'(/[^\n]*\.so)(?: \(deleted\))?$').firstMatch(line);
    if (match == null) continue;
    final path = match.group(1)!;
    final name = Uri.file(path).pathSegments.last;
    if (!(binding['libraries'] as Map).containsKey(name)) continue;
    if (path != '${directory.path}/$name') {
      throw const FormatException('Another Android runtime payload is mapped');
    }
    await requireS24LiteRtFile(
      File(path),
      (binding['libraries'] as Map)[name] as Map,
    );
    observed[name] = path;
  }
  if (!observed.containsKey('libLiteRtLm.so')) {
    throw const FormatException('Bound LiteRT core was not observed mapped');
  }
  return {
    'capture': captureS24LiteRtBytes(raw),
    'verified': observed.keys.toList()..sort(),
  };
}

/// Scoped stderr descriptor ownership; never restores while native work is live.
final class S24LiteRtStderr {
  S24LiteRtStderr._(this._saved);
  int? _saved;
  static final _process = DynamicLibrary.process();
  static final _close = _process
      .lookupFunction<Int32 Function(Int32), int Function(int)>('close');
  static final _dup2 = _process
      .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
        'dup2',
      );
  static final _flush = _process
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('fflush');

  factory S24LiteRtStderr.open(File output) {
    final dup = _process
        .lookupFunction<Int32 Function(Int32), int Function(int)>('dup');
    final creat = _process
        .lookupFunction<
          Int32 Function(Pointer<Utf8>, Uint32),
          int Function(Pointer<Utf8>, int)
        >('creat');
    final path = output.path.toNativeUtf8();
    _flush(nullptr);
    final saved = dup(2);
    try {
      if (saved < 0) throw StateError('Cannot save native stderr');
      final descriptor = creat(path, 384);
      if (descriptor < 0) throw StateError('Cannot open native stderr capture');
      try {
        if (_dup2(descriptor, 2) != 2) {
          throw StateError('Cannot capture native stderr');
        }
      } finally {
        _close(descriptor);
      }
      return S24LiteRtStderr._(saved);
    } on Object {
      if (saved >= 0) _close(saved);
      rethrow;
    } finally {
      malloc.free(path);
    }
  }

  void close() {
    final saved = _saved;
    if (saved == null) return;
    _flush(nullptr);
    _saved = null;
    try {
      if (_dup2(saved, 2) != 2) {
        throw StateError('Cannot restore native stderr');
      }
    } finally {
      _close(saved);
    }
  }
}

/// Validates S24's own child protocol after the caller journals its raw captures.
/// The shared Android helper's GGUF protocol result is deliberately not used.
List<Map<String, dynamic>> readS24LiteRtChildRecords(
  Map receipt,
  List<int> stdoutBytes,
  List<int> stderrBytes, {
  required String binding,
  required String caseId,
}) {
  if (receipt['binding'] != binding ||
      receipt['case_id'] != caseId ||
      receipt['pid'] is! int ||
      receipt['pid'] <= 0 ||
      receipt['exit_code'] != 0 ||
      receipt['timed_out'] != false ||
      receipt['capture_limit_exceeded'] != false ||
      receipt['capture_failed'] != false ||
      receipt['elapsed_ms'] is! int ||
      receipt['elapsed_ms'] < 0 ||
      receipt['elapsed_ms'] > 125000) {
    throw const FormatException('Owned native child did not complete safely');
  }
  for (final entry in {
    'stdout.jsonl': stdoutBytes,
    'stderr.log': stderrBytes,
  }.entries) {
    final lock = (receipt['files'] as Map)[entry.key] as Map;
    if (entry.value.length != lock['bytes'] ||
        sha256.convert(entry.value).toString() != lock['sha256']) {
      throw const FormatException('Changed owned-child capture');
    }
  }
  final text = utf8.decode(stdoutBytes);
  if (!text.endsWith('\n')) {
    throw const FormatException('Truncated S24 child log');
  }
  final lines = const LineSplitter().convert(text);
  if (lines.length < 2 || lines.length > 16) {
    throw const FormatException('Invalid S24 child record count');
  }
  final records = <Map<String, dynamic>>[];
  for (final line in lines) {
    if (utf8.encode(line).length > 64 * 1024) {
      throw const FormatException('Oversized S24 child record');
    }
    final value = jsonDecode(line);
    if (value is! Map<String, dynamic> ||
        value['schema'] != 1 ||
        value['binding'] != binding ||
        value['case_id'] != caseId ||
        value['pid'] != receipt['pid'] ||
        value['sequence'] != records.length ||
        !const [
          'started',
          'maps',
          'generation',
          'finished',
        ].contains(value['event'])) {
      throw const FormatException('S24 child protocol binding mismatch');
    }
    records.add(value);
  }
  if (records.first['event'] != 'started' ||
      records.last['event'] != 'finished' ||
      records.where((value) => value['event'] == 'started').length != 1 ||
      records.where((value) => value['event'] == 'finished').length != 1) {
    throw const FormatException('Incomplete S24 child lifetime');
  }
  return records;
}

List<int> readS24LiteRtHex(String value) {
  if (value.length.isOdd || !RegExp(r'^[0-9a-f]*$').hasMatch(value)) {
    throw const FormatException('Invalid S24 child hexadecimal bytes');
  }
  return [
    for (var i = 0; i < value.length; i += 2)
      int.parse(value.substring(i, i + 2), radix: 16),
  ];
}

/// Parses only an already-captured synchronous native response's text fields.
String readS24LiteRtNativeAnswer(List<int> bytes) {
  final value = jsonDecode(utf8.decode(bytes));
  if (value is! Map ||
      value['content'] is! List ||
      (value['reasoning_content'] != null &&
          value['reasoning_content'] != '') ||
      (value['tool_calls'] is List &&
          (value['tool_calls'] as List).isNotEmpty)) {
    throw const FormatException(
      'Native control returned unsupported response content',
    );
  }
  final text = StringBuffer();
  for (final part in value['content'] as List) {
    if (part is! Map || part['type'] != 'text' || part['text'] is! String) {
      throw const FormatException('Native control returned non-text content');
    }
    text.write(part['text']);
  }
  return text.toString();
}

/// This observes initialization, never per-request accelerator execution.
bool s24LiteRtGpuInitialized(String log) =>
    RegExp(
      r'Selected adapter: [^\n]*Adreno[^\n]*750[^\n]*backend=Vulkan, adapterType=(?:Integrated GPU|Discrete GPU)',
    ).hasMatch(log) &&
    log.contains('Created a WebGPU environment.') &&
    RegExp(
      r'Total \d+ external tensors are used for delegate inputs and outputs',
    ).hasMatch(log) &&
    !liteRtGpuFailureMarkers.any(
      (marker) => log.toLowerCase().contains(marker.toLowerCase()),
    );
