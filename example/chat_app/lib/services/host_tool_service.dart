import 'package:llamadart/llamadart.dart';

/// Supplies the example app's built-in host implementations for declared tools.
///
/// Declarations are user-editable, so a declared name is never treated as
/// permission to run arbitrary code: only names with a built-in implementation
/// produce a real result and every other name resolves to an explicit error
/// payload that is sent back to the model as the tool result.
class HostToolService {
  const HostToolService();

  /// The name of the built-in demo tool shipped with the default declarations.
  static const String getWeatherToolName = 'getWeather';

  static const List<String> _simulatedConditions = <String>[
    'clear sky',
    'partly cloudy',
    'overcast',
    'light rain',
    'thunderstorms',
    'light snow',
  ];

  /// Returns the handler bound to [toolName] when a declaration is parsed.
  ToolHandler handlerFor(String toolName) {
    final normalized = toolName.trim();
    if (normalized == getWeatherToolName) {
      return getWeather;
    }
    return (ToolParams params) async => unsupportedToolResult(normalized);
  }

  /// The tool result returned for a declaration without an implementation.
  Map<String, Object?> unsupportedToolResult(String toolName) {
    return <String, Object?>{
      'tool': toolName,
      'error': 'unsupported_tool',
      'message':
          'This example app has no built-in implementation for "$toolName", '
          'so nothing was executed.',
    };
  }

  /// The tool result returned when a handler throws.
  Map<String, Object?> failedToolResult(String toolName) {
    return <String, Object?>{
      'tool': toolName,
      'error': 'tool_execution_failed',
      'message': 'The "$toolName" handler failed, so no result was produced.',
    };
  }

  /// Returns a deterministic simulated forecast for the requested city.
  ///
  /// The values are derived from a stable hash of the city name so repeated
  /// runs and semantic assertions stay reproducible. This never contacts a
  /// weather service.
  Future<Object?> getWeather(ToolParams params) async {
    final rawCity = params['city'];
    final city = rawCity is String ? rawCity.trim() : '';
    if (city.isEmpty) {
      return <String, Object?>{
        'tool': getWeatherToolName,
        'error': 'invalid_arguments',
        'message': 'getWeather requires a non-empty "city" string argument.',
      };
    }

    final seed = _stableSeed(city.toLowerCase());
    return <String, Object?>{
      'tool': getWeatherToolName,
      'city': city,
      'condition': _simulatedConditions[seed % _simulatedConditions.length],
      'temperatureCelsius': 4 + (seed % 28),
      'humidityPercent': 35 + (seed % 45),
      'simulated': true,
      'source':
          'llamadart chat example built-in simulation; not live weather data',
    };
  }

  int _stableSeed(String value) {
    var hash = 7;
    for (final codeUnit in value.codeUnits) {
      hash = (hash * 31 + codeUnit) & 0x7fffffff;
    }
    return hash;
  }
}
