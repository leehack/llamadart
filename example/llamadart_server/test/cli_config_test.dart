import 'package:llamadart_server/src/bootstrap/cli/cli.dart';
import 'package:test/test.dart';

void main() {
  test('uses the Unsloth Qwen3.6 27B default configuration', () {
    final parser = buildServerCliArgParser();
    final config = parseServerCliConfig(parser.parse([]));

    expect(
      config.modelInput,
      'https://huggingface.co/unsloth/Qwen3.6-27B-GGUF/resolve/main/'
      'Qwen3.6-27B-UD-Q4_K_XL.gguf?download=true',
    );
    expect(config.contextSize, 16384);
    expect(parser.options, isNot(contains('enable-tool-execution')));
    expect(parser.options, isNot(contains('max-tool-rounds')));
  });
}
