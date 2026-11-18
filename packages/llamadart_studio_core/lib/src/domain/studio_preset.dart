import 'package:meta/meta.dart';

/// Reusable persona, system prompt, sampling, and structured-output preset.
@immutable
class StudioPreset {
  /// Creates a [StudioPreset].
  const StudioPreset({
    required this.id,
    required this.name,
    required this.description,
    required this.systemPrompt,
    this.temperature = 0.7,
    this.thinkingEnabled = true,
    this.toolsEnabled = false,
    this.jsonSchema,
    this.starterPrompt,
    this.isBuiltIn = false,
  });

  /// Stable identifier for persistence and selection.
  final String id;

  /// Display title shown in preset pickers and inspector badges.
  final String name;

  /// One-line summary of what this preset optimizes for.
  final String description;

  /// System instruction injected at the root of the session.
  final String systemPrompt;

  /// Recommended sampling temperature.
  final double temperature;

  /// Whether chain-of-thought reasoning should be enabled when supported.
  final bool thinkingEnabled;

  /// Whether built-in/custom tool declarations should be active.
  final bool toolsEnabled;

  /// Optional JSON Schema string enforcing grammar-constrained JSON output.
  final String? jsonSchema;

  /// Optional sample user prompt to help try the preset immediately.
  final String? starterPrompt;

  /// Whether this preset ships with `llamadart Studio` and cannot be deleted.
  final bool isBuiltIn;

  /// Built-in presets showcasing `llamadart` capabilities.
  static const List<StudioPreset> builtInPresets = <StudioPreset>[
    StudioPreset(
      id: 'concise_assistant',
      name: 'Concise Assistant',
      description: 'Direct, grounded answers with clean formatting.',
      systemPrompt:
          'You are a concise, accurate local AI assistant running on llamadart. '
          'Lead with the answer, avoid filler, and format code clearly.',
      temperature: 0.6,
      thinkingEnabled: true,
      isBuiltIn: true,
      starterPrompt:
          'Explain how KV-cache quantization saves memory during local LLM inference in 4 bullet points.',
    ),
    StudioPreset(
      id: 'tool_agent',
      name: 'Tool-Calling Agent',
      description: 'Uses local functions for weather, math, units, and time.',
      systemPrompt:
          'You are a helpful tool-using assistant. Call the provided tools '
          'whenever factual lookup, unit conversion, or calculation is needed, '
          'then summarize the result clearly.',
      temperature: 0.3,
      thinkingEnabled: true,
      toolsEnabled: true,
      isBuiltIn: true,
      starterPrompt:
          'Check the weather in Seoul and Tokyo, convert both temperatures to Fahrenheit, and compare them.',
    ),
    StudioPreset(
      id: 'json_extractor',
      name: 'Structured JSON Extractor',
      description: 'Grammar-constrained output matching a strict JSON Schema.',
      systemPrompt:
          'Extract structured information that strictly conforms to the '
          'active JSON Schema. Output valid JSON only.',
      temperature: 0.1,
      thinkingEnabled: false,
      jsonSchema: '''{
  "type": "object",
  "required": ["summary", "sentiment", "actionItems"],
  "properties": {
    "summary": { "type": "string" },
    "sentiment": { "type": "string", "enum": ["positive", "neutral", "negative"] },
    "actionItems": {
      "type": "array",
      "items": { "type": "string" }
    }
  }
}''',
      isBuiltIn: true,
      starterPrompt:
          'Release 0.17 shipped Metal FlashAttention and cut TTFT by 38%. Next week we need to benchmark Android Vulkan and publish migration docs.',
    ),
    StudioPreset(
      id: 'deep_reasoner',
      name: 'Deep Reasoner',
      description: 'Step-by-step chain-of-thought for logic, math, and code.',
      systemPrompt:
          'Think carefully through edge cases before answering. Verify '
          'intermediate steps and present a clear final solution.',
      temperature: 0.5,
      thinkingEnabled: true,
      isBuiltIn: true,
      starterPrompt:
          'Design a lock-free ring buffer in Dart for single-producer single-consumer audio samples and explain why index wrap-around is safe.',
    ),
  ];

  /// Returns a copy with selectively updated fields.
  StudioPreset copyWith({
    String? id,
    String? name,
    String? description,
    String? systemPrompt,
    double? temperature,
    bool? thinkingEnabled,
    bool? toolsEnabled,
    String? jsonSchema,
    bool clearJsonSchema = false,
    String? starterPrompt,
    bool clearStarterPrompt = false,
    bool? isBuiltIn,
  }) {
    return StudioPreset(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      systemPrompt: systemPrompt ?? this.systemPrompt,
      temperature: temperature ?? this.temperature,
      thinkingEnabled: thinkingEnabled ?? this.thinkingEnabled,
      toolsEnabled: toolsEnabled ?? this.toolsEnabled,
      jsonSchema: clearJsonSchema ? null : (jsonSchema ?? this.jsonSchema),
      starterPrompt: clearStarterPrompt
          ? null
          : (starterPrompt ?? this.starterPrompt),
      isBuiltIn: isBuiltIn ?? this.isBuiltIn,
    );
  }

  /// Serializes this preset to a JSON map.
  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'name': name,
      'description': description,
      'systemPrompt': systemPrompt,
      'temperature': temperature,
      'thinkingEnabled': thinkingEnabled,
      'toolsEnabled': toolsEnabled,
      if (jsonSchema != null) 'jsonSchema': jsonSchema,
      if (starterPrompt != null) 'starterPrompt': starterPrompt,
      'isBuiltIn': isBuiltIn,
    };
  }

  /// Restores a [StudioPreset] from a JSON map.
  factory StudioPreset.fromJson(Map<String, Object?> json) {
    return StudioPreset(
      id: (json['id'] as String?) ?? 'custom',
      name: (json['name'] as String?) ?? 'Custom Preset',
      description: (json['description'] as String?) ?? '',
      systemPrompt: (json['systemPrompt'] as String?) ?? '',
      temperature: (json['temperature'] as num?)?.toDouble() ?? 0.7,
      thinkingEnabled: (json['thinkingEnabled'] as bool?) ?? true,
      toolsEnabled: (json['toolsEnabled'] as bool?) ?? false,
      jsonSchema: json['jsonSchema'] as String?,
      starterPrompt: json['starterPrompt'] as String?,
      isBuiltIn: (json['isBuiltIn'] as bool?) ?? false,
    );
  }
}
