# llamadart_llama_cpp_flutter

Flutter Apple Swift Package Manager companion package for
[`llamadart`](https://pub.dev/packages/llamadart) GGUF / llama.cpp support.

Add this package to a Flutter iOS/macOS app when the app should link the
prebuilt llama.cpp Apple XCFramework through SwiftPM instead of relying on the
core package's native-assets fallback.

**Unreleased coordinated upgrade:** companion `0.0.18` requires the matching
llama.cpp v0.4.0 core bindings; it is not compatible with published core
`0.8.22`. For published packages, keep core `0.8.22` with companion `0.0.17`.
The development example below requires both path overrides to the same checkout.
Publish companion `0.0.18` only with the matching next core release, and replace
these temporary overrides/version constraints during that coordinated release.

```yaml
dependencies:
  llamadart: ^0.8.22
  llamadart_llama_cpp_flutter: ^0.0.18

dependency_overrides:
  llamadart:
    path: /path/to/llamadart
  llamadart_llama_cpp_flutter:
    path: /path/to/llamadart/packages/llamadart_llama_cpp_flutter
```

This package has no runtime Dart API of its own. Import `package:llamadart`
normally from the core package and use `LlamaBackend()` / `LlamaEngine` there.

The Apple SwiftPM manifest pins `leehack/llamadart-native@v0.4.0`.

Source for this package lives in
`packages/llamadart_llama_cpp_flutter` in the
[`llamadart`](https://github.com/leehack/llamadart) repository.
