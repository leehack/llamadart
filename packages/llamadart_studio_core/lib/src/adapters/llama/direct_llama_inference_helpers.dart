part of 'direct_llama_inference_port.dart';

extension _DirectLlamaInferenceHelpers on DirectLlamaInferencePort {
  Future<String> _safeString(
    Future<String> Function() fn,
    String fallback,
  ) async {
    try {
      return await fn();
    } catch (_) {
      return fallback;
    }
  }

  Future<int?> _safeInt(Future<int> Function() fn) async {
    try {
      return await fn();
    } catch (_) {
      return null;
    }
  }

  Future<int?> _safeNullableInt(Future<int?> Function() fn) async {
    try {
      return await fn();
    } catch (_) {
      return null;
    }
  }

  Future<({int total, int free})> _safeVram() async {
    try {
      return await _engine.getVramInfo();
    } catch (_) {
      return (total: 0, free: 0);
    }
  }

  Future<List<GpuDeviceInfo>> _safeDevices() async {
    try {
      return await _engine.listGpuDevices();
    } catch (_) {
      return const <GpuDeviceInfo>[];
    }
  }

  Future<Map<String, String>> _safeMetadata() async {
    try {
      return await _engine.getMetadata();
    } catch (_) {
      return const <String, String>{};
    }
  }

  Future<BackendPerfContextData?> _safePerf() async {
    try {
      return await _engine.getPerformanceContext();
    } catch (_) {
      return null;
    }
  }
}

List<LlamaContentPart> _toUserPartsHelper(StudioMessage message) {
  final parts = <LlamaContentPart>[
    for (final att in message.attachments) att.toLlamaContentPart(),
    if (message.text.isNotEmpty) LlamaTextContent(message.text),
  ];
  if (parts.isEmpty) {
    return const <LlamaContentPart>[LlamaTextContent('')];
  }
  return parts;
}

Iterable<LlamaChatMessage> _toLlamaHistoryHelper(
  List<StudioMessage> history,
) sync* {
  final explicitResultIds = <String>{
    for (final message in history)
      if (!message.isError && message.role == StudioRole.tool)
        for (final call in message.toolCalls) call.id,
  };
  for (final message in history) {
    if (message.isError) continue;
    if (message.transcript.isNotEmpty) {
      for (final entry in message.transcript) {
        if (entry.role == StudioRole.tool) {
          for (final call in entry.toolCalls) {
            yield _toolResultMessageHelper(call, fallbackText: entry.text);
          }
        } else {
          yield LlamaChatMessage.withContent(
            role: LlamaChatRole.assistant,
            content: <LlamaContentPart>[
              if (entry.thinkingText != null)
                LlamaThinkingContent(entry.thinkingText!),
              if (entry.text.isNotEmpty) LlamaTextContent(entry.text),
              for (final call in entry.toolCalls)
                LlamaToolCallContent(
                  id: call.id,
                  name: call.name,
                  arguments: _decodeToolArgumentsHelper(call.argumentsJson),
                  rawJson: call.argumentsJson,
                ),
            ],
          );
        }
      }
      continue;
    }
    if (message.role == StudioRole.tool && message.toolCalls.isNotEmpty) {
      for (final call in message.toolCalls) {
        yield _toolResultMessageHelper(call, fallbackText: message.text);
      }
      continue;
    }
    if (message.role != StudioRole.assistant || message.toolCalls.isEmpty) {
      yield message.toLlamaChatMessage();
      continue;
    }
    // A saved assistant node aggregates tool rounds. Replay completed calls
    // and results together; interrupted calls have no result to replay.
    final calls = message.toolCalls
        .where(
          (call) =>
              explicitResultIds.contains(call.id) || call.resultJson != null,
        )
        .toList(growable: false);
    yield LlamaChatMessage.withContent(
      role: LlamaChatRole.assistant,
      content: <LlamaContentPart>[
        ...message.toLlamaChatMessage().parts,
        for (final call in calls)
          LlamaToolCallContent(
            id: call.id,
            name: call.name,
            arguments: _decodeToolArgumentsHelper(call.argumentsJson),
            rawJson: call.argumentsJson,
          ),
      ],
    );
    for (final call in calls) {
      if (!explicitResultIds.contains(call.id)) {
        yield _toolResultMessageHelper(call);
      }
    }
  }
}

StudioTurnTranscriptEntry _toStudioTranscriptEntryHelper(
  LlamaChatMessage message,
) => StudioTurnTranscriptEntry(
  role: message.role == LlamaChatRole.tool
      ? StudioRole.tool
      : StudioRole.assistant,
  text: message.parts.whereType<LlamaTextContent>().map((p) => p.text).join(),
  thinkingText: message.reasoning,
  toolCalls: <StudioToolInvocation>[
    for (final part in message.parts)
      if (part is LlamaToolCallContent)
        StudioToolInvocation(
          id: part.id ?? '',
          name: part.name,
          argumentsJson: jsonEncode(part.arguments),
        )
      else if (part is LlamaToolResultContent)
        StudioToolInvocation(
          id: part.id ?? '',
          name: part.name,
          argumentsJson: '{}',
          resultJson: _encodeToolOutputHelper(part.result),
        ),
  ],
);

