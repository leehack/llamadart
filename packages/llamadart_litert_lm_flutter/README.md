# llamadart_litert_lm_flutter

Flutter Apple Swift Package Manager companion package for
[`llamadart`](https://pub.dev/packages/llamadart) `.litertlm` / LiteRT-LM
support.

Add this package to a Flutter iOS app when the app should link the prebuilt
LiteRT-LM Apple XCFrameworks through SwiftPM instead of relying on the core
package's native-assets fallback. Flutter macOS `.litertlm` builds currently
keep the core native-assets fallback when the SwiftPM artifact set is incomplete
for the selected architecture.

```yaml
dependencies:
  llamadart: ^0.8.12
  llamadart_litert_lm_flutter: ^0.0.3
```

This package has no runtime Dart API of its own. Import `package:llamadart`
normally from the core package and use `LlamaBackend()` / `LlamaEngine` there.

The Apple SwiftPM manifest pins `leehack/litert-lm-native@v0.14.0-native.1`.

Source for this package lives in
`packages/llamadart_litert_lm_flutter` in the
[`llamadart`](https://github.com/leehack/llamadart) repository.
