import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:llamadart/llamadart.dart';
import 'package:path/path.dart' as p;

import 'workspace_guard.dart';

/// Minimal Pi-style file and shell tools for one workspace.
class WorkspaceTools {
  static const int _defaultReadLimit = 200;
  static const int _maxReadLimit = 800;
  static const int _maxFileBytes = 1024 * 1024;
  static const int _maxReadOutputBytes = 12000;
  static const int _maxShellOutputChars = 12000;

  final WorkspaceGuard _guard;
  Process? _activeProcess;
  bool _toolInProgress = false;
  bool _cancelRequested = false;

  WorkspaceTools({required String workspaceRoot})
    : _guard = WorkspaceGuard(workspaceRoot);

  String get workspaceRoot => _guard.workspaceRoot;

  /// The four tools exposed to the coding agent.
  List<ToolDefinition> buildToolDefinitions() {
    return <ToolDefinition>[
      ToolDefinition(
        name: 'read',
        description:
            'Read bounded UTF-8 text from a workspace file. offset is a '
            '1-based line number and limit is a line count.',
        parameters: <ToolParam>[
          ToolParam.string('path', required: true),
          ToolParam.integer('offset'),
          ToolParam.integer('limit'),
        ],
        handler: read,
      ),
      ToolDefinition(
        name: 'write',
        description:
            'Overwrite or create a UTF-8 workspace file, creating parent '
            'directories when necessary.',
        parameters: <ToolParam>[
          ToolParam.string('path', required: true),
          ToolParam.string('content', required: true),
        ],
        handler: write,
      ),
      ToolDefinition(
        name: 'edit',
        description:
            'Replace exactly one literal occurrence in a UTF-8 workspace file. '
            'The call fails without writing when the match count is not one.',
        parameters: <ToolParam>[
          ToolParam.string('path', required: true),
          ToolParam.string('old_text', required: true),
          ToolParam.string('new_text', required: true),
        ],
        handler: edit,
      ),
      ToolDefinition(
        name: 'bash',
        description:
            'Run a command from the workspace using Bash on Unix or cmd.exe on '
            'Windows. NOT SANDBOXED: the command has the user\'s permissions '
            'and can access or change files outside the workspace.',
        parameters: <ToolParam>[
          ToolParam.string('command', required: true),
          ToolParam.integer(
            'timeout',
            description: 'Timeout in seconds (1-120, default 30).',
          ),
        ],
        handler: bash,
      ),
    ];
  }

  Future<Object?> read(ToolParams params) {
    return _runTool(() async {
      final path = params.getRequiredString('path');
      final offset = _boundedInt(
        params.getInt('offset') ?? 1,
        name: 'offset',
        minimum: 1,
        maximum: 1000000,
      );
      final limit = _boundedInt(
        params.getInt('limit') ?? _defaultReadLimit,
        name: 'limit',
        minimum: 1,
        maximum: _maxReadLimit,
      );
      final resolved = _guard.resolvePath(path);
      final file = File(resolved);
      _requireRegularFile(file, path);
      final fileBytes = file.lengthSync();
      if (fileBytes > _maxFileBytes) {
        throw ArgumentError(
          'File is too large to read ($fileBytes bytes, max $_maxFileBytes).',
        );
      }

      _throwIfCancelled();
      final source = await file.readAsString(encoding: utf8);
      _throwIfCancelled();
      final lines = const LineSplitter().convert(source);
      final startIndex = offset - 1;
      if (startIndex >= lines.length) {
        return <String, Object?>{
          'ok': true,
          'path': _guard.toWorkspaceRelative(resolved),
          'offset': offset,
          'line_count': 0,
          'total_lines': lines.length,
          'content': '',
          'content_bytes': 0,
          'truncated': false,
        };
      }

      final endExclusive = (startIndex + limit).clamp(0, lines.length);
      final bounded = _boundedLines(
        lines,
        startIndex: startIndex,
        endExclusive: endExclusive,
        maxBytes: _maxReadOutputBytes,
      );
      final endLine = startIndex + bounded.lineCount;
      final hasMore = endLine < lines.length;
      return <String, Object?>{
        'ok': true,
        'path': _guard.toWorkspaceRelative(resolved),
        'offset': offset,
        'line_count': bounded.lineCount,
        'total_lines': lines.length,
        if (hasMore) 'next_offset': endLine + 1,
        'content': bounded.content,
        'content_bytes': bounded.bytes,
        'truncated': bounded.truncated || hasMore,
      };
    });
  }