LlamaChatMessage _toolResultMessageHelper(
  StudioToolInvocation call, {
  String fallbackText = '',
}) {
  final raw = call.resultJson ?? fallbackText;
  Object? result;
  try {
    result = jsonDecode(raw);
  } catch (_) {
    result = raw;
  }
  return LlamaChatMessage.withContent(
    role: LlamaChatRole.tool,
    content: <LlamaContentPart>[
      LlamaToolResultContent(id: call.id, name: call.name, result: result),
    ],
  );
}

ToolDefinition? _findToolHelper(List<ToolDefinition> tools, String name) {
  for (final tool in tools) {
    if (tool.name == name) {
      return tool;
    }
  }
  return null;
}

ToolDefinition _toolDispatchValidatorHelper(ToolDefinition tool) {
  final schema = tool.toJsonSchema();
  if (!schema.containsKey('additionalProperties')) {
    // ToolParam schemas use closed objects, unlike JSON Schema's open default.
    // Preserve that existing contract when asking the canonical validator to
    // validate an emitted call, without exposing a canonical tool to templates.
    _closeLegacyObjectSchemasHelper(schema);
  }
  return ToolDefinition.fromJsonSchema(
    name: tool.name,
    description: tool.description,
    schema: schema,
    handler: (params) => tool.invoke(params.raw),
  );
}

void _closeLegacyObjectSchemasHelper(Map<String, dynamic> schema) {
  if (schema['type'] == 'object') {
    schema.putIfAbsent('additionalProperties', () => false);
    final properties = schema['properties'];
    if (properties is Map) {
      for (final property in properties.values) {
        if (property is Map<String, dynamic>) {
          _closeLegacyObjectSchemasHelper(property);
        }
      }
    }
  }
  final items = schema['items'];
  if (items is Map<String, dynamic>) {
    _closeLegacyObjectSchemasHelper(items);
  }
}

Map<String, dynamic>? _buildThinkingTemplateKwargsHelper({
  required StudioSettings settings,
  required LlamaEngineCapabilities capabilities,
  int? effectiveBudgetTokens,
}) {
  if (capabilities.runtime == LlamaRuntime.liteRtLm &&
      settings.thinkingEnabled &&
      settings.thinkingBudgetTokens <= 0) {
    return null;
  }
  final budget = settings.thinkingBudgetTokens > 0
      ? settings.thinkingBudgetTokens
      : effectiveBudgetTokens;
  if (settings.thinkingEnabled && (budget == null || budget <= 0)) {
    return null;
  }
  final kwargs = <String, dynamic>{
    'enable_thinking': settings.thinkingEnabled,
    'thinking': settings.thinkingEnabled,
    'reasoning': settings.thinkingEnabled,
  };
  if (settings.thinkingEnabled && budget != null && budget > 0) {
    kwargs['thinking_budget'] = budget;
    kwargs['reasoning_budget'] = budget;
    kwargs['max_thinking_tokens'] = budget;
  }
  return kwargs;
}

Map<String, dynamic> _decodeToolArgumentsHelper(String rawArgsText) {
  final trimmed = rawArgsText.trim();
  if (trimmed.isEmpty) {
    return <String, dynamic>{};
  }
  try {
    final decoded = jsonDecode(trimmed);
    if (decoded is Map) {
      return Map<String, dynamic>.from(decoded);
    }
  } catch (_) {
    // Fall back to wrapping raw string.
  }
  return <String, dynamic>{'raw': trimmed};
}

String _prettyJsonHelper(Map<String, dynamic> map) {
  try {
    return const JsonEncoder.withIndent('  ').convert(map);
  } catch (_) {
    return map.toString();
  }
}

String _encodeToolOutputHelper(Object? value) {
  try {
    return const JsonEncoder.withIndent('  ').convert(value);
  } catch (_) {
    return value?.toString() ?? 'null';
  }
}

Map<String, String> _selectDisplayMetadataHelper(Map<String, String> raw) {
  const preferredKeys = <String>[
    'general.architecture',
    'general.name',
    'general.quantization_version',
    'general.size_label',
    'tokenizer.ggml.model',
  ];
  final picked = <String, String>{};
  for (final key in preferredKeys) {
    final value = raw[key];
    if (value != null && value.isNotEmpty) {
      picked[key] = value;
    }
  }
  for (final entry in raw.entries) {
    if (picked.length >= 12) {
      break;
    }
    if (entry.key.endsWith('.context_length') ||
        entry.key.endsWith('.embedding_length') ||
        entry.key.endsWith('.block_count') ||
        entry.key.endsWith('.head_count')) {
      picked[entry.key] = entry.value;
    }
  }
  return picked;
}

List<ToolDefinition> _mergeToolDefinitionsHelper(
  List<ToolDefinition> base,
  List<ToolDefinition> extra,
) {
  if (extra.isEmpty) {
    return base;
  }
  final byName = <String, ToolDefinition>{
    for (final tool in base) tool.name: tool,
    for (final tool in extra) tool.name: tool,
  };
  return byName.values.toList(growable: false);
}
