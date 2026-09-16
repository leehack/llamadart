# llamadart_litert_lm_flutter

Flutter Apple Swift Package Manager companion package for
[`llamadart`](https://pub.dev/packages/llamadart) `.litertlm` / LiteRT-LM
support.

Add the package to a Flutter iOS app when it should link the prebuilt LiteRT-LM
Apple XCFrameworks through SwiftPM instead of relying on the core package's
native-assets fallback. Flutter macOS continues to use the core package's
hook-managed runtime bundle for the complete GPU companion inventory. The
SwiftPM package links the shared runtime and macOS compatibility shim, but
those two frameworks alone do not provide the complete macOS runtime.

The iOS artifacts include arm64 device and arm64 Simulator slices. Apps that
also request an x86_64 Simulator slice must exclude x86_64 for LiteRT-LM builds.

```yaml
dependencies:
  llamadart: ^0.8.23
  llamadart_litert_lm_flutter: ^0.0.10
```

This package has no runtime Dart API of its own. Import `package:llamadart`
normally from the core package and use `LlamaBackend()` / `LlamaEngine` there.

The Apple SwiftPM manifest pins `leehack/litert-lm-native@v0.17.0-3`.

Source for this package lives in
`packages/llamadart_litert_lm_flutter` in the
[`llamadart`](https://github.com/leehack/llamadart) repository.
