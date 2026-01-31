import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;

class TestHelper {
  static const String modelUrl =
      'https://huggingface.co/ggml-org/tiny-llamas/resolve/main/stories15M.gguf';
  static const String modelFileName = 'stories15M.gguf';

  static Future<File> getTestModel() async {
    final modelsDir = Directory(path.join(Directory.current.path, 'models'));
    if (!modelsDir.existsSync()) {
      modelsDir.createSync(recursive: true);
    }

    final modelFile = File(path.join(modelsDir.path, modelFileName));
    if (modelFile.existsSync()) {
      return modelFile;
    }

    print('Downloading test model from $modelUrl...');
    final response = await http.get(Uri.parse(modelUrl));
    if (response.statusCode != 200) {
      throw Exception('Failed to download model: ${response.statusCode}');
    }

    await modelFile.writeAsBytes(response.bodyBytes);
    print('Test model downloaded to ${modelFile.path}');
    return modelFile;
  }
}
