# llamadart_litert_lm_flutter

Flutter Apple Swift Package Manager companion package for
[`llamadart`](https://pub.dev/packages/llamadart) `.litertlm` / LiteRT-LM
support.

Add the published package to a Flutter iOS app when it should link the prebuilt
LiteRT-LM Apple XCFrameworks through SwiftPM instead of relying on the core
package's native-assets fallback. This unreleased source also restores the
complete macOS SwiftPM target set; published `0.0.4` still uses the core
native-assets fallback on macOS until the next companion release.

```yaml
dependencies:
  llamadart: ^0.8.14
  llamadart_litert_lm_flutter: ^0.0.4
```

This package has no runtime Dart API of its own. Import `package:llamadart`
normally from the core package and use `LlamaBackend()` / `LlamaEngine` there.

The Apple SwiftPM manifest pins `leehack/litert-lm-native@v0.14.0-native.2`.

Source for this package lives in
`packages/llamadart_litert_lm_flutter` in the
[`llamadart`](https://github.com/leehack/llamadart) repository.
