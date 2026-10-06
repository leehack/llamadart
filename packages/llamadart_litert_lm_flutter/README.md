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
tool loops and strict structured output remain unsupported. The macOS
hook-managed bundle still requires its provider.

iOS 16.4 is the declared deployment floor, not a tested one. The Swift package
requires an iOS 16.4 app target and the `v0.17.0-7` frameworks declare
`MinimumOSVersion` 15.0, but nothing has been run on iOS 16.4. On a device,
model load and generation have run only on an iPhone 16 Pro with iOS 18.3.2;
no other iOS version is device-verified
([#831](https://github.com/leehack/llamadart/issues/831)).

The LiteRT-LM frameworks include no Apple privacy manifest on either path, and
llamadart publishes no reason codes for this runtime. The `v0.17.0-7` iOS
frameworks reference
[required-reason API](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)
in three categories: File Timestamp (`stat`, `fstat`, `lstat`), System Boot
Time (`mach_absolute_time`) and User Defaults (`NSUserDefaults`, in the Metal
accelerator and sampler). An app that links LiteRT-LM declares all three in
its own `PrivacyInfo.xcprivacy`, with reasons it has verified against Apple's
list ([litert-lm-native#65](https://github.com/leehack/litert-lm-native/issues/65)).

Source for this package lives in
`packages/llamadart_litert_lm_flutter` in the
[`llamadart`](https://github.com/leehack/llamadart) repository.
