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
  llamadart: ^0.10.0
  llamadart_litert_lm_flutter: ^0.0.12
```

This package has no runtime Dart API of its own. Import `package:llamadart`
normally from the core package and use `LlamaBackend()` / `LlamaEngine` there.

The Apple SwiftPM manifest pins `leehack/litert-lm-native@v0.17.0-7`.
This repository change awaits a companion package release; published `0.0.12`
retains its previous pin.

These iOS artifacts omit the Gemma FST constraint provider. Gemma 3/4 and
FunctionGemma conversations must use constrained decoding disabled, as the Dart
adapter already does. Enabling it through the native C API fails conversation
creation with a null handle and a build-time-disabled diagnostic. Ordinary
generation, thinking and best-effort tool formatting remain available; automatic
tool loops and strict structured output remain unsupported. The artifacts target
iOS 16.4, but actual runtime qualification used iOS 18.3.2, not iOS 16.4.
The macOS hook-managed bundle still requires its provider.

Source for this package lives in
`packages/llamadart_litert_lm_flutter` in the
[`llamadart`](https://github.com/leehack/llamadart) repository.
