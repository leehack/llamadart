/// Declared-key sets whose open-object exclusion grammars previously exceeded
/// llama.cpp's repetition limit.
final Map<String, List<String>> largeKeySets = {
  'Kubernetes PodSpec': _podSpecProperties,
  '150 keys': [for (var i = 0; i < 150; i++) 'field_${i}_value'],
  '21 distinct 20-character names': [
    for (var i = 0; i < 21; i++)
      '${String.fromCharCode(0x61 + i)}0123456789abcdefghi',
  ],
  '4 names of 128 characters': [
    for (var i = 0; i < 4; i++)
      '${String.fromCharCode(0x61 + i)}${'0123456789abcdef' * 8}'.substring(
        0,
        128,
      ),
  ],
  '1023 properties': [for (var i = 0; i < 1023; i++) 'p$i'],
};

/// Declared keys whose exclusion rules exceed the per-grammar budget, so the
/// extra-property slot falls back to the plain string key.
final List<String> overBudgetKeySet = [
  for (var i = 0; i < 200; i++)
    'n${i.toString().padLeft(3, '0')}${'abcdefghij' * 10}'.substring(0, 100),
];

/// Item schemas covering primitive, enum, object, nested and union arrays.
const List<Map<String, dynamic>> boundedArrayItemSchemas = [
  {'type': 'string'},
  {'type': 'integer'},
  {
    'enum': ['x', 'y'],
  },
  {
    'type': 'object',
    'properties': {
      'a': {'type': 'integer'},
    },
    'required': ['a'],
    'additionalProperties': false,
  },
  {
    'type': 'array',
    'items': {'type': 'integer'},
  },
  {
    'anyOf': [
      {'type': 'integer'},
      {'type': 'null'},
    ],
  },
];

/// Returns a JSON value that [schema] from [boundedArrayItemSchemas] accepts.
Object? boundedArrayItemValue(Map<String, dynamic> schema) =>
    switch (schema['type']) {
      'string' => 's',
      'integer' => 1,
      'object' => {'a': 1},
      'array' => [1],
      _ => schema.containsKey('enum') ? 'x' : null,
    };

/// Returns why llama.cpp's grammar parser would reject [grammar] for its
/// repetition limit, or `null` when it stays within it.
///
/// Mirrors the symbol accounting of `llama_grammar_parser::parse_sequence` at
/// the pinned b10549: a repeated item counts every symbol created while it
/// was parsed (synthesized groups, repetition rules and first references to
/// rule names), and the product with the repetition count must stay below
/// `MAX_REPETITION_THRESHOLD`.
String? llamaCppRepetitionRejection(String grammar) =>
    _RepetitionBudget(grammar).rejection();

const _maxRepetitionThreshold = 2000;
const _unbounded = -1;

final class _RepetitionBudget {
  _RepetitionBudget(this._source);

  final String _source;
  final Set<String> _names = {};
  int _generated = 0;
  int _pos = 0;
  String _rule = '';

  int get _symbols => _names.length + _generated;

  String? rejection() {
    try {
      _skipSpace(newlines: true);
      while (_pos < _source.length) {
        _parseRule();
      }
      return null;
    } on _Rejected catch (rejected) {
      return rejected.message;
    }
  }

  void _parseRule() {
    _rule = _name();
    _names.add(_rule);
    _skipSpace(newlines: false);
    _expect('::=');
    _skipSpace(newlines: true);
    _alternates(nested: false);
    _skipSpace(newlines: true);
  }

  void _alternates({required bool nested}) {
    _sequence(nested: nested);
    while (_peek == '|') {
      _pos++;
      _skipSpace(newlines: true);
      _sequence(nested: nested);
    }
  }

