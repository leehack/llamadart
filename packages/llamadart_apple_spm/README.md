# llamadart_apple_spm

Apple-only Flutter plugin that links official llama.cpp and LiteRT-LM
XCFramework releases through Swift Package Manager.

Add this package next to `llamadart` in a Flutter app to use the thin Apple
runtime path. It is required for iOS builds; the `llamadart` build hook
auto-detects this package and switches iOS/macOS native assets to process-symbol
lookup.

The linked Apple binaries are pinned in `darwin/llamadart_apple_spm/Package.swift`.
The current pins use official upstream artifacts:

- `llama.cpp` `b9371`
- `CLiteRTLM` `v0.13.1`

## Platform floors

The wrapper follows the strictest upstream Apple deployment target:

- iOS `16.4`, from the official `llama.cpp` XCFramework
- macOS `13.3`, from the official `llama.cpp` XCFramework

`CLiteRTLM` is lower (`iOS 15.0` and macOS `12.0`), but a combined package must
use the higher llama.cpp floor.

## Customization

This SPM path keeps package customization, but it moves the customization point
from the Dart build hook to Swift Package Manager:

- To use a different llama.cpp or LiteRT-LM binary release, edit this package's
  `Package.swift` URL/checksum pins, or publish a sibling companion package with
  different pins.
- To use locally built Apple binaries, replace the binary targets with local
  binary targets or a local package dependency.
- macOS native-assets builds that do not use Flutter/SPM can omit this package.
  iOS builds fail fast without it to avoid App Store `MinimumOSVersion`
  mismatches from the old hook-managed wrapper path.

The Dart build hook cannot rewrite SPM binary target URLs or checksums at build
time. It still controls non-Apple native bundles, macOS fallback mode, and the
runtime selection surface (`llama_cpp`, `litert_lm`, or both).

## LiteRT-LM backend note

The official iOS `CLiteRTLM` artifact currently exposes CPU through llamadart's
native backend selection. macOS exposes CPU and GPU. Requesting iOS GPU will be
rejected by the runtime backend availability check instead of silently falling
back.
