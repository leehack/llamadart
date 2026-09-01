@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:llamadart/src/hook/native_bundle_config.dart';
import 'package:test/test.dart';

void main() {
  const forms = <String, NativeTagForm>{
    'stable': NativeTagForm.stable,
    'stable_wrapper': NativeTagForm.stableWrapper,
    'nightly': NativeTagForm.nightly,
    'nightly_wrapper': NativeTagForm.nightlyWrapper,
    'legacy_wrapper': NativeTagForm.legacyWrapper,
  };
  final fixtureFile = File(
    'tool/native/fixtures/native_release_tag_grammar.json',
  );
  final fixtureJson =
      jsonDecode(fixtureFile.readAsStringSync()) as Map<String, dynamic>;
  final patterns = fixtureJson['patterns'] as Map<String, dynamic>;
  final positiveCases = fixtureJson['positive_cases'] as List<dynamic>;
  final negativeCases = fixtureJson['negative_cases'] as List<dynamic>;
  final reservedInputs = fixtureJson['reserved_inputs'] as List<dynamic>;

  group('native tag pattern contract', () {
    test('compiled patterns match fixture specification', () {
      expect(stableNativeTagPattern.pattern, patterns['stable_pattern']);
      expect(
        stableWrapperTagPattern.pattern,
        patterns['stable_wrapper_pattern'],
      );
      expect(nightlyNativeTagPattern.pattern, patterns['nightly_pattern']);
      expect(
        nightlyWrapperTagPattern.pattern,
        patterns['nightly_wrapper_pattern'],
      );
      expect(
        legacyWrapperTagPattern.pattern,
        patterns['legacy_wrapper_pattern'],
      );
      expect(nativeReleaseTagPattern.pattern, patterns['combined_pattern']);
    });
  });

  group('positive native release tag corpus', () {
    for (final rawCase in positiveCases) {
      final caseMap = rawCase as Map<String, dynamic>;
      final tag = caseMap['tag'] as String;
      final expectedChannel = caseMap['channel'] as String;
      final expectedForm = caseMap['form'] as String;
      final expectedVersion = (caseMap['version'] as List<dynamic>).cast<int>();
      final expectedWrapperRevision = caseMap['wrapper_revision'] as int;
      final expectedUpstreamTag = caseMap['upstream_tag'] as String;
      final expectedIsWrapper = caseMap['is_wrapper'] as bool;
      final expectedIsLegacy = caseMap['is_legacy'] as bool;
      final expectedIsLatestEligible = caseMap['is_latest_eligible'] as bool;
      final expectedIsStableUpstream = caseMap['is_stable_upstream'] as bool;

      test('accepts and correctly classifies "$tag"', () {
        expect(isValidNativeReleaseTag(tag), isTrue);
        expect(nativeReleaseTagPattern.hasMatch(tag), isTrue);

        final parsed = parseNativeReleaseTag(tag);
        expect(parsed.rawTag, tag);
        expect(parsed.channel, expectedChannel);
        expect(parsed.form, forms[expectedForm]);
        expect(parsed.version, expectedVersion);
        expect(parsed.wrapperRevision, expectedWrapperRevision);
        expect(parsed.upstreamTag, expectedUpstreamTag);
        expect(parsed.isWrapper, expectedIsWrapper);
        expect(parsed.isLegacy, expectedIsLegacy);
        expect(parsed.isLatestEligible, expectedIsLatestEligible);
        expect(parsed.isStableUpstream, expectedIsStableUpstream);

        expect(tryParseNativeReleaseTag(tag), equals(parsed));
        expect(normalizeNativeLlamaCppTag(tag), expectedUpstreamTag);
      });
    }
  });

  group('negative native release tag corpus', () {
    for (final rawCase in negativeCases) {
      final caseMap = rawCase as Map<String, dynamic>;
      final tag = caseMap['tag'] as String;
      final reason = caseMap['reason'] as String;

      test('rejects "$tag" ($reason)', () {
        expect(isValidNativeReleaseTag(tag), isFalse);
        expect(nativeReleaseTagPattern.hasMatch(tag), isFalse);
        expect(tryParseNativeReleaseTag(tag), isNull);
        expect(normalizeNativeLlamaCppTag(tag), isNull);
        expect(
          () => parseNativeReleaseTag(tag),
          throwsA(isA<FormatException>()),
        );
      });
    }
  });

  group('reserved native tag inputs', () {
    for (final rawCase in reservedInputs) {
      final caseMap = rawCase as Map<String, dynamic>;
      final value = caseMap['value'] as String;

      test('classifies "$value" only where explicitly allowed', () {
        expect(caseMap['dart_build_hook'], isFalse);
        expect(caseMap['release_docs_pin'], isFalse);
        expect(isValidNativeReleaseTag(value), isFalse);
        expect(tryParseNativeReleaseTag(value), isNull);
      });
    }
  });
}
