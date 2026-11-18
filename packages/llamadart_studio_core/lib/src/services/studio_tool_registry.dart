import 'dart:convert';
import 'dart:math' as math;

import 'package:llamadart/llamadart.dart';
import 'package:meta/meta.dart';

/// Metadata for a built-in Studio tool shown in the Session Inspector.
@immutable
class BuiltInToolSpec {
  /// Creates a [BuiltInToolSpec].
  const BuiltInToolSpec({
    required this.name,
    required this.title,
    required this.description,
    required this.definition,
  });

  /// Canonical function name.
  final String name;

  /// Short UI label.
  final String title;

  /// Human-readable description.
  final String description;

  /// Executable `llamadart` [ToolDefinition].
  final ToolDefinition definition;
}

/// Extensible tool registry contract for resolving active chat/agent tools.
abstract interface class StudioToolCatalog {
  /// Returns all registered [BuiltInToolSpec]s.
  List<BuiltInToolSpec> get availableTools;

  /// Resolves active [ToolDefinition]s from [enabledNames] and optional
  /// [customDeclarationsJson].
  List<ToolDefinition> resolveTools({
    required Iterable<String> enabledNames,
    String customDeclarationsJson = '[]',
  });
}

/// Pure-Dart registry providing deterministic local demo tools and parsing
/// OpenAI-compatible JSON custom tool declarations.
///
/// Can be instantiated with [extraTools] or extended via [registerTool] without
/// modifying [builtInTools] (Open/Closed Principle).
class StudioToolRegistry implements StudioToolCatalog {
  /// Creates an extensible [StudioToolRegistry] pre-seeded with [baseTools]
  /// (defaults to [builtInTools]) plus optional [extraTools].
  StudioToolRegistry({
    List<BuiltInToolSpec>? baseTools,
    List<BuiltInToolSpec> extraTools = const <BuiltInToolSpec>[],
  }) : _specs = <BuiltInToolSpec>[
         ...(baseTools ?? builtInTools),
         ...extraTools,
       ];

  final List<BuiltInToolSpec> _specs;

  /// Registers an additional [BuiltInToolSpec] at runtime (replacing any prior
  /// spec with the same name).
  void registerTool(BuiltInToolSpec spec) {
    _specs.removeWhere(
      (BuiltInToolSpec existing) => existing.name == spec.name,
    );
    _specs.add(spec);
  }

  @override
  List<BuiltInToolSpec> get availableTools =>
      List<BuiltInToolSpec>.unmodifiable(_specs);

  @override
  List<ToolDefinition> resolveTools({
    required Iterable<String> enabledNames,
    String customDeclarationsJson = '[]',
  }) {
    final enabledSet = enabledNames.toSet();
    final resolved = <ToolDefinition>[
      for (final spec in _specs)
        if (enabledSet.contains(spec.name)) spec.definition,
    ];
    final trimmed = customDeclarationsJson.trim();
    if (trimmed.isNotEmpty && trimmed != '[]') {
      resolved.addAll(parseCustomDeclarations(trimmed));
    }
    return resolved;
  }

