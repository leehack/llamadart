/// Native runtime release pins consumed by `hook/build.dart`.
///
/// `tool/native/sync_native_release_pins.py` rewrites this file from published
/// release metadata. Hook logic stays in `hook/build.dart`.
library;

/// `leehack/llamadart-native` release tag downloaded for the llama.cpp runtime.
const llamaCppTag = 'v1.0.0';

/// The first `llamadart_llama_cpp_flutter` release whose `Package.swift` pins
/// [llamaCppTag].
///
/// Incompatible-companion build errors name it, because a caret constraint on
/// an earlier companion can never resolve it. A core from
/// `appleCompanionLockstepStart` on names it only when it shares the core's
/// `MAJOR.MINOR`, and its own minor's first release otherwise. The native pin
/// sync sets it to the companion's next release whenever it moves the
/// companion pin.
const llamaCppAppleCompanionVersion = '0.19.12';

/// Earlier `leehack/llamadart-native` tags that a published Apple llama.cpp
/// companion pins and the build still accepts, each mapped to what its
/// frameworks lack compared with [llamaCppTag].
///
/// No older Apple runtime is admitted for v1.0.0: consumers need its ARM F16
/// accumulation fix. Native pin sync clears this map whenever the pin moves;
/// additions require exact artifact compatibility evidence and matching
/// checksums below.
const llamaCppCompatibleAppleCompanionTags = <String, String>{};

/// Exact XCFramework checksums for [llamaCppTag] and any admitted earlier
/// [llamaCppCompatibleAppleCompanionTags] entries.
///
/// Native pin sync preserves this proof on a same-tag refresh and replaces it
/// with the newly published artifact's checksum when the pin moves.
const llamaCppCompatibleAppleCompanionChecksums = <String, String>{
  'v1.0.0': 'e7223258c6d1c21686b4ee6235e82ceb2bd19e9fc1851e60e5b99556ed44112f',
};

/// SHA-256 of each published `llamadart-native-<bundle>-<llamaCppTag>.tar.gz`
/// archive, keyed by bundle.
///
/// The hook verifies a downloaded or cached archive of the pinned release
/// against this map before extracting it.
const llamaCppBundleSha256 = <String, String>{
  'android-arm64':
      '68248fa23753d4ee2f7ccacae69c49ee3006a66a86f4cddb997c02bd893b269e',
  'android-x64':
      'bc9be52c3fdf10666e1ef480268614b99e864c31897954abab25f1f78861b842',
  'ios-arm64':
      'c83b718b313fce394c68ab84d1998e29910c8f604056115a54ae2c2a3a68f891',
  'ios-arm64-sim':
      '42a1ac025abf5281f98563c73091d33b6850d6dfb561a2b2d615faa2d62a7d6d',
  'ios-x86_64-sim':
      '4c471f411e931b7fc120daa1feb63ba2e0f124b72ddee3ba3cba351e9e80f15f',
  'linux-arm64':
      '934782fe70b4c2549bd69f19e0b5df9342f6ff302e75956a63d998f596a41155',
  'linux-x64':
      '1697ef4fafb9d4f74f1310358d661dc893409cd93c6d3bb4d3d0f6b472a351af',
  'macos-arm64':
      'b92afe25836b8280ff528930f8ba2784a54db31a2cc81c7f5c41d98c96f75b27',
  'macos-x86_64':
      'f01f2ac08c1d295839154401d406ddba56bee04c8b42ef41b192440a8ef54560',
  'windows-arm64':
      'af5e6632fa6aecb136c169ddafb7c8f65f2722b3d82256892ebda4829ff74806',
  'windows-x64':
      'f0933e4bfc456ef4bfc60a6636dab3416ff3ac23d45b7cc933114bff5e806761',
};

/// The `hook_contract_version` of the [llamaCppTag] release's `assets.json`.
const llamaCppHookContractVersion = 2;

/// A backend module that [llamaCppTag] publishes as its own archive,
/// `llamadart-native-<archive>-<llamaCppTag>.tar.gz`, extracted over the
/// [bundle] archive when [backend] is selected.
class LlamaCppBackendSidecarSpec {
  /// Core bundle the sidecar extends, such as `windows-x64`.
  final String bundle;

  /// Backend the sidecar adds, such as `cuda`.
  final String backend;

  /// Archive key, such as `windows-x64-cuda12`.
  final String archive;

  /// SHA-256 of the published `.tar.gz` archive.
  final String sha256;

  /// Creates a spec for the [archive] sidecar.
  const LlamaCppBackendSidecarSpec({
    required this.bundle,
    required this.backend,
    required this.archive,
    required this.sha256,
  });
}

/// Every backend sidecar archive the [llamaCppTag] release publishes.
const llamaCppBackendSidecarSpecs = <LlamaCppBackendSidecarSpec>[
  LlamaCppBackendSidecarSpec(
    bundle: 'windows-x64',
    backend: 'cuda',
    archive: 'windows-x64-cuda12',
    sha256: '28ec4ff3f0a9dd257c8369978ea1ddc35e0d178ee68dd80501aea36825e4bc37',
  ),
];

