@TestOn('browser')
library;

import 'package:test/test.dart';

void main() {
  test('disposable 0.17.4 core-template shard failure proof', () {
    fail('Intentional hosted shard isolation control; never merge this test.');
  });
}
