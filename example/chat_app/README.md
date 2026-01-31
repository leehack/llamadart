# llamadart Chat Example

A Flutter chat application demonstrating real-world usage of llamadart with UI.

## Features

- 🦙 Real-time chat with local LLM
- 📱 Material Design 3 UI
- ⚙️ Model configuration (path, backend selection)
- 💾 Settings persistence
- 🔄 Streaming generation
- 🎨 User and AI message bubbles

## Setup

### 1. Run the App
```bash
cd example/chat_app
flutter pub get
flutter run
```

### 2. Choose and Download a Model
1. The app will open to a **Model Selection** screen.
2. Select one of the pre-configured models (e.g., Qwen 2.5 0.5B).
3. Tap the **Download** icon. The app uses `Dio` to download the model directly to your device's documents directory.
4. Once downloaded, tap **Select** to load the model.

### 3. Advanced Configuration (Optional)
1. Tap the settings icon (⚙️) in the app bar.
2. Adjust **GPU Layers**, **Context Size**, or **Preferred Backend**.
3. Tap **Load Model** to apply changes.


## Testing Scenarios

### Scenario 1: Fresh Install
1. Install the app
2. Model not loaded -> Show welcome screen
3. Configure and load model
4. Verify it works

### Scenario 2: App Restart
1. Load model and chat
2. Close and reopen app
3. Verify settings persist
4. Verify model reloads automatically

### Scenario 3: Offline Mode
1. Use app once (downloads libraries)
2. Disconnect internet
3. Restart app
4. Verify it works offline

### Scenario 4: Multiple Messages
1. Load model
2. Send multiple messages
3. Verify responses
4. Check context is maintained

## Architecture

The app follows a clean, layered architecture with strict separation of concerns:

```
lib/
├── main.dart              # App entry point
├── screens/
│   ├── chat_screen.dart            # Main chat screen
│   └── model_selection_screen.dart  # Model management UI
├── widgets/
│   ├── chat_input.dart             # Message input area
│   ├── message_bubble.dart         # Styled chat bubbles
│   ├── settings_sheet.dart         # Advanced config UI
│   └── ...                         # Other modular UI components
├── providers/
│   └── chat_provider.dart          # App state & orchestration
├── services/
│   ├── chat_service.dart           # Business logic & prompt building
│   ├── model_service.dart          # File system & download logic
│   └── settings_service.dart       # Local persistence (SharedPreferences)
├── models/
│   ├── chat_message.dart           # Message data with token caching
│   ├── chat_settings.dart          # Configuration data
│   └── downloadable_model.dart     # Model metadata
└── stub/
    └── io_stub.dart                # Web compatibility stubs
```

### Key Components

- **`ChatProvider`**: Orchestrates state and reacts to user input.
- **`ChatService`**: Handles prompt construction, token counting, and engine interaction.
- **`ModelService`**: Manages the local model library and background downloads.
- **`SettingsService`**: Handles persistent storage of user preferences.
- **`ChatMessage`**: Implements **Token Caching** to optimize performance during long conversations.

## Code Examples

### Loading a Model
```dart
final service = LlamaService();
await service.init(
  modelPath,
  modelParams: ModelParams(
    gpuLayers: 99, // Offload all layers for best performance on GPU
    contextSize: 2048,
    preferredBackend: GpuBackend.auto,
    loras: [], // Optional LoRA adapters
  ),
);
```

### Sending a Message
```dart
final stream = service.generate(
  userMessage,
  params: GenerationParams(
    maxTokens: 128,
    temp: 0.7,
  ),
);

await for (final token in stream) {
  print(token);
}
```

### Persisting Settings
```dart
final prefs = await SharedPreferences.getInstance();
await prefs.setString('model_path', modelPath);
await prefs.setInt('preferred_backend', backendIndex);
```

## Screenshots

_(Add screenshots here when complete)_

## Troubleshooting

**"Failed to load library" or "Native asset not found" on first run:**
- Ensure you have an active internet connection. The `llamadart` build hook needs to download the pre-compiled `llama.cpp` binary for your platform.
- Check the console for download progress logs.
- If behind a proxy, ensure Dart/Flutter can access GitHub.

**"Model file not found" error:**
- Ensure you have successfully downloaded a model from the selection screen.
- If you manually moved a model, verify the path in the settings sheet.

**Slow generation:**
- Ensure hardware acceleration is enabled (e.g., Metal on Apple, Vulkan on Android/Linux/Windows).
- Check if `GPU Layers` is set to a high enough value (default 99 offloads all layers).
- Use a model with a smaller quantization level (e.g., Q4_K_M).


**App crashes on startup:**
- Check console output for error messages
- Verify llamadart dependency is correctly configured
- Ensure Flutter version >= 3.10.0

## Tech Stack

- **llamadart** - High-performance LLM inference
- **Provider** - Reactive state management
- **Dio** - Robust background downloads
- **SharedPreferences** - Persistent settings
- **Material Design 3** - Modern UI components
- **Google Fonts** - Typography

## Platform Support

| Platform | Status | Hardware Acceleration |
|----------|--------|-----------------------|
| macOS    | ✅ Tested | Metal |
| iOS      | ✅ Tested | Metal |
| Android  | ✅ Tested | Vulkan |
| Linux    | 🟡 Expected | Vulkan |
| Windows  | ✅ Tested | Vulkan |
| Web      | ✅ Tested | CPU (Wasm) |


## Future Enhancements (Implemented ✅)

- [x] Conversation history maintenance
- [x] Multiple model support & switching
- [x] Professional layered architecture
- [x] Real-time streaming UI
- [x] Persistent settings & log control
- [x] Advanced sampling parameters (Temp/Top-K/Top-P)