  void _sequence({required bool nested}) {
    var previous = 1;
    void repeat(int min, int max) {
      final total = max != _unbounded && max > 0 ? max : (min > 0 ? min : 1);
      if (previous * total >= _maxRepetitionThreshold) {
        throw _Rejected(
          'rule $_rule repeats $previous symbols $total times at $_pos',
        );
      }
      _generated += max == _unbounded ? 1 : max - min;
      previous *= total;
    }

    while (_pos < _source.length) {
      final char = _peek;
      if (char == '"' || char == '[') {
        _delimited(char == '"' ? '"' : ']');
        previous = 1;
      } else if (_isWordChar(char)) {
        _names.add(_name());
        previous = 1;
      } else if (char == '(') {
        _pos++;
        _skipSpace(newlines: true);
        final before = _symbols;
        _generated++;
        _alternates(nested: true);
        _expect(')');
        previous = _symbols - before;
      } else if (char == '.') {
        _pos++;
        previous = 1;
      } else if (char == '*' || char == '+' || char == '?') {
        _pos++;
        repeat(char == '+' ? 1 : 0, char == '?' ? 1 : _unbounded);
      } else if (char == '{') {
        _pos++;
        final min = _int();
        var max = min;
        if (_peek == ',') {
          _pos++;
          max = _isDigit(_peek) ? _int() : _unbounded;
        }
        _expect('}');
        if (min > _maxRepetitionThreshold) {
          throw _Rejected('rule $_rule repeats $min times');
        }
        if (max > _maxRepetitionThreshold) max = _unbounded;
        repeat(min, max);
      } else {
        return;
      }
      _skipSpace(newlines: nested);
    }
  }

  void _delimited(String end) {
    _pos++;
    while (_source[_pos] != end) {
      _pos += _source[_pos] == r'\' ? 2 : 1;
    }
    _pos++;
  }

  String _name() {
    final start = _pos;
    while (_pos < _source.length && _isWordChar(_source[_pos])) {
      _pos++;
    }
    if (start == _pos) throw StateError('Expected a rule name at $_pos');
    return _source.substring(start, _pos);
  }

  int _int() {
    final start = _pos;
    while (_isDigit(_peek)) {
      _pos++;
    }
    return int.parse(_source.substring(start, _pos));
  }

  void _expect(String token) {
    if (!_source.startsWith(token, _pos)) {
      throw StateError('Expected "$token" at $_pos');
    }
    _pos += token.length;
  }

  void _skipSpace({required bool newlines}) {
    while (_pos < _source.length) {
      final char = _source[_pos];
      if (char == ' ' || char == '\t' || newlines && char == '\n') {
        _pos++;
      } else {
        return;
      }
    }
  }

  String get _peek => _pos < _source.length ? _source[_pos] : '';

  static bool _isDigit(String char) =>
      char.isNotEmpty &&
      char.codeUnitAt(0) >= 0x30 &&
      char.codeUnitAt(0) <= 0x39;

  static bool _isWordChar(String char) =>
      char.isNotEmpty && RegExp(r'[A-Za-z0-9_-]').hasMatch(char);
}

final class _Rejected implements Exception {
  _Rejected(this.message);

  final String message;
}

const _podSpecProperties = [
  'activeDeadlineSeconds',
  'affinity',
  'automountServiceAccountToken',
  'containers',
  'dnsConfig',
  'dnsPolicy',
  'enableServiceLinks',
  'ephemeralContainers',
  'hostAliases',
  'hostIPC',
  'hostNetwork',
  'hostPID',
  'hostUsers',
  'hostname',
  'imagePullSecrets',
  'initContainers',
  'nodeName',
  'nodeSelector',
  'os',
  'overhead',
  'preemptionPolicy',
  'priority',
  'priorityClassName',
  'readinessGates',
  'resourceClaims',
  'restartPolicy',
  'runtimeClassName',
  'schedulerName',
  'schedulingGates',
  'securityContext',
  'serviceAccount',
  'serviceAccountName',
  'setHostnameAsFQDN',
  'shareProcessNamespace',
  'subdomain',
  'terminationGracePeriodSeconds',
  'tolerations',
  'topologySpreadConstraints',
  'volumes',
];
