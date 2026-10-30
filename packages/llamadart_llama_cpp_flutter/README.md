# llamadart_llama_cpp_flutter

Flutter Apple Swift Package Manager companion package for
[`llamadart`](https://pub.dev/packages/llamadart) GGUF / llama.cpp support.

Add this package to a Flutter iOS/macOS app when the app should link the
prebuilt llama.cpp Apple XCFramework through SwiftPM instead of relying on the
core package's native-assets fallback.

Use companion `0.17.1` with core `>=0.17.1 <0.18.0` for llama.cpp `v0.8.0`.
A locked companion `0.17.0` keeps `v0.7.0-3` and works with those cores with an
upgrade warning; core `0.17.0` needs it. Core `0.17.x` rejects earlier llama.cpp
companions. Use `0.16.0` with core `0.16.x`,
or `0.15.2` with core `>=0.15.6 <0.16.0`, for llama.cpp `v0.7.0-2`.
Locked `0.15.0`/`0.15.1` companions keep `v0.7.0-1` and work with core `0.15.6`
with an upgrade warning, or pair with core `0.15.0` to `0.15.5`.
Pair companion `0.14.0` with core `0.14.x` for llama.cpp `v0.7.0`.
Use companion `0.13.0` with core `0.13.x`, or `0.0.23` with core `0.12.2`,
for llama.cpp `v0.6.0-3`. Keep `0.0.22` with core `0.12.1` and `0.12.0`
for `v0.6.0-2`.
Keep companion `0.0.21` with core `0.11.1` and `0.11.0` for llama.cpp v0.5.0
bindings, and core `0.10.0` and `0.9.0` with companion `0.0.20`,
core `0.8.23` with companion `0.0.18`, and core `0.8.22` with companion
`0.0.17`.

```yaml
dependencies:
  llamadart: ^0.17.0
  llamadart_llama_cpp_flutter: ^0.17.0
```

This package has no runtime Dart API of its own. Import `package:llamadart`
normally from the core package and use `LlamaBackend()` / `LlamaEngine` there.

The Apple SwiftPM manifest pins `leehack/llamadart-native@v0.8.0`.

Apps bound for the App Store should use this package: an Apple privacy
manifest for the llama.cpp runtime ships inside this XCFramework, never in the
dylibs the core package's native-assets fallback bundles. The `v0.5.0-2`
XCFramework declares `NSPrivacyAccessedAPICategoryFileTimestamp` with reason
`C617.1`; releases of this package up to `0.0.20` link `v0.5.0` or older,
which has no manifest. If the embedded `llama.framework` in the built app has
no `PrivacyInfo.xcprivacy`, or the app uses the fallback, declare that
category and reason in the app's own `PrivacyInfo.xcprivacy`.

Source for this package lives in
`packages/llamadart_llama_cpp_flutter` in the
[`llamadart`](https://github.com/leehack/llamadart) repository.

## Fresh macOS builds

Keep Runner's deployment target at macOS 14.0 or newer. If SwiftPM reports
that `FlutterGeneratedPluginSwiftPackage` supports only 12.0, follow the
[Flutter 3.47.1 consumer bootstrap](https://llamadart.leehack.com/docs/getting-started/installation#fresh-macos-swiftpm-bootstrap)
before the first build. It updates only the ignored generated manifest and
builds with `--no-pub`; keep this package's platform requirements, native
URLs and checksums intact.
