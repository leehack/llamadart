# llamadart_litert_lm_flutter

Flutter Apple Swift Package Manager companion package for
[`llamadart`](https://pub.dev/packages/llamadart) `.litertlm` / LiteRT-LM
support.

Add this package to a Flutter iOS/macOS app when the app should link the
prebuilt LiteRT-LM Apple XCFrameworks through SwiftPM instead of relying on the
core package's native-assets fallback.

```yaml
dependencies:
  llamadart: ^0.8.1
  llamadart_litert_lm_flutter: ^0.0.2
```

This package has no runtime Dart API of its own. Import `package:llamadart`
normally from the core package and use `LlamaBackend()` / `LlamaEngine` there.

The Apple SwiftPM manifest pins `leehack/litert-lm-native@v0.13.1-native.1`.

Source for this package lives in
`packages/llamadart_litert_lm_flutter` in the
[`llamadart`](https://github.com/leehack/llamadart) repository.