  /// All built-in tools shipped with `llamadart Studio`.
  static final List<BuiltInToolSpec> builtInTools = <BuiltInToolSpec>[
    BuiltInToolSpec(
      name: 'getCurrentTime',
      title: 'Clock & Timezone',
      description: 'Returns the current ISO-8601 timestamp and UTC offset.',
      definition: ToolDefinition(
        name: 'getCurrentTime',
        description:
            'Get the current local or UTC date and time in ISO-8601 format.',
        parameters: <ToolParam>[
          ToolParam.enumType(
            'zone',
            values: const <String>['local', 'utc'],
            description: 'Whether to return local time or UTC time.',
          ),
        ],
        handler: (ToolParams params) async {
          final zone = params.getString('zone') ?? 'local';
          final now = zone == 'utc' ? DateTime.now().toUtc() : DateTime.now();
          return <String, Object?>{
            'iso8601': now.toIso8601String(),
            'timeZoneName': now.timeZoneName,
            'utcOffsetMinutes': now.timeZoneOffset.inMinutes,
            'weekday': _weekdayName(now.weekday),
          };
        },
      ),
    ),
    BuiltInToolSpec(
      name: 'getWeather',
      title: 'Weather Lookup',
      description: 'Deterministic local weather simulator for tool demos.',
      definition: ToolDefinition(
        name: 'getWeather',
        description:
            'Get current weather conditions and temperature for a city.',
        parameters: <ToolParam>[
          ToolParam.string(
            'city',
            description: 'City name, for example "Seoul" or "San Francisco".',
            required: true,
          ),
          ToolParam.enumType(
            'unit',
            values: const <String>['celsius', 'fahrenheit'],
            description: 'Temperature unit.',
          ),
        ],
        handler: (ToolParams params) async {
          final city = params.getString('city')?.trim();
          if (city == null || city.isEmpty) {
            return <String, Object?>{'error': 'Missing required city name.'};
          }
          final unit = params.getString('unit') ?? 'celsius';
          final seed = city.toLowerCase().codeUnits.fold<int>(
            17,
            (int acc, int code) => (acc * 31 + code) & 0x7fffffff,
          );
          const conditions = <String>[
            'Clear sky',
            'Partly cloudy',
            'Light breeze',
            'Crisp & sunny',
            'Scattered clouds',
          ];
          final celsius = 11 + (seed % 18);
          final temp = unit == 'fahrenheit'
              ? ((celsius * 9 / 5) + 32).round()
              : celsius;
          return <String, Object?>{
            'city': city,
            'temperature': temp,
            'unit': unit,
            'condition': conditions[seed % conditions.length],
            'humidityPercent': 42 + (seed % 38),
          };
        },
      ),
    ),
    BuiltInToolSpec(
      name: 'evaluateMath',
      title: 'Math Evaluator',
      description:
          'Safe recursive-descent arithmetic & scientific expression solver.',
      definition: ToolDefinition(
        name: 'evaluateMath',
        description:
            'Evaluate a mathematical expression (+, -, *, /, ^, parentheses, '
            'sqrt, sin, cos, tan, log, pi, e).',
        parameters: <ToolParam>[
          ToolParam.string(
            'expression',
            description:
                'Arithmetic expression such as "(18.5 * 4) + sqrt(81)".',
            required: true,
          ),
        ],
        handler: (ToolParams params) async {
          final expr = params.getString('expression') ?? '';
          final value = evaluateExpression(expr);
          return <String, Object?>{'expression': expr, 'result': value};
        },
      ),
    ),
    BuiltInToolSpec(
      name: 'convertUnits',
      title: 'Unit Converter',
      description: 'Converts length, mass, data size, and temperature units.',
      definition: ToolDefinition(
        name: 'convertUnits',
        description:
            'Convert a numeric value between common units (km, mi, m, ft, kg, '
            'lb, gb, mb, c, f).',
        parameters: <ToolParam>[
          ToolParam.number(
            'value',
            description: 'Numeric value to convert.',
            required: true,
          ),
          ToolParam.string(
            'from',
            description:
                'Source unit symbol (km, mi, m, ft, kg, lb, gb, mb, c, f).',
            required: true,
          ),
          ToolParam.string(
            'to',
            description: 'Target unit symbol.',
            required: true,
          ),
        ],
        handler: (ToolParams params) async {
          final value = params.getDouble('value') ?? 0;
          final from = (params.getString('from') ?? '').trim().toLowerCase();
          final to = (params.getString('to') ?? '').trim().toLowerCase();
          final converted = _convert(value, from, to);
          return <String, Object?>{
            'value': value,
            'from': from,
            'to': to,
            'converted': converted,
          };
        },
      ),
    ),
  ];

  /// Builds the active list of [ToolDefinition]s from [enabledBuiltInNames] and
  /// [customDeclarationsJson].
  static List<ToolDefinition> resolveActiveTools({
    required Iterable<String> enabledBuiltInNames,
    String customDeclarationsJson = '[]',
  }) => StudioToolRegistry().resolveTools(
    enabledNames: enabledBuiltInNames,
    customDeclarationsJson: customDeclarationsJson,
  );

  /// Parses an OpenAI-style JSON array of tool/function declarations.
  ///
  /// Custom user-declared tools run with a deterministic echo handler so
  /// developers can inspect structured tool-call extraction without writing
  /// Dart code first.
  static List<ToolDefinition> parseCustomDeclarations(String rawJson) {
    final decoded = jsonDecode(rawJson);
    if (decoded is! List) {
      throw const FormatException(
        'Custom tool declarations must be a JSON array.',
      );
    }
    final tools = <ToolDefinition>[];
    for (final entry in decoded) {
      if (entry is! Map) {
        continue;
      }
      final map = Map<String, dynamic>.from(entry);
      final fnMap = map['function'] is Map
          ? Map<String, dynamic>.from(map['function'] as Map)
          : map;
      final name = (fnMap['name'] as String?)?.trim();
      if (name == null || name.isEmpty) {
        continue;
      }
      final description =
          (fnMap['description'] as String?)?.trim() ?? 'Custom Studio tool.';
      final parameters = fnMap['parameters'] is Map
          ? Map<String, dynamic>.from(fnMap['parameters'] as Map)
          : <String, dynamic>{
              'type': 'object',
              'properties': <String, Object?>{},
            };
      tools.add(
        ToolDefinition.fromJsonSchema(
          name: name,
          description: description,
          schema: parameters,
          handler: (ToolParams params) async => <String, Object?>{
            'tool': name,
            'status': 'simulated_ok',
            'receivedArguments': params.raw,
          },
        ),
      );
    }
    return tools;
  }

