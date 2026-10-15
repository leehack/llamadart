## Unreleased

* Depends on `llamadart` within the core minor this companion pairs with,
  so pub refuses to resolve it beside a mismatched core. The Apple SwiftPM
  native pin stays `leehack/stable-diffusion-native@v0.2.0-3`.

## 0.0.3

* Updated Apple SwiftPM native pin to `leehack/stable-diffusion-native@v0.2.0-3`.

## 0.0.2

* Updated Apple SwiftPM native pin to `leehack/stable-diffusion-native@v0.2.0-1`,
  whose XCFramework carries an Apple privacy manifest and frees image models
  still allocated at process exit.

## 0.0.1

* Initial Flutter Apple SwiftPM companion package for `llamadart`
  stable-diffusion.cpp image generation.
* Updated Apple SwiftPM native pin to `leehack/stable-diffusion-native@v0.2.0`.
