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

Pair companion `0.14.0` with core `0.14.0`, `0.13.0` with core `0.13.x`, and `0.0.3` with core `0.12.2`,
`0.12.1` and `0.12.0`. Keep `0.0.2` with core `0.11.1` and `0.11.0`, and `0.0.1` with core `0.10.0`; older cores,
including `0.9.x`, ignore it.

```yaml
dependencies:
  llamadart: ^0.14.0
  llamadart_stable_diffusion_flutter: ^0.14.0
```

Adding the package selects the `stable_diffusion` runtime for Flutter iOS and
macOS builds; `llamadart_native_runtimes` still decides the other platforms.
A list there replaces the default `llama_cpp` and `litert_lm`:
`[llama_cpp, stable_diffusion]` ships GGUF chat and images,
`[stable_diffusion]` images only, and `[all, stable_diffusion]` every runtime.
From core `0.12.0`, `all` alone includes `stable_diffusion`; on
Flutter iOS and macOS it does so only with this package.

This package has no runtime Dart API of its own. Import `package:llamadart`
normally from the core package and use `ImageGenerationEngine` there.

The Apple SwiftPM manifest pins `leehack/stable-diffusion-native@v0.2.0-3`.

Apps bound for the App Store should use this package: an Apple privacy
manifest for the stable-diffusion.cpp runtime ships inside this XCFramework,
never in the dylibs the core package's native-assets hook bundles. The
`v0.2.0-1` XCFramework declares `NSPrivacyAccessedAPICategoryFileTimestamp`
with reasons `C617.1` and `3B52.1`; release `0.0.1` of this package links
`v0.2.0`, which has no manifest. If the embedded `stable_diffusion.framework`
in the built app has no `PrivacyInfo.xcprivacy`, or the app uses the hook
path, declare that category and those reasons in the app's own
`PrivacyInfo.xcprivacy`.

Source for this package lives in
`packages/llamadart_stable_diffusion_flutter` in the
[`llamadart`](https://github.com/leehack/llamadart) repository.

## Fresh macOS builds

Keep Runner's deployment target at macOS 14.0 or newer. If SwiftPM reports
that `FlutterGeneratedPluginSwiftPackage` supports only 12.0, follow the
[Flutter 3.47.1 consumer bootstrap](https://llamadart.leehack.com/docs/next/getting-started/installation#fresh-macos-swiftpm-bootstrap)
before the first build. It updates only the ignored generated manifest and
builds with `--no-pub`; keep this package's platform requirements, native
URLs and checksums intact.