  Future<Object?> write(ToolParams params) {
    return _runTool(() async {
      final path = params.getRequiredString('path');
      final content = params.getRequiredString('content');
      final resolved = _guard.resolvePath(path);
      _requireWritableTarget(resolved, path);
      _throwIfCancelled();
      await Directory(p.dirname(resolved)).create(recursive: true);
      await File(resolved).writeAsString(
        content,
        encoding: utf8,
        mode: FileMode.write,
        flush: true,
      );
      return <String, Object?>{
        'ok': true,
        'path': _guard.toWorkspaceRelative(resolved),
        'bytes_written': utf8.encode(content).length,
      };
    });
  }

  Future<Object?> edit(ToolParams params) {
    return _runTool(() async {
      final path = params.getRequiredString('path');
      final oldText = params.getRequiredString('old_text');
      final newText = params.getRequiredString('new_text');
      if (oldText.isEmpty) {
        throw ArgumentError('old_text cannot be empty.');
      }
      final resolved = _guard.resolvePath(path);
      final file = File(resolved);
      _requireRegularFile(file, path);
      final fileBytes = file.lengthSync();
      if (fileBytes > _maxFileBytes) {
        throw ArgumentError(
          'File is too large to edit ($fileBytes bytes, max $_maxFileBytes).',
        );
      }

      _throwIfCancelled();
      final original = await file.readAsString(encoding: utf8);
      final first = original.indexOf(oldText);
      if (first < 0) {
        throw StateError('old_text was not found in $path.');
      }
      if (original.indexOf(oldText, first + oldText.length) >= 0) {
        throw StateError('old_text occurs more than once in $path.');
      }
      _throwIfCancelled();
      final updated = original.replaceFirst(oldText, newText, first);
      await file.writeAsString(
        updated,
        encoding: utf8,
        mode: FileMode.write,
        flush: true,
      );
      return <String, Object?>{
        'ok': true,
        'path': _guard.toWorkspaceRelative(resolved),
        'replacements': 1,
        'bytes_written': utf8.encode(updated).length,
      };
    });
  }

  Future<Object?> bash(ToolParams params) async {
    final command = params.getRequiredString('command');
    if (command.trim().isEmpty) {
      throw ArgumentError('command cannot be empty.');
    }
    final timeout = _boundedInt(
      params.getInt('timeout') ?? 30,
      name: 'timeout',
      minimum: 1,
      maximum: 120,
    );

    return _runTool(() async {
      final shell = _platformShell(command);
      Process? process;
      try {
        process = await Process.start(
          shell.executable,
          shell.arguments,
          workingDirectory: workspaceRoot,
          runInShell: false,
        );
        _activeProcess = process;
        try {
          await process.stdin.close();
        } catch (_) {
          // The process may close stdin itself before the parent does.
        }
        if (_cancelRequested) {
          _terminateProcessTree(process);
        }
      } catch (error) {
        return <String, Object?>{
          'ok': false,
          'executed': false,
          'sandboxed': false,
          'error': 'Failed to start platform shell: $error',
        };
      }

      final stdoutCollector = _BoundedCollector(_maxShellOutputChars ~/ 2);
      final stderrCollector = _BoundedCollector(_maxShellOutputChars ~/ 2);
      final stdoutDrain = _drain(
        process.stdout,
        stdoutCollector,
        streamName: 'stdout',
      );
      final stderrDrain = _drain(
        process.stderr,
        stderrCollector,
        streamName: 'stderr',
      );

      var timedOut = false;
      try {
        final exitCode = await process.exitCode.timeout(
          Duration(seconds: timeout),
          onTimeout: () {
            timedOut = true;
            _terminateProcessTree(process!);
            return -1;
          },
        );
        try {
          await Future.wait(<Future<void>>[
            stdoutDrain.done,
            stderrDrain.done,
          ]).timeout(const Duration(seconds: 2));
        } on TimeoutException {
          await Future.wait(<Future<void>>[
            stdoutDrain.cancel(),
            stderrDrain.cancel(),
          ]);
        }

        final cancelled = _cancelRequested;
        return <String, Object?>{
          'ok': !cancelled && !timedOut && exitCode == 0,
          'executed': true,
          'sandboxed': false,
          'exit_code': exitCode,
          'cancelled': cancelled,
          'timed_out': timedOut,
          'stdout': stdoutCollector.value,
          'stderr': stderrCollector.value,
          'output_truncated':
              stdoutCollector.truncated || stderrCollector.truncated,
          if (cancelled) 'error': 'Command cancelled.',
          if (timedOut) 'error': 'Command timed out.',
        };
      } finally {
        if (identical(_activeProcess, process)) {
          _activeProcess = null;
        }
      }
    });
  }

