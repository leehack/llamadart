import 'dart:ffi';
import 'dart:mirrors';

import 'package:llamadart/src/backends/llama_cpp/bindings.dart';
import 'package:llamadart/src/backends/llama_cpp/exit_teardown_api.dart';
import 'package:llamadart/src/backends/llama_cpp/llama_cpp_service.dart';
import 'package:llamadart/src/core/exceptions.dart';
import 'package:test/test.dart';

final LibraryMirror _owner =
    reflectClass(LlamaCppService).owner as LibraryMirror;

dynamic _read(Object object, String field) =>
    reflect(object).getField(MirrorSystem.getSymbol(field, _owner)).reflectee;

void main(List<String> arguments) {
  final calls = LlamaCppObjectCalls.untracked();
  final service = LlamaCppService(objectCalls: calls);
  final wrapperClass =
      _owner.declarations[MirrorSystem.getSymbol('_LlamaModelWrapper', _owner)]
          as ClassMirror;
  final model = wrapperClass
      .newInstance(
        const Symbol(''),
        [Pointer<llama_model>.fromAddress(0x1000), calls],
        {#vocabSize: 1, #suppressedTokens: <int>[]},
      )
      .reflectee;
  (_read(service, '_models') as Map)[1] = model;

  _check(_read(service, '_reasoningBudgetApiLookupAttempted'), isFalse);
  _check(_read(service, '_reasoningBudgetApi'), isNull);
  switch (arguments.single) {
    case 'cold':
      final capabilities = service.generationCapabilities(1);
      _check(capabilities.thinkingBudget, isTrue);
      _check(_read(service, '_reasoningBudgetApiLookupAttempted'), isTrue);
      final api = _read(service, '_reasoningBudgetApi');
      _check(api, isNotNull);
      _check(service.generationCapabilities(1).thinkingBudget, isTrue);
      _check(_read(service, '_reasoningBudgetApi'), same(api));
    case 'dead-model':
    case 'dead-vocab':
      final failuresOwner = reflect(calls.failures).type.owner as LibraryMirror;
      final freeOnly =
          reflect(calls.failures)
                  .getField(MirrorSystem.getSymbol('_freeOnly', failuresOwner))
                  .reflectee
              as Map;
      freeOnly[arguments.single == 'dead-model' ? 0x1000 : 0x2000] =
          'llama_dart_tokenize';
      try {
        service.generationCapabilities(1);
        throw StateError('An unusable model must not report capabilities.');
      } on LlamaStateException catch (error) {
        _check(error.message, contains('Unload the model and load it again'));
      }
      _check(_read(service, '_reasoningBudgetApiLookupAttempted'), isFalse);
    default:
      throw ArgumentError.value(arguments.single, 'mode');
  }
}

void _check(Object? actual, Matcher matcher) {
  if (!matcher.matches(actual, <Object?, Object?>{})) {
    throw StateError(
      'Expected ${matcher.describe(StringDescription())}; got $actual',
    );
  }
}
