# llamadart_llama_cpp_flutter

Flutter Apple Swift Package Manager companion package for
[`llamadart`](https://pub.dev/packages/llamadart) GGUF / llama.cpp support.

Add this package to a Flutter iOS/macOS app when the app should link the
prebuilt llama.cpp Apple XCFramework through SwiftPM instead of relying on the
core package's native-assets fallback.

Pair companion `0.0.20` with core `0.10.0` for matching llama.cpp v0.5.0
bindings. Keep core `0.8.23` paired with companion `0.0.18`, and core `0.8.22`
paired with companion `0.0.17`.

```yaml
dependencies:
  llamadart: ^0.10.0
  llamadart_llama_cpp_flutter: ^0.0.20
```

This package has no runtime Dart API of its own. Import `package:llamadart`
normally from the core package and use `LlamaBackend()` / `LlamaEngine` there.

The Apple SwiftPM manifest pins `leehack/llamadart-native@v0.5.0-1`.

Apps bound for the App Store should use this package: an Apple privacy
manifest for the llama.cpp runtime ships inside this XCFramework, never in the
dylibs the core package's native-assets fallback bundles. The `v0.5.0-1`
XCFramework declares `NSPrivacyAccessedAPICategoryFileTimestamp` with reason
`C617.1`; releases of this package up to `0.0.20` link `v0.5.0` or older,
which has no manifest. If the embedded `llama.framework` in the built app has
no `PrivacyInfo.xcprivacy`, or the app uses the fallback, declare that
category and reason in the app's own `PrivacyInfo.xcprivacy`.

Source for this package lives in
`packages/llamadart_llama_cpp_flutter` in the
[`llamadart`](https://github.com/leehack/llamadart) repository.