  /// Cancels the active tool, terminating a shell process tree when present.
  bool cancelActiveTool() {
    if (!_toolInProgress) {
      return false;
    }
    _cancelRequested = true;
    final process = _activeProcess;
    if (process != null) {
      _terminateProcessTree(process);
    }
    return true;
  }

  Future<Object?> _runTool(Future<Object?> Function() operation) async {
    if (_toolInProgress) {
      throw StateError('Another workspace tool is already running.');
    }
    _toolInProgress = true;
    _cancelRequested = false;
    try {
      _throwIfCancelled();
      return await operation();
    } finally {
      _activeProcess = null;
      _toolInProgress = false;
      _cancelRequested = false;
    }
  }

  void _throwIfCancelled() {
    if (_cancelRequested) {
      throw StateError('Workspace tool operation cancelled.');
    }
  }

  void _requireRegularFile(File file, String displayPath) {
    if (FileSystemEntity.typeSync(file.path, followLinks: true) !=
        FileSystemEntityType.file) {
      throw FileSystemException('File not found', displayPath);
    }
  }

  void _requireWritableTarget(String path, String displayPath) {
    final type = FileSystemEntity.typeSync(path, followLinks: true);
    if (type != FileSystemEntityType.file &&
        type != FileSystemEntityType.notFound) {
      throw ArgumentError('write target must be a regular file: $displayPath');
    }
  }

  int _boundedInt(
    int value, {
    required String name,
    required int minimum,
    required int maximum,
  }) {
    if (value < minimum || value > maximum) {
      throw ArgumentError('$name must be between $minimum and $maximum.');
    }
    return value;
  }

  ({String executable, List<String> arguments}) _platformShell(String command) {
    if (Platform.isWindows) {
      final executable = Platform.environment['ComSpec'] ?? 'cmd.exe';
      return (
        executable: executable,
        arguments: <String>['/d', '/s', '/c', command],
      );
    }
    final executable = File('/bin/bash').existsSync()
        ? '/bin/bash'
        : File('/usr/bin/bash').existsSync()
        ? '/usr/bin/bash'
        : 'bash';
    return (
      executable: executable,
      arguments: <String>['--noprofile', '--norc', '-c', command],
    );
  }

  _OutputDrain _drain(
    Stream<List<int>> stream,
    _BoundedCollector collector, {
    required String streamName,
  }) {
    final completer = Completer<void>();
    final subscription = stream
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(
          collector.add,
          onError: (Object error, StackTrace stackTrace) {
            collector.add('\n[$streamName stream error: $error]');
          },
          onDone: completer.complete,
          cancelOnError: false,
        );
    return _OutputDrain(subscription, completer);
  }

  void _terminateProcessTree(Process process) {
    if (Platform.isWindows) {
      final taskkill = _windowsTaskkill();
      if (taskkill != null) {
        try {
          Process.runSync(taskkill, <String>[
            '/PID',
            '${process.pid}',
            '/T',
            '/F',
          ]);
        } catch (_) {}
      }
      process.kill();
      return;
    }

    final descendants = _descendantProcessIds(process.pid);
    process.kill(ProcessSignal.sigkill);
    for (final pid in descendants) {
      try {
        Process.killPid(pid, ProcessSignal.sigkill);
      } catch (_) {}
    }
  }

  String? _windowsTaskkill() {
    final root =
        Platform.environment['SystemRoot'] ?? Platform.environment['WINDIR'];
    if (root == null || !p.isAbsolute(root)) {
      return null;
    }
    final file = File(p.join(root, 'System32', 'taskkill.exe'));
    return file.existsSync() ? file.absolute.path : null;
  }

