/// Current reproducible catalog contract; older journals retain their version.
const int validationCatalogVersion = 5;

/// Versioned core feature selectors. Optional model/media packs are separate.
const validationFeatures = {
  'text': 1,
  'unicode': 1,
  'thinking': 1,
  'history': 1,
  'tools': 1,
  'streaming': 1,
  'batching': 1,
  'lifecycle': 1,
  'guards': 1,
  'performance': 1,
};

/// Shared synthetic fixtures, compiled into desktop, mobile and Web runners.
/// Model-specific overrides stay in the hashed profile manifest.
const validationFixtures = <String, Map<String, Object>>{
  'unicode': {'input': 'Montréal 👋\n한글 café', 'expected_prefix': ''},
  'unicode_generation': {
    'prompt': 'Reply with exactly: Montréal 👋',
    'expected': 'Montréal 👋',
    'qualification':
        'strict public output assertion; a failure does not identify its root cause',
  },
  'raw': {'prompt': 'Once upon a time'},
  'hello': {
    'prompt': 'Reply with one short sentence saying hello.',
    'regex': r'\bhello\b',
  },
  'arithmetic': {
    'prompt': 'What is 2 + 2? Reply with only the number.',
    'regex': r'^4[.!]?$',
  },
  'history': {
    'system': 'Remember the secret code exactly.',
    'user': 'The secret code is cedar17.',
    'assistant': 'I will remember the code.',
    'prompt': 'What is the secret code? Reply with only the code.',
    'expected': 'cedar17',
  },
  'tools': {
    'prompt': 'Call get_weather for Montréal.',
    'tool': {
      'type': 'function',
      'function': {
        'name': 'get_weather',
        'description': 'Return the weather for a city.',
        'parameters': {
          'type': 'object',
          'properties': {
            'city': {'type': 'string'},
          },
          'required': ['city'],
        },
      },
    },
    'expected_arguments': {'city': 'Montréal'},
    'response': {'city': 'Montréal', 'temperature_celsius': 17},
    'modes': ['auto', 'required', 'none'],
  },
  'cancel': {
    'chat_prompt':
        'Write a long story about a fox. Continue for at least 500 words.',
    'max_tokens': 256,
    'deadline_ms': 5000,
  },
  'batching': {'token_threshold': 1, 'byte_threshold': 1},
  'stop': {
    'prompt': 'Reply with exactly: alpha cedar17 omega',
    'marker': 'cedar17',
  },
  'limit': {'max_tokens': 1, 'expected_native_decode_tokens': 1},
  'invalid_grammar': {
    'grammar': 'root ::= "unterminated',
    'native_message':
        'llama.cpp failed to initialize the requested grammar sampler.',
    'web_details_marker': '(invalid grammar)',
  },
  'benchmark': {
    'chat_prompt': 'List the numbers from one to twenty in English.',
    'warmups': 1,
    'samples': 3,
  },
};

/// Case identity and fixture dependencies. False implementation flags always
/// produce NOT_RUN, never an unsupported-platform exemption.
class ValidationCaseDefinition {
  /// Declares a case without hiding unimplemented obligations.
  const ValidationCaseDefinition(
    this.id,
    this.features,
    this.fixtures, {
    this.implemented = true,
    this.version = 1,
  });

  /// Stable identifier in journals and reports.
  final String id;

  /// Feature selectors that include this case.
  final List<String> features;

  /// Fixture keys included in the case's evidence hash.
  final List<String> fixtures;

  /// Whether the shared runner can execute this case.
  final bool implemented;

  /// Semantic version of the current case contract.
  final int version;

  /// Serializable metadata, independent of model-specific fixture overrides.
  Map<String, Object> toJson() => {
    'id': id,
    'version': version,
    'features': features,
    'fixture_ids': fixtures,
    'implemented': implemented,
  };
}