/// `leehack/litert-lm-native` release tag downloaded for the LiteRT-LM runtime.
const liteRtLmReleaseTag = 'v0.19.1-5';

/// LiteRT-LM cache directory version derived from [liteRtLmReleaseTag].
const liteRtLmVersion = '0.19.1-5';

/// A published LiteRT-LM runtime archive and the libraries it must contain.
class LiteRtLmBundleSpec {
  /// Release bundle key such as `linux-x64`.
  final String bundle;

  /// SHA-256 of the published `.tar.gz` archive.
  final String sha256;

  /// Library file names the extracted archive must provide.
  final Set<String> requiredLibraries;

  /// Creates a spec for [bundle].
  const LiteRtLmBundleSpec(
    this.bundle, {
    required this.sha256,
    required this.requiredLibraries,
  });
}

/// Every LiteRT-LM bundle the hook can download, keyed by [LiteRtLmBundleSpec.bundle].
const liteRtLmBundleSpecs = <LiteRtLmBundleSpec>[
  LiteRtLmBundleSpec(
    'android-arm64',
    sha256: '09da4ead66bfe95d32aefb890c5b45b10074c60545b99d6c10266d054d93e55f',
    requiredLibraries: {
      'libGemmaModelConstraintProvider.so',
      'libLiteRtGpuAccelerator.so',
      'libLiteRtLm.so',
      'libLiteRtOpenClAccelerator.so',
      'libLiteRtWebGpuAccelerator.so',
      'libwebgpu_dawn.so',
    },
  ),
  LiteRtLmBundleSpec(
    'android-x64',
    sha256: 'c29c937ae7eb405dc34188fe1f63003a165146c24389dc51069d2bbe44db4d25',
    requiredLibraries: {
      'libGemmaModelConstraintProvider.so',
      'libLiteRtGpuAccelerator.so',
      'libLiteRtLm.so',
      'libLiteRtOpenClAccelerator.so',
      'libLiteRtWebGpuAccelerator.so',
      'libwebgpu_dawn.so',
    },
  ),
  LiteRtLmBundleSpec(
    'ios-arm64',
    sha256: '375201e6b8ccb33f958318dd94aad4629b09a39d7dccbf40584276222d5f0839',
    requiredLibraries: {'CLiteRTLM', 'LiteRtLm'},
  ),
  LiteRtLmBundleSpec(
    'ios-arm64-sim',
    sha256: 'd0608be33ce98fbc72892941d23eb6fb5ba0799fb9a13acb92ffb8e0200b094c',
    requiredLibraries: {'CLiteRTLM', 'LiteRtLm'},
  ),
  LiteRtLmBundleSpec(
    'macos-arm64',
    sha256: '54696ced0a18a4f081724cdbf107061ee1d91b09199e2d1cd86d795de24de691',
    requiredLibraries: {
      'libCLiteRTLM_mac.dylib',
      'libGemmaModelConstraintProvider.dylib',
      'libLiteRtLm.dylib',
      'libwebgpu_dawn.dylib',
    },
  ),
  LiteRtLmBundleSpec(
    'linux-arm64',
    sha256: '6f6814354a8b1e6e74c91056adc67f345394dd1a0c448f7448c2196cac117a88',
    requiredLibraries: {
      'libGemmaModelConstraintProvider.so',
      'libLiteRtLm.so',
      'libLiteRtWebGpuAccelerator.so',
      'libwebgpu_dawn.so',
    },
  ),
  LiteRtLmBundleSpec(
    'linux-x64',
    sha256: '5709cc8e944be2370ab91c9054fbe435f19e80a703a6567fdcd9218962daa55a',
    requiredLibraries: {
      'libGemmaModelConstraintProvider.so',
      'libLiteRtLm.so',
      'libLiteRtWebGpuAccelerator.so',
      'libwebgpu_dawn.so',
    },
  ),
  LiteRtLmBundleSpec(
    'windows-x64',
    sha256: '618b489914283dfe99bac232ba99654bef0b2c26d0a11dc3062016cddb164de5',
    requiredLibraries: {
      'LiteRtLm.dll',
      'dxcompiler.dll',
      'dxil.dll',
      'libGemmaModelConstraintProvider.dll',
      'libLiteRtWebGpuAccelerator.dll',
      'libwebgpu_dawn.dll',
      'msvcp140.dll',
      'vcruntime140.dll',
      'vcruntime140_1.dll',
      'vcruntime140_threads.dll',
      'webgpu_dawn.dll',
    },
  ),
];

/// `leehack/stable-diffusion-native` release tag downloaded for the opt-in
/// stable-diffusion.cpp runtime.
const stableDiffusionReleaseTag = 'v0.3.0-6';

/// First Apple companion release containing [stableDiffusionReleaseTag].
const stableDiffusionAppleCompanionVersion = '0.19.11';