  List<int> _descendantProcessIds(int rootPid) {
    try {
      final ps = File('/bin/ps').existsSync() ? '/bin/ps' : '/usr/bin/ps';
      final result = Process.runSync(ps, const <String>['-axo', 'pid=,ppid=']);
      if (result.exitCode != 0 || result.stdout is! String) {
        return const <int>[];
      }
      final children = <int, List<int>>{};
      for (final line in const LineSplitter().convert(
        result.stdout as String,
      )) {
        final fields = line.trim().split(RegExp(r'\s+'));
        if (fields.length != 2) {
          continue;
        }
        final pid = int.tryParse(fields[0]);
        final parent = int.tryParse(fields[1]);
        if (pid != null && parent != null && pid > 0) {
          children.putIfAbsent(parent, () => <int>[]).add(pid);
        }
      }
      final resultPids = <int>[];
      final visited = <int>{rootPid};
      void collect(int parent) {
        for (final child in children[parent] ?? const <int>[]) {
          if (visited.add(child)) {
            collect(child);
            resultPids.add(child);
          }
        }
      }

      collect(rootPid);
      return resultPids;
    } catch (_) {
      return const <int>[];
    }
  }
}

class _OutputDrain {
  final StreamSubscription<String> _subscription;
  final Completer<void> _completer;

  _OutputDrain(this._subscription, this._completer);

  Future<void> get done => _completer.future;

  Future<void> cancel() async {
    await _subscription.cancel();
    if (!_completer.isCompleted) {
      _completer.complete();
    }
  }
}

class _BoundedCollector {
  final int limit;
  final StringBuffer _buffer = StringBuffer();
  bool truncated = false;

  _BoundedCollector(this.limit);

  void add(String chunk) {
    if (chunk.isEmpty) {
      return;
    }
    final remaining = limit - _buffer.length;
    if (remaining <= 0) {
      truncated = true;
      return;
    }
    if (chunk.length <= remaining) {
      _buffer.write(chunk);
    } else {
      _buffer.write(_safePrefix(chunk, remaining));
      truncated = true;
    }
  }

  String get value => _buffer.toString();
}

({String content, int bytes, int lineCount, bool truncated}) _boundedLines(
  List<String> lines, {
  required int startIndex,
  required int endExclusive,
  required int maxBytes,
}) {
  final buffer = StringBuffer();
  var bytes = 0;
  var lineCount = 0;
  var truncated = false;
  for (var index = startIndex; index < endExclusive; index++) {
    if (lineCount > 0) {
      if (bytes >= maxBytes) {
        truncated = true;
        break;
      }
      buffer.write('\n');
      bytes += 1;
    }
    final line = lines[index];
    final prefix = _utf8Prefix(line, maxBytes - bytes);
    buffer.write(prefix.text);
    bytes += prefix.bytes;
    lineCount += 1;
    if (prefix.truncated) {
      truncated = true;
      break;
    }
  }
  if (startIndex + lineCount < endExclusive) {
    truncated = true;
  }
  return (
    content: buffer.toString(),
    bytes: bytes,
    lineCount: lineCount,
    truncated: truncated,
  );
}

({String text, int bytes, bool truncated}) _utf8Prefix(
  String value,
  int maxBytes,
) {
  final buffer = StringBuffer();
  var bytes = 0;
  var truncated = false;
  for (final rune in value.runes) {
    final runeBytes = rune <= 0x7f
        ? 1
        : rune <= 0x7ff
        ? 2
        : rune <= 0xffff
        ? 3
        : 4;
    if (bytes + runeBytes > maxBytes) {
      truncated = true;
      break;
    }
    buffer.writeCharCode(rune);
    bytes += runeBytes;
  }
  return (text: buffer.toString(), bytes: bytes, truncated: truncated);
}

String _safePrefix(String value, int maxChars) {
  if (maxChars <= 0 || value.isEmpty) {
    return '';
  }
  if (value.length <= maxChars) {
    return value;
  }
  var end = maxChars;
  final last = value.codeUnitAt(end - 1);
  if (last >= 0xd800 && last <= 0xdbff) {
    end -= 1;
  }
  return value.substring(0, end);
}
