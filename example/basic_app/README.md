# llamadart CLI Chat Example

A clean, organized CLI application demonstrating the capabilities of the `llamadart` package. It supports both interactive conversation mode and single-response mode.

## Features

- **Interactive Mode**: Have a back-and-forth conversation with an LLM in your terminal.
- **Single Response Mode**: Pass a prompt as an argument for quick tasks.
- **Automatic Model Management**: Automatically downloads models from Hugging Face if a URL is provided.
- **Backend Optimization**: Defaults to GPU acceleration (Metal/Vulkan) when available.

## Usage

First, ensure you have the Dart SDK installed.

### 1. Install Dependencies

```bash
dart pub get
```

### 2. Run Interactive Mode (Default)

This will download a small default model (Qwen 2.5 0.5B) if not already present and start a chat session.

```bash
dart bin/main.dart
```

### 3. Run with a Specific Model

You can provide a local path or a Hugging Face GGUF URL.

```bash
dart bin/main.dart -m "path/to/model.gguf"
```

### 4. Single Response Mode

Useful for scripting or quick queries.

```bash
dart bin/main.dart -p "What is the capital of France?"
```

## Options

- `-m, --model`: Path or URL to the GGUF model file.
- `-p, --prompt`: Prompt for single response mode.
- `-i, --interactive`: Start in interactive mode (default if no prompt provided).
- `-h, --help`: Show help message.

## Project Structure

- **`bin/main.dart`**: The CLI entry point and user interface logic.
- **`lib/services/llama_service.dart`**: High-level wrapper for the `llamadart` engine.
- **`lib/services/model_service.dart`**: Handles model downloading and path verification.
- **`lib/models.dart`**: Data structures for the application.