/// Explicitly qualified older Apple SD pins that preserve existing app locks.
///
/// These builds share the pinned upstream and C ABI, not identical machine
/// code. The Dart worker rejects recorded Metal backend failures even when
/// native generation returns images; the newer native guard remains preferred.
/// Clear and requalify this map whenever [stableDiffusionReleaseTag] changes.
///
/// `v0.3.0-3` and `v0.3.0-4` share the pinned upstream and its C headers.
/// `v0.3.0-3` lacks the `sd_dart_graph_split_*` exports, which the bindings
/// load as an optional group, so it keeps the iOS full-VAE refusal; `v0.3.0-4`
/// lacks the Apple host-buffer and model-loader scratch release fixes.
const stableDiffusionCompatibleAppleCompanionTags = <String, String>{
  'v0.3.0-3':
      'the sd_dart_graph_split_* exports (iOS full-VAE decoding) and Apple host-buffer and model-loader scratch release fixes',
  'v0.3.0-4': 'the Apple host-buffer and model-loader scratch release fixes',
};

/// Checksums of the exact published XCFrameworks accepted by the SD hook.
const stableDiffusionAppleCompanionChecksums = <String, String>{
  'v0.3.0-3':
      '8f35c67f72d1d4bf86d31f20f3437d04baaf3b6ac7389908000fd166e387783f',
  'v0.3.0-4':
      '0d022638f54be80aa75fd8e73a94d139ad8887f4f3c73084501369ca5e7ac354',
  'v0.3.0-6':
      '7e5a79218d731ce7fb6b54020190a79630bd843d9a1dbafb24e5f0442ab95cb8',
};

/// stable_diffusion cache directory version derived from
/// [stableDiffusionReleaseTag].
const stableDiffusionVersion = '0.3.0-6';

/// A published stable-diffusion-native runtime archive and the library it must
/// contain under `lib/`.
class StableDiffusionBundleSpec {
  /// Release bundle key such as `linux-x64-vulkan`.
  final String bundle;

  /// SHA-256 of the published `.tar.gz` archive.
  final String sha256;

  /// Library file names the archive must provide under `lib/`.
  final Set<String> requiredLibraries;

  /// Creates a spec for [bundle].
  const StableDiffusionBundleSpec(
    this.bundle, {
    required this.sha256,
    required this.requiredLibraries,
  });
}

/// Every stable_diffusion bundle the hook can download, keyed by
/// [StableDiffusionBundleSpec.bundle].
const stableDiffusionBundleSpecs = <StableDiffusionBundleSpec>[
  StableDiffusionBundleSpec(
    'android-arm64',
    sha256: '56ab35a9e1b941fab1169b6308c0e2a1fceaea0e97499e19f849242ee2d076f8',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'ios-arm64',
    sha256: '87e5a91bf2b68fac21722aac7bc22ec265ba4946cb54a83e75e7ff3b69aaa801',
    requiredLibraries: {'libstable-diffusion.dylib'},
  ),
  StableDiffusionBundleSpec(
    'ios-arm64-sim',
    sha256: '30f65bcebf4044b87085b8c130322398d3212530ad0948e6166a11e838966731',
    requiredLibraries: {'libstable-diffusion.dylib'},
  ),
  StableDiffusionBundleSpec(
    'ios-x64-sim',
    sha256: 'ff135eca41f75798dd3edc16da31af515b10f5793d35e8d70c340f02479fdfcd',
    requiredLibraries: {'libstable-diffusion.dylib'},
  ),
  StableDiffusionBundleSpec(
    'macos-arm64',
    sha256: '2a2468ecd8aa284a093179ecf28f17e93b31d4359ab553a4010353063cb410dc',
    requiredLibraries: {'libstable-diffusion.dylib'},
  ),
  StableDiffusionBundleSpec(
    'macos-x64',
    sha256: 'e2f49a8ecbc898cfafa9feefaca1b4703f23af19e74b3b2a6bd407f8730eb8ff',
    requiredLibraries: {'libstable-diffusion.dylib'},
  ),
  StableDiffusionBundleSpec(
    'linux-arm64',
    sha256: 'd394acffe3a9de8cc86abb4f1176f1bb1b5af5ed83efc013384e2b6e220d831f',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'linux-arm64-vulkan',
    sha256: 'd2412bc1ee28dd87a353d37181c060e1e0287d37ffc6c231dae5b3b399071dab',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'linux-x64',
    sha256: '6dd33ff5cede6b9468006dcd08b6b60d5d3ac32c65863df1475942b7c6d9baac',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'linux-x64-vulkan',
    sha256: 'dda3969e18974ddd2dc110ca2576927548bcc0e9355932cd25249803ff1f816c',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'windows-x64',
    sha256: '8da3d2d03634bcd9a76e52d84d92995a02b956ed697cc23e4303f45b3d1fdc5e',
    requiredLibraries: {'stable-diffusion.dll'},
  ),
  StableDiffusionBundleSpec(
    'windows-x64-vulkan',
    sha256: 'eb15f8673c87cfbfd0a8a9f133dc96af1316bc1b58009e33f9f851e43b8d3d39',
    requiredLibraries: {'stable-diffusion.dll'},
  ),
];
