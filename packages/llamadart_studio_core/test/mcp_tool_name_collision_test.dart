import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:test/test.dart';

void main() {
  test('long MCP tool names remain unique across repeated collisions', () {
    final raw = List.filled(64, 'x').join();
    final used = {raw, 'server_$raw'.substring(0, 64)};
    for (var i = 0; i < 30; i++) {
      final name = McpToolSchemaAdapter.allocateExposedToolName(
        serverName: 'server',
        rawToolName: raw,
        usedNames: used,
      );
      expect(name.length, lessThanOrEqualTo(64));
      expect(name, matches(RegExp(r'^[a-zA-Z0-9_-]+$')));
      expect(used.add(name), isTrue);
    }
  });
}
