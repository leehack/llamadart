## Unreleased

* The next companion patch requires core `>=0.15.2 <0.16.0`, whose hook accepts this native pin.

* Updated Apple SwiftPM native pin to `leehack/stable-diffusion-native@v0.2.0-4`.

## 0.15.1

- Update core 0.15.1 examples; retain `leehack/stable-diffusion-native@v0.2.0-3`.

## 0.15.0

* Pair with core `0.15.x`; Apple SwiftPM stays pinned to `leehack/stable-diffusion-native@v0.2.0-3`.

## 0.14.0

* Pair with core `0.14.x`; Apple SwiftPM pins `leehack/stable-diffusion-native@v0.2.0-3`.

## 0.13.0

* Versions now share the core `MAJOR.MINOR`; this release pairs with core
  `0.13.0`.
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
