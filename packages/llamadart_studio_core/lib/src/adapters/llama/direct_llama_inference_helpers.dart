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

LlamaChatMessage _toLlamaMessageHelper(StudioMessage message) {
  final role = switch (message.role) {
    StudioRole.system => LlamaChatRole.system,
    StudioRole.user => LlamaChatRole.user,
    StudioRole.assistant => LlamaChatRole.assistant,
    StudioRole.tool => LlamaChatRole.tool,
  };
  if (role == LlamaChatRole.user && message.attachments.isNotEmpty) {
    return LlamaChatMessage.withContent(
      role: role,
      content: _toUserPartsHelper(message),
    );
  }
  return LlamaChatMessage.fromText(role: role, text: message.text);
}

ToolDefinition? _findToolHelper(List<ToolDefinition> tools, String name) {
  for (final tool in tools) {
    if (tool.name == name) {
      return tool;
    }
  }
  return null;
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