  /// Evaluates a safe arithmetic expression without `eval`.
  static double evaluateExpression(String input) {
    final parser = _MathExpressionParser(input);
    final value = parser.parse();
    if (!value.isFinite) {
      throw const FormatException(
        'Expression evaluated to a non-finite value.',
      );
    }
    return value;
  }

  static double _convert(double value, String from, String to) {
    if (from == to) {
      return value;
    }
    if (from == 'c' && to == 'f') {
      return (value * 9.0 / 5.0) + 32.0;
    }
    if (from == 'f' && to == 'c') {
      return (value - 32.0) * 5.0 / 9.0;
    }
    const toMeters = <String, double>{
      'm': 1.0,
      'km': 1000.0,
      'mi': 1609.344,
      'ft': 0.3048,
    };
    if (toMeters.containsKey(from) && toMeters.containsKey(to)) {
      return value * toMeters[from]! / toMeters[to]!;
    }
    const toKg = <String, double>{'kg': 1.0, 'lb': 0.45359237, 'g': 0.001};
    if (toKg.containsKey(from) && toKg.containsKey(to)) {
      return value * toKg[from]! / toKg[to]!;
    }
    const toBytes = <String, double>{
      'b': 1.0,
      'kb': 1024.0,
      'mb': 1048576.0,
      'gb': 1073741824.0,
    };
    if (toBytes.containsKey(from) && toBytes.containsKey(to)) {
      return value * toBytes[from]! / toBytes[to]!;
    }
    throw FormatException('Unsupported unit conversion from "$from" to "$to".');
  }

  static String _weekdayName(int weekday) {
    const names = <String>[
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    return names[(weekday - 1).clamp(0, 6)];
  }
}

class _MathExpressionParser {
  _MathExpressionParser(String source)
    : _source = source.replaceAll(' ', ''),
      _index = 0;

  final String _source;
  int _index;

  double parse() {
    if (_source.isEmpty) {
      throw const FormatException('Empty expression.');
    }
    final result = _parseAddSub();
    if (_index < _source.length) {
      throw FormatException('Unexpected token at index $_index.');
    }
    return result;
  }

  double _parseAddSub() {
    var left = _parseMulDiv();
    while (_index < _source.length) {
      final op = _source[_index];
      if (op != '+' && op != '-') {
        break;
      }
      _index++;
      final right = _parseMulDiv();
      left = op == '+' ? left + right : left - right;
    }
    return left;
  }

  double _parseMulDiv() {
    var left = _parsePower();
    while (_index < _source.length) {
      final op = _source[_index];
      if (op != '*' && op != '/') {
        break;
      }
      _index++;
      final right = _parsePower();
      left = op == '*' ? left * right : left / right;
    }
    return left;
  }

  double _parsePower() {
    final base = _parseUnary();
    if (_index < _source.length && _source[_index] == '^') {
      _index++;
      final exponent = _parsePower();
      return math.pow(base, exponent).toDouble();
    }
    return base;
  }

  double _parseUnary() {
    if (_index < _source.length && _source[_index] == '-') {
      _index++;
      return -_parseUnary();
    }
    if (_index < _source.length && _source[_index] == '+') {
      _index++;
      return _parseUnary();
    }
    return _parsePrimary();
  }

  double _parsePrimary() {
    if (_index >= _source.length) {
      throw const FormatException('Unexpected end of expression.');
    }
    if (_source[_index] == '(') {
      _index++;
      final inner = _parseAddSub();
      if (_index >= _source.length || _source[_index] != ')') {
        throw const FormatException('Missing closing parenthesis.');
      }
      _index++;
      return inner;
    }

    final identStart = _index;
    while (_index < _source.length && _isLetter(_source.codeUnitAt(_index))) {
      _index++;
    }
    if (_index > identStart) {
      final ident = _source.substring(identStart, _index).toLowerCase();
      if (ident == 'pi') {
        return math.pi;
      }
      if (ident == 'e') {
        return math.e;
      }
      if (_index >= _source.length || _source[_index] != '(') {
        throw FormatException('Unknown identifier "$ident".');
      }
      _index++;
      final arg = _parseAddSub();
      if (_index >= _source.length || _source[_index] != ')') {
        throw FormatException('Missing ")" after $ident.');
      }
      _index++;
      return switch (ident) {
        'sqrt' => math.sqrt(arg),
        'sin' => math.sin(arg),
        'cos' => math.cos(arg),
        'tan' => math.tan(arg),
        'log' => math.log(arg),
        'abs' => arg.abs(),
        _ => throw FormatException('Unsupported function "$ident".'),
      };
    }

    final numStart = _index;
    while (_index < _source.length &&
        _isNumberChar(_source.codeUnitAt(_index))) {
      _index++;
    }
    if (_index == numStart) {
      throw FormatException('Expected number at index $_index.');
    }
    return double.parse(_source.substring(numStart, _index));
  }

  static bool _isLetter(int unit) =>
      (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122);

  static bool _isNumberChar(int unit) =>
      (unit >= 48 && unit <= 57) || unit == 46;
}
