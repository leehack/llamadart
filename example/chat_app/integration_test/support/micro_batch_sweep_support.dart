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
// A device name is free text and may hold a quote, so it ends at the quote
// that the version list follows.
final _capDevice = RegExp(
  r'"(.*?)" \(API (\d+\.\d+), loader (\d+\.\d+), subgroup size (\d+)\)',
  dotAll: true,
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

/// What is known about the Android Vulkan text prompt cap of one context.
enum PromptCapState {
  /// The library logged that it caps the prompt decode.
  capped('capped'),

  /// The library logged that it leaves the prompt decode uncapped.
  notCapped('not_capped'),

  /// An explicit micro-batch size, which makes the library leave the cap off
  /// without logging.
  explicitSize('explicit_size'),

  /// A platform other than Android, where there is no cap.
  notAndroid('not_android'),

  /// An Android load that asks Vulkan for no GPU layer, which gets no cap.
  vulkanNotRequested('vulkan_not_requested'),

  /// An Android load that asks Vulkan for GPU layers while ggml-vulkan
  /// registered no device. The library logs nothing and applies the cap all
  /// the same, although the context runs on the CPU.
  noVulkanDevice('no_vulkan_device'),

  /// A Vulkan device is registered and the cap was to be decided, but no
  /// decision reached the log: the record is missing.
  notLogged('not_logged');

  const PromptCapState(this.wireName);

  /// The value the journal carries.
  final String wireName;
}

/// The state of the prompt cap for a context created with [microBatchSize]
/// (0 for the library default), from the library's [logged] decision when it
/// logged one and otherwise from what the load reported.
///
/// [vulkanRequested] is whether the load prefers Vulkan and kept a positive
/// GPU layer count. [registeredVulkanDevices] is the number of Vulkan devices
/// the runtime lists, or null when it cannot be read.
PromptCapState promptCapState({
  required PromptCapDecision? logged,
  required int microBatchSize,
  required bool isAndroid,
  required bool vulkanRequested,
  required int? registeredVulkanDevices,
}) {
  if (logged != null) {
    return logged.capTokens == null
        ? PromptCapState.notCapped
        : PromptCapState.capped;
  }
  if (microBatchSize > 0) return PromptCapState.explicitSize;
  if (!isAndroid) return PromptCapState.notAndroid;
  if (!vulkanRequested) return PromptCapState.vulkanNotRequested;
  if (registeredVulkanDevices == 0) return PromptCapState.noVulkanDevice;
  return PromptCapState.notLogged;
}

/// Whether [content] is one of [codes] and nothing else: surrounding
/// whitespace, letter case and one closing `.` or `!` are ignored.
bool answerIsCode(String content, Iterable<String> codes) {
  final answer = content.trim().toLowerCase().replaceFirst(
    RegExp(r'[.!]$'),
    '',
  );
  return codes.any((code) => code.toLowerCase() == answer);
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

/// Whether a request that ended with [finishReasons] and the tool [call] is
/// exactly one call of [name] with [arguments].
bool toolCallMatches({
  required Object? finishReasons,
  required ({String name, Object? arguments, bool wellFormed}) call,
  required String name,
  required Object? arguments,
}) =>
    jsonEncode(finishReasons) == jsonEncode(['tool_calls']) &&
    call.wellFormed &&
    call.name == name &&
    _canonical(call.arguments) == _canonical(arguments);

/// JSON text of [value] with the keys of every object in order.
String _canonical(Object? value) => jsonEncode(_sorted(value));

Object? _sorted(Object? value) => switch (value) {
  final Map<Object?, Object?> map => {
    for (final key in map.keys.map((key) => '$key').toList()..sort())
      key: _sorted(map[key]),
  },
  final List<Object?> list => [for (final item in list) _sorted(item)],
  _ => value,
};

/// How one judged request ended: whether it [passed], and what to print when
/// it did not.
typedef JudgedCase = ({bool passed, String description});

/// The verdict of one attempt at the judged size.
///
/// It passes when the load succeeded ([loadError] is null) and every case in
/// [judgedCases] has a passing entry in [results]. `cases` holds the verdict
/// of each judged case, false for one that never ran.
({bool passed, Map<String, bool> cases, List<String> failures}) judgeAttempt(
  Iterable<String> judgedCases,
  Map<String, JudgedCase> results, {
  String? loadError,
}) {
  final failures = <String>[];
  if (loadError != null) {
    failures.add('did not load: $loadError');
  } else {
    for (final id in judgedCases) {
      final result = results[id];
      if (result == null) {
        failures.add('$id did not run');
      } else if (!result.passed) {
        failures.add('$id ${result.description}');
      }
    }
  }
  return (
    passed: failures.isEmpty,
    cases: {for (final id in judgedCases) id: results[id]?.passed ?? false},
    failures: failures,
  );
}

/// The attempts of a sweep over [arms] and [repeats], in running order: every
/// repeat of the [judgedArm] first, so that nothing a control arm does to the
/// process can cost a judged repeat, then the control arms repeat by repeat.
List<({int repeat, int arm})> sweepOrder(
  List<int> arms,
  int repeats, {
  required int judgedArm,
}) => [
  for (var repeat = 1; repeat <= repeats; repeat++)
    (repeat: repeat, arm: judgedArm),
  for (var repeat = 1; repeat <= repeats; repeat++)
    for (final arm in arms)
      if (arm != judgedArm) (repeat: repeat, arm: arm),
];
