@TestOn('vm')
library;

import 'dart:io';

import 'package:llamadart/src/backends/llama_cpp/build_identity.dart';
import 'package:test/test.dart';

void main() {
  test('the pinned runtime reports a complete, path-free build identity', () {
    final identity = readNativeBuildIdentity(isWindows: Platform.isWindows);

    expect(identity, startsWith('llamadart-native-build/1;'));
    final fields = {
      for (final field in identity!.split(';').skip(1))
        field.substring(0, field.indexOf('=')): field.substring(
          field.indexOf('=') + 1,
        ),
    };
    expect(
      fields.keys,
      containsAll(['owner', 'llama.cpp', 'backends', 'options']),
    );
    for (final MapEntry(:key, :value) in fields.entries) {
      expect(value, matches(RegExp(r'^[A-Za-z0-9._+,-]+$')), reason: key);
    }
  });
}
