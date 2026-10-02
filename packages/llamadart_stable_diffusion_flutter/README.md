# llamadart_stable_diffusion_flutter

Flutter Apple Swift Package Manager companion package for
[`llamadart`](https://pub.dev/packages/llamadart) image generation with
stable-diffusion.cpp.

Add this package to a Flutter iOS/macOS app that uses `ImageGenerationEngine`
to link the prebuilt stable-diffusion.cpp Apple XCFramework through SwiftPM.
Adding it opts iOS and macOS builds into that runtime, about 37 MB per Apple
target. Without it, the core package bundles the runtime through its
native-assets hook, whose iOS framework App Store Connect rejects: Flutter
writes `MinimumOSVersion` 13.0 into it, while the library requires iOS 16.4.
The hook reports this as an Xcode build warning, which Xcode and `xcodebuild`
show but plain `flutter build` and `flutter run` output does not.

Pair companion `0.0.1` with the first core release whose changelog lists
this package, or a newer one. Older cores, including `0.9.x`, ignore the
companion and keep bundling the runtime through their hook; the snippet below
tracks the current core version until that release.

```yaml
dependencies:
  llamadart: ^0.9.0
  llamadart_stable_diffusion_flutter: ^0.0.1
```

Adding the package selects the `stable_diffusion` runtime for Flutter iOS and
macOS builds; `llamadart_native_runtimes` still decides the other platforms.

This package has no runtime Dart API of its own. Import `package:llamadart`
normally from the core package and use `ImageGenerationEngine` there.

The Apple SwiftPM manifest pins `leehack/stable-diffusion-native@v0.2.0`.

Source for this package lives in
`packages/llamadart_stable_diffusion_flutter` in the
[`llamadart`](https://github.com/leehack/llamadart) repository.
