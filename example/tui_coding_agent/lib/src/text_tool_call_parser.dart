import 'dart:convert';

/// A validated tool call emitted through the text protocol.
class TextToolCall {
  /// Tool name.
  final String name;

  /// JSON object passed to the tool.
  final Map<String, dynamic> arguments;

  TextToolCall({required this.name, required Map<String, dynamic> arguments})
    : arguments = Map<String, dynamic>.unmodifiable(arguments);
}

/// Result of parsing one assistant response.
class TextToolCallParseResult {
  /// The single executable call, when the response is valid.
  final TextToolCall? call;

  /// Whether the response contained a tool-call protocol marker.
  final bool hasToolCallEnvelope;

  /// A concise protocol diagnostic, or `null` for a normal response.
  final String? error;

  const TextToolCallParseResult({
    required this.call,
    required this.hasToolCallEnvelope,
    required this.error,
  });

  /// Whether parsing found a non-executable protocol attempt.
  bool get hasError => error != null;
}

/// Parses one strict JSON tool-call envelope.
///
/// The only executable form is:
///
/// ```text
/// <tool_call>{"name":"tool_name","arguments":{}}</tool_call>
/// ```
///
/// The envelope must be the entire response. The scanner recognizes closing
/// tags only outside JSON strings, so source text containing `<tool_call>` or
/// `</tool_call>` remains ordinary argument data.
class TextToolCallParser {
  static const String _openTag = '<tool_call>';
  static const String _closeTag = '</tool_call>';
  static const String _openMarker = '<tool_call';
  static const String _closeMarker = '</tool_call';

  final Set<String> _knownToolNames;

  TextToolCallParser({required Set<String> knownToolNames})
    : _knownToolNames = Set<String>.unmodifiable(knownToolNames);

  /// Parses [content] without interpreting protocol-like prose as a tool call.
  TextToolCallParseResult parse(String content) {
    final hasEnvelope =
        content.contains(_openMarker) || content.contains(_closeMarker);
    if (!hasEnvelope) {
      return const TextToolCallParseResult(
        call: null,
        hasToolCallEnvelope: false,
        error: null,
      );
    }

    final response = content.trim();
    if (!response.startsWith(_openTag)) {
      return _error('Tool call must be the entire response.');
    }

    final scan = _scanEnvelope(response);
    if (scan.error != null) {
      return _error(scan.error!);
    }

    final suffix = response.substring(scan.end).trim();
    if (suffix.isNotEmpty) {
      if (suffix.contains(_openMarker)) {
        return _error('Only one tool call is allowed per response.');
      }
      return _error('Tool call must be the entire response.');
    }

    return _parsePayload(scan.payload);
  }

  _EnvelopeScan _scanEnvelope(String response) {
    var inString = false;
    var escaping = false;

    for (var index = _openTag.length; index < response.length; index++) {
      final codeUnit = response.codeUnitAt(index);
      if (inString) {
        if (escaping) {
          escaping = false;
        } else if (codeUnit == 0x5c) {
          escaping = true;
        } else if (codeUnit == 0x22) {
          inString = false;
        }
        continue;
      }

      if (codeUnit == 0x22) {
        inString = true;
        continue;
      }
      if (response.startsWith(_openTag, index)) {
        return const _EnvelopeScan.error(
          'Only one tool call is allowed per response.',
        );
      }
      if (response.startsWith(_closeTag, index)) {
        return _EnvelopeScan.complete(
          payload: response.substring(_openTag.length, index),
          end: index + _closeTag.length,
        );
      }
    }

    return const _EnvelopeScan.error('Incomplete tool-call envelope.');
  }

  TextToolCallParseResult _parsePayload(String payload) {
    Object? decoded;
    try {
      decoded = jsonDecode(payload);
    } on FormatException {
      return _error('Tool-call payload must be valid JSON.');
    }

    if (decoded is! Map<String, dynamic> ||
        decoded.length != 2 ||
        !decoded.containsKey('name') ||
        !decoded.containsKey('arguments')) {
      return _error('Tool-call payload must contain only name and arguments.');
    }

    final name = decoded['name'];
    final arguments = decoded['arguments'];
    if (name is! String || name.isEmpty || arguments is! Map<String, dynamic>) {
      return _error('Tool-call name must be text and arguments an object.');
    }
    if (!_knownToolNames.contains(name)) {
      return _error('Unknown tool "$name".');
    }

    return TextToolCallParseResult(
      call: TextToolCall(name: name, arguments: arguments),
      hasToolCallEnvelope: true,
      error: null,
    );
  }

  TextToolCallParseResult _error(String message) {
    return TextToolCallParseResult(
      call: null,
      hasToolCallEnvelope: true,
      error: message,
    );
  }
}

class _EnvelopeScan {
  final String payload;
  final int end;
  final String? error;

  const _EnvelopeScan.complete({required this.payload, required this.end})
    : error = null;

  const _EnvelopeScan.error(this.error) : payload = '', end = 0;
}
