import 'dart:io';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_basic_example/model_downloader.dart';
import 'package:llamadart_basic_example/inference_test.dart';

// TinyLlama is a good balance of size and performance for testing
const modelUrl =
    'https://huggingface.co/TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF/resolve/main/tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf';
const modelFileName = 'tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf';

void main() async {
  print('🦙 llamadart Basic Example & Test');
  print('=' * 50);

  LlamaService? service;

  try {
    // 1. Setup & Download
    final downloader = ModelDownloader();
    final modelFile =
        await downloader.downloadModel(modelUrl, fileName: modelFileName);

    // 2. Initialize Service
    service = LlamaService();

    // 3. Run Test
    final tester = InferenceTest(service);
    await tester.run(
      modelFile.path,
      prompt: "<|user|>\nTell me a joke about a llama.<|end|>\n<|assistant|>\n",
    );
  } catch (e) {
    print('\nFatal Error: $e');
    exit(1);
  } finally {
    service?.dispose();
    // Allow time for the isolate to process the dispose message and detach finalizers
    // preventing race condition on shutdown
    await Future.delayed(Duration(seconds: 2));
  }
}
