@TestOn('vm')
library;

import 'package:llamadart/src/hook/apple_companion_constraint.dart';
import 'package:test/test.dart';

const _nativePin = 'leehack/llamadart-native@v0.6.0-3';

String? _requirement(String? coreVersion, {String? firstPinningRelease}) =>
    appleCompanionRequirement(
      packageName: 'llamadart_llama_cpp_flutter',
      coreVersion: coreVersion,
      nativePin: _nativePin,
      firstPinningRelease: firstPinningRelease,
    );

void main() {
  group('appleCompanionConstraint', () {
    test('a core before lockstep names the first pinning 0.0.x release', () {
      for (final core in ['0.12.0', '0.12.2', '0.9.1']) {
        expect(
          appleCompanionConstraint(core, firstPinningRelease: '0.0.23'),
          '^0.0.23',
          reason: core,
        );
        expect(appleCompanionConstraint(core), isNull, reason: core);
      }
    });

    test('a lockstep core names its own minor, never a 0.0.x release', () {
      for (final (core, expected) in [
        ('0.13.0', '^0.13.0'),
        ('0.13.4', '^0.13.0'),
        ('0.14.1', '^0.14.0'),
      ]) {
        for (final firstPinning in [null, '0.0.23']) {
          expect(
            appleCompanionConstraint(core, firstPinningRelease: firstPinning),
            expected,
            reason: '$core with $firstPinning',
          );
        }
      }
    });

    test('a 1.x core names a range a caret would widen', () {
      expect(appleCompanionConstraint('1.2.3'), "'>=1.2.0 <1.3.0'");
    });

    test('an unreadable core version names nothing', () {
      for (final core in [null, '', 'latest', '0.13']) {
        expect(
          appleCompanionConstraint(core, firstPinningRelease: '0.0.23'),
          isNull,
          reason: core,
        );
      }
    });
  });

  group('appleCompanionRequirement', () {
    test('core 0.12.x names the first release pinning the native tag', () {
      expect(
        _requirement('0.12.2', firstPinningRelease: '0.0.23'),
        'Depend on `llamadart_llama_cpp_flutter: ^0.0.23`, the first release '
        'pinning $_nativePin, in pubspec.yaml and rerun flutter pub get; a '
        'caret constraint on an earlier 0.0.x release never resolves it.',
      );
    });

    test('core 0.13.x names the companions of its minor', () {
      for (final core in ['0.13.0', '0.13.2']) {
        final requirement = _requirement(core, firstPinningRelease: '0.0.23');
        expect(
          requirement,
          'Depend on `llamadart_llama_cpp_flutter: ^0.13.0`, the releases '
          'paired with core 0.13.x, in pubspec.yaml and rerun flutter pub '
          'get.',
          reason: core,
        );
        expect(requirement, isNot(contains('0.0.')), reason: core);
      }
    });

    test('names nothing when no constraint is known', () {
      expect(_requirement('0.12.2'), isNull);
      expect(_requirement(null, firstPinningRelease: '0.0.23'), isNull);
    });
  });
}
