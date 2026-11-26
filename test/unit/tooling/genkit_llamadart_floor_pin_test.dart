@TestOn('vm')
library;

import 'dart:io';

import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';

import 'support/genkit_dependency_floor.dart';

void main() {
  const floor = '0.21.0';

  test('reads the floor of a caret constraint', () {
    expect(
      genkitLlamadartFloor('dependencies:\n  llamadart: ^$floor\n'),
      Version.parse(floor),
    );
  });

  test('reads the inclusive lower bound of an explicit range', () {
    expect(
      genkitLlamadartFloor("dependencies:\n  llamadart: '>=$floor <0.23.0'\n"),
      Version.parse(floor),
    );
  });

  test('rejects a malformed range', () {
    expect(
      () => genkitLlamadartFloor(
        "dependencies:\n  llamadart: '>=$floor <next'\n",
      ),
      throwsFormatException,
    );
  });

  test('rejects a range without an inclusive lower bound', () {
    expect(
      () => genkitLlamadartFloor(
        "dependencies:\n  llamadart: '>$floor <0.23.0'\n",
      ),
      throwsFormatException,
    );
  });

  test('genkit workflow llamadart pins equal the package floor', () {
    final floor = genkitLlamadartFloor(
      File('packages/genkit_llamadart/pubspec.yaml').readAsStringSync(),
    ).toString();

    for (final path in [
      '.github/workflows/ci.yml',
      '.github/workflows/publish_genkit_pubdev.yml',
    ]) {
      final pins = RegExp(
        r'llamadart@(\d+\.\d+\.\d+)',
      ).allMatches(File(path).readAsStringSync()).map((m) => m.group(1));
      expect(pins, isNotEmpty, reason: path);
      expect(pins, everyElement(floor), reason: path);
    }
  });
}
