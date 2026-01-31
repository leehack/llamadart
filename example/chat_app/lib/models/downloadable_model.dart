class DownloadableModel {
  final String name;
  final String description;
  final String url;
  final String filename;
  final int sizeBytes;

  const DownloadableModel({
    required this.name,
    required this.description,
    required this.url,
    required this.filename,
    required this.sizeBytes,
  });

  String get sizeMb => (sizeBytes / (1024 * 1024)).toStringAsFixed(1);

  static const List<DownloadableModel> defaultModels = [
    DownloadableModel(
      name: 'Qwen 2.5 0.5B (4bit)',
      description: 'Extremely small and fast. Good for basic tasks.',
      url:
          'https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf?download=true',
      filename: 'qwen2.5-0.5b-instruct-q4_k_m.gguf',
      sizeBytes: 398000000, // Approx 400MB
    ),
    DownloadableModel(
      name: 'LFM 2.5 1.2B (4bit)',
      description: 'LiquidAI\'s efficient 1.2B model. Fast edge inference.',
      url:
          'https://huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct-GGUF/resolve/main/LFM2.5-1.2B-Instruct-Q4_K_M.gguf?download=true',
      filename: 'LFM2.5-1.2B-Instruct-Q4_K_M.gguf',
      sizeBytes: 800000000, // Approx 800MB
    ),
    DownloadableModel(
      name: 'Gemma 3 1B (4bit)',
      description:
          'Google\'s latest lightweight multimodal model. Fast and capable.',
      url:
          'https://huggingface.co/bartowski/google_gemma-3-1b-it-GGUF/resolve/main/google_gemma-3-1b-it-Q4_K_M.gguf?download=true',
      filename: 'google_gemma-3-1b-it-Q4_K_M.gguf',
      sizeBytes: 850000000, // Approx 850MB
    ),
    DownloadableModel(
      name: 'Llama 3.2 1B (4bit)',
      description: 'Meta\'s latest small model. Balanced performance.',
      url:
          'https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf?download=true',
      filename: 'Llama-3.2-1B-Instruct-Q4_K_M.gguf',
      sizeBytes: 866000000, // Approx 866MB
    ),
    DownloadableModel(
      name: 'TinyLlama 1.1B (Chat)',
      description: 'Classic tiny model.',
      url:
          'https://huggingface.co/TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF/resolve/main/tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf?download=true',
      filename: 'tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf',
      sizeBytes: 669000000, // Approx 670MB
    ),
  ];
}
