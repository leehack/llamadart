# llamadart_llama_cpp_flutter

Flutter Apple Swift Package Manager companion package for
[`llamadart`](https://pub.dev/packages/llamadart) GGUF / llama.cpp support.

Add this package to a Flutter iOS/macOS app when the app should link the
prebuilt llama.cpp Apple XCFramework through SwiftPM instead of relying on the
core package's native-assets fallback.

```yaml
dependencies:
  llamadart: ^0.8.0
  llamadart_llama_cpp_flutter: ^0.0.2
```

This package has no runtime Dart API of its own. Import `package:llamadart`
normally from the core package and use `LlamaBackend()` / `LlamaEngine` there.

The Apple SwiftPM manifest pins `leehack/llamadart-native@b9587`.

Source for this package lives in
`packages/llamadart_llama_cpp_flutter` in the
[`llamadart`](https://github.com/leehack/llamadart) repository.
