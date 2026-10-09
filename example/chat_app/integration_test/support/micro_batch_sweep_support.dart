import 'dart:convert';

/// One Vulkan device as the prompt cap log line of llamadart describes it.
typedef PromptCapDevice = ({
  String name,
  String apiVersion,
  String loaderApiVersion,
  int subgroupSize,
});

/// What llamadart logged about the Android Vulkan text prompt cap when it
/// created a context.
///
/// [capTokens] is the most prompt tokens one decode call takes, or null when
/// the cap is lifted. [devices] are the Vulkan devices the decision was made
/// from; when the probe could not list them, [detail] holds its reason.
typedef PromptCapDecision = ({
  int? capTokens,
  List<PromptCapDevice> devices,
  String detail,
});

final _capLine = RegExp(
  r'Android Vulkan text prompt decode is '
  r'(?:capped at (\d+) tokens per call|not capped) \((.*)\)',
  dotAll: true,
);
final _capDevice = RegExp(
  r'"([^"]*)" \(API (\d+\.\d+), loader (\d+\.\d+), subgroup size (\d+)\)',
);

/// The decision in a `LlamaLogger` debug [message], or null when the message
/// is not the prompt cap line.
PromptCapDecision? parsePromptCapDecision(String message) {
  final match = _capLine.firstMatch(message);
  if (match == null) return null;
  final cap = match[1];
  final detail = match[2]!;
  return (
    capTokens: cap == null ? null : int.parse(cap),
    devices: [
      for (final device in _capDevice.allMatches(detail))
        (
          name: device[1]!,
          apiVersion: device[2]!,
          loaderApiVersion: device[3]!,
          subgroupSize: int.parse(device[4]!),
        ),
    ],
    detail: detail,
  );
}

/// The tool call that streamed tool-call [deltas] add up to: the
/// concatenated name and the decoded arguments. `arguments` is null when the
/// argument text is not JSON, and `wellFormed` is false then, when there are
/// no deltas, and when the deltas name more than one call.
({String name, Object? arguments, bool wellFormed}) reconstructToolCall(
  List<Object?> deltas,
) {
  final name = StringBuffer();
  final arguments = StringBuffer();
  var wellFormed = deltas.isNotEmpty;
  String? id;
  for (final delta in deltas.cast<Map<Object?, Object?>>()) {
    if (delta['index'] != 0) wellFormed = false;
    if (delta['id'] case final String next) {
      if (id != null && id != next) wellFormed = false;
      id = next;
    }
    final function = delta['function'] as Map<Object?, Object?>?;
    name.write(function?['name'] ?? '');
    arguments.write(function?['arguments'] ?? '');
  }
  Object? decoded;
  try {
    decoded = jsonDecode(arguments.toString());
  } on FormatException {
    wellFormed = false;
  }
  return (name: name.toString(), arguments: decoded, wellFormed: wellFormed);
}
