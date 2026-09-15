# llamadart_litert_lm_flutter

Flutter Apple Swift Package Manager companion package for
[`llamadart`](https://pub.dev/packages/llamadart) `.litertlm` / LiteRT-LM
support.

Add the package to a Flutter iOS app when it should link the prebuilt LiteRT-LM
Apple XCFrameworks through SwiftPM instead of relying on the core package's
native-assets fallback. Flutter macOS continues to use the core package's
complete hook-managed runtime bundle on arm64 because the core and shim
SwiftPM frameworks do not include every dynamically loaded GPU companion.
The sync tool preserves this completeness check when refreshing runtime pins.

The iOS artifacts include arm64 device and arm64 Simulator slices. Apps that
also request an x86_64 Simulator slice must exclude x86_64 for LiteRT-LM builds.

```yaml
dependencies:
  llamadart: ^0.8.23
  llamadart_litert_lm_flutter: ^0.0.10
```

This package has no runtime Dart API of its own. Import `package:llamadart`
normally from the core package and use `LlamaBackend()` / `LlamaEngine` there.

The Apple SwiftPM manifest pins `leehack/litert-lm-native@v0.17.0-1`.

Source for this package lives in
`packages/llamadart_litert_lm_flutter` in the
[`llamadart`](https://github.com/leehack/llamadart) repository.
