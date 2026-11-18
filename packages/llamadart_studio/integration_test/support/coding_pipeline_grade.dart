import 'dart:convert';

/// One completed tool invocation as the Coding acceptance harness saw it.
class GradedToolCall {
  const GradedToolCall({
    required this.name,
    required this.arguments,
    required this.result,
    required this.succeeded,
  });

  final String name;
  final Map<String, dynamic> arguments;
  final Map<String, dynamic>? result;
  final bool succeeded;
}

/// Reads the bytes of a workspace-relative path, or null when it is absent.
typedef WorkspaceDiskReader = List<int>? Function(String relativePath);

/// Pipeline verdict for one Coding turn, with model-fidelity reported apart.
///
/// [failures] hold only pipeline-invariant violations. Whether the model
/// emitted the exact requested path and content is evidence, never a failure.
class CodingPipelineGrade {
  const CodingPipelineGrade({
    required this.failures,
    required this.path,
    required this.pathExact,
    required this.contentExact,
  });

  final List<String> failures;
  final String? path;
  final bool pathExact;
  final bool contentExact;

  bool get pipelinePass => failures.isEmpty;
  bool get fidelity => pathExact && contentExact;

  Map<String, Object?> toJson() => {
    'pipeline_pass': pipelinePass,
    'failures': failures,
    'path': path,
    'path_exact': pathExact,
    'content_exact': contentExact,
    'fidelity': fidelity,
  };
}

/// The numbered view the `read` tool returns for [text].
String numberedView(String text) {
  final lines = text.split('\n');
  return [for (var i = 0; i < lines.length; i++) '${i + 1}: ${lines[i]}']
      .join('\n')
      .trimRight();
}

/// Grades the last successful `write` and a later successful `read`.
///
/// The write passes when the bytes on disk at its result path equal the UTF-8
/// of the content the model dispatched; the read passes when its content equals
/// the numbered view of the disk file.
CodingPipelineGrade gradeWriteAndRead({
  required List<GradedToolCall> calls,
  required String expectedPath,
  required String expectedContent,
  required WorkspaceDiskReader readDisk,
}) {
  final failures = <String>[];
  final writeIndex = calls.lastIndexWhere(
    (c) => c.name == 'write' && c.succeeded,
  );
  if (writeIndex < 0) {
    return const CodingPipelineGrade(
      failures: ['no successful write'],
      path: null,
      pathExact: false,
      contentExact: false,
    );
  }
  final write = calls[writeIndex];
  final path = write.result?['path'];
  final content = write.arguments['content'];
  final pathExact = path == expectedPath;
  final contentExact = content == expectedContent;
  if (path is! String || path.isEmpty) {
    failures.add('write result has no path');
  } else if (content is! String) {
    failures.add('write dispatched no string content');
  } else {
    final disk = readDisk(path);
    if (disk == null) {
      failures.add('written file missing on disk: $path');
    } else if (!_sameBytes(disk, utf8.encode(content))) {
      failures.add('disk bytes differ from dispatched content: $path');
    }
  }
  _gradeLaterRead(calls, writeIndex, readDisk, failures);
  return CodingPipelineGrade(
    failures: failures,
    path: path is String ? path : null,
    pathExact: pathExact,
    contentExact: contentExact,
  );
}

/// Grades the last successful `edit` against [preEditBytes] and a later read.
///
/// The edit passes when the disk file at its result path equals
/// [preEditBytes] with the dispatched find/replace applied.
CodingPipelineGrade gradeEditAndRead({
  required List<GradedToolCall> calls,
  required String expectedPath,
  required String expectedFindText,
  required String expectedReplaceText,
  required List<int> preEditBytes,
  required WorkspaceDiskReader readDisk,
}) {
  final failures = <String>[];
  final editIndex = calls.lastIndexWhere(
    (c) => c.name == 'edit' && c.succeeded,
  );
  if (editIndex < 0) {
    return const CodingPipelineGrade(
      failures: ['no successful edit'],
      path: null,
      pathExact: false,
      contentExact: false,
    );
  }
  final edit = calls[editIndex];
  final path = edit.result?['path'];
  final find = edit.arguments['findText'];
  final replace = edit.arguments['replaceText'];
  final replaceAll = edit.arguments['replaceAll'] == true;
  if (path is! String || path.isEmpty) {
    failures.add('edit result has no path');
  } else if (find is! String || find.isEmpty || replace is! String) {
    failures.add('edit dispatched no find/replace strings');
  } else {
    final before = utf8.decode(preEditBytes, allowMalformed: true);
    final expected = replaceAll
        ? before.replaceAll(find, replace)
        : before.replaceFirst(find, replace);
    final disk = readDisk(path);
    if (disk == null) {
      failures.add('edited file missing on disk: $path');
    } else if (!_sameBytes(disk, utf8.encode(expected))) {
      failures.add('disk bytes differ from pre-edit bytes with edit applied');
    }
  }
  _gradeLaterRead(calls, editIndex, readDisk, failures);
  return CodingPipelineGrade(
    failures: failures,
    path: path is String ? path : null,
    pathExact: path == expectedPath,
    contentExact: find == expectedFindText && replace == expectedReplaceText,
  );
}

void _gradeLaterRead(
  List<GradedToolCall> calls,
  int afterIndex,
  WorkspaceDiskReader readDisk,
  List<String> failures,
) {
  final readIndex = calls.lastIndexWhere(
    (c) => c.name == 'read' && c.succeeded,
  );
  if (readIndex <= afterIndex) {
    failures.add('no successful read after the mutation');
    return;
  }
  final result = calls[readIndex].result;
  final path = result?['path'];
  final disk = path is String ? readDisk(path) : null;
  if (disk == null) {
    failures.add('read path missing on disk: $path');
  } else if (result!['content'] != numberedView(utf8.decode(disk))) {
    failures.add('read content differs from numbered view of disk');
  } else if (result['truncated'] == true) {
    failures.add('read result truncated');
  }
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