/// Baseline case definitions; model applicability is resolved by the profile.
const coreValidationCases = [
  ValidationCaseDefinition('C01.load', ['lifecycle'], []),
  ValidationCaseDefinition('C02.unicode', ['unicode'], ['unicode']),
  ValidationCaseDefinition('C03.raw', ['text'], ['raw']),
  ValidationCaseDefinition('C04.hello', ['text'], ['hello']),
  ValidationCaseDefinition('C04.arithmetic', ['text'], ['arithmetic']),
  ValidationCaseDefinition('C06.history', ['history'], ['history']),
  ValidationCaseDefinition(
    'C06.history.public_system_wire',
    ['history'],
    ['history'],
  ),
  ValidationCaseDefinition('C06.history.no_system', ['history'], ['history']),
  ValidationCaseDefinition('C06.history.combined', ['history'], ['history']),
  ValidationCaseDefinition(
    'C08.cancel',
    ['streaming', 'lifecycle'],
    ['cancel', 'raw', 'hello'],
  ),
  ValidationCaseDefinition(
    'C08.cancel.early',
    ['streaming', 'lifecycle'],
    ['cancel', 'raw', 'hello'],
  ),
  ValidationCaseDefinition(
    'C08.cancel.restart',
    ['streaming', 'lifecycle'],
    ['cancel', 'raw', 'hello'],
  ),
  ValidationCaseDefinition(
    'C08.overlap',
    ['streaming', 'lifecycle'],
    ['cancel', 'raw', 'hello'],
  ),
  ValidationCaseDefinition('C09.reload', ['lifecycle'], ['raw', 'hello']),
  ValidationCaseDefinition(
    'C10.limit',
    ['streaming'],
    ['limit', 'raw', 'hello'],
  ),
  ValidationCaseDefinition(
    'C12.grammar',
    ['guards'],
    ['invalid_grammar', 'raw', 'hello'],
  ),
  ValidationCaseDefinition(
    'C12.recovery',
    ['guards', 'lifecycle'],
    ['raw', 'hello'],
  ),
  ValidationCaseDefinition('B01.warmup', ['performance'], ['benchmark', 'raw']),
  ValidationCaseDefinition('B01.1', ['performance'], ['benchmark', 'raw']),
  ValidationCaseDefinition('B01.2', ['performance'], ['benchmark', 'raw']),
  ValidationCaseDefinition('B01.3', ['performance'], ['benchmark', 'raw']),
];

/// Extra obligations added by release or matching focused feature selections.
const extendedValidationCases = [
  ValidationCaseDefinition(
    'C05.thinking',
    ['thinking'],
    ['arithmetic'],
    version: 2,
  ),
  ValidationCaseDefinition(
    'C07.tools',
    ['tools'],
    ['tools', 'hello'],
    version: 3,
  ),
  ValidationCaseDefinition(
    'C07.tools.auto_text',
    ['tools'],
    ['tools', 'hello'],
  ),
  ValidationCaseDefinition(
    'C10.stop',
    ['streaming'],
    ['stop', 'hello', 'raw'],
    version: 2,
  ),
  ValidationCaseDefinition(
    'C11.batching',
    ['streaming', 'batching'],
    ['raw', 'hello', 'batching'],
    version: 2,
  ),
  ValidationCaseDefinition(
    'C12.guards',
    ['guards'],
    ['hello', 'raw'],
    version: 2,
  ),
  ValidationCaseDefinition(
    'C02.generate',
    ['unicode'],
    ['unicode_generation'],
    version: 2,
  ),
  ValidationCaseDefinition(
    'C09.reload.second',
    ['lifecycle'],
    ['raw', 'hello'],
  ),
];

/// Stable order for the complete selected/omitted inventory.
const validationCaseCatalog = [
  ...coreValidationCases,
  ...extendedValidationCases,
];

/// Cases that catalogs 1 to 4 do not declare.
const catalogFiveCaseIds = {
  'C08.cancel.early',
  'C08.cancel.restart',
  'C08.overlap',
  'C12.grammar',
  'C07.tools.auto_text',
};

/// Whether [catalogVersion] declares case [id].
bool catalogDeclaresCase(String id, int catalogVersion) =>
    catalogVersion >= 5 || !catalogFiveCaseIds.contains(id);

/// Finds a declared case; an unknown ID is a programming error.
ValidationCaseDefinition validationCase(
  String id, {
  int catalogVersion = validationCatalogVersion,
}) {
  if (catalogVersion < 1 || catalogVersion > validationCatalogVersion) {
    throw const FormatException('Unsupported catalog version');
  }
  if (!catalogDeclaresCase(id, catalogVersion)) {
    throw FormatException('Catalog $catalogVersion does not declare $id');
  }
  final current = catalogVersion < 5 && id == 'C07.tools'
      ? const ValidationCaseDefinition(
          'C07.tools',
          ['tools'],
          ['tools'],
          version: 2,
        )
      : validationCaseCatalog.singleWhere((definition) => definition.id == id);
  if (catalogVersion < 4 &&
      ['C05.thinking', 'C07.tools', 'C02.generate'].contains(id)) {
    return ValidationCaseDefinition(
      id,
      current.features,
      current.fixtures,
      implemented: false,
    );
  }
  if (catalogVersion < 3 && (id == 'C10.stop' || id == 'C12.guards')) {
    return ValidationCaseDefinition(
      id,
      [id == 'C10.stop' ? 'streaming' : 'guards'],
      [],
      implemented: false,
    );
  }
  if (catalogVersion == 1 && id == 'C11.batching') {
    return const ValidationCaseDefinition(
      'C11.batching',
      ['streaming'],
      ['raw', 'hello'],
      implemented: false,
    );
  }
  return current;
}
