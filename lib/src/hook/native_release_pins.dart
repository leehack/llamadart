/// Native runtime release pins consumed by `hook/build.dart`.
///
/// `tool/native/sync_native_release_pins.py` rewrites this file from published
/// release metadata. Hook logic stays in `hook/build.dart`.
library;

/// `leehack/llamadart-native` release tag downloaded for the llama.cpp runtime.
const llamaCppTag = 'v0.9.0';

/// The first `llamadart_llama_cpp_flutter` release whose `Package.swift` pins
/// [llamaCppTag].
///
/// Incompatible-companion build errors name it, because a caret constraint on
/// an earlier companion can never resolve it. A core from
/// `appleCompanionLockstepStart` on names it only when it shares the core's
/// `MAJOR.MINOR`, and its own minor's first release otherwise. The native pin
/// sync sets it to the companion's next release whenever it moves the
/// companion pin.
const llamaCppAppleCompanionVersion = '0.19.0';

/// Earlier `leehack/llamadart-native` tags that a published Apple llama.cpp
/// companion pins and the build still accepts, each mapped to what its
/// frameworks lack compared with [llamaCppTag].
///
/// No older Apple runtime is admitted for v0.9.0: consumers need its ARM F16
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
  'v0.9.0': 'b0005b1da364f9ea4345218b8d53d78d6de888f301c6defb44b08321e136ac2e',
};

/// SHA-256 of each published `llamadart-native-<bundle>-<llamaCppTag>.tar.gz`
/// archive, keyed by bundle.
///
/// The hook verifies a downloaded or cached archive of the pinned release
/// against this map before extracting it.
const llamaCppBundleSha256 = <String, String>{
  'android-arm64':
      'd3c933a63e8ccaafeee32edd30685fdccd17c05e54b75895282f01fe74914a1b',
  'android-x64':
      'e86181d67997c25704f84a39fdf268f3622491a481149a39079c90323d208132',
  'ios-arm64':
      'a1dc8707568e6dc92ea44caf63489c23b86f7bf51d367ae8bfff84cc333f18b3',
  'ios-arm64-sim':
      '1744bb7220e11b1b3f7ccf3e788e03695f1cce6e4009729d87bd3c4098dd8e99',
  'ios-x86_64-sim':
      '0e373a49f8d7740466534c8c5106bf3182579cfdd8f11b5c377e942e23867fdb',
  'linux-arm64':
      '7706ea759d93f2ea20e013c4531edd4223b9f290961eac229c1967e6b2f1fa1d',
  'linux-x64':
      '92662cc83d076590d1b3785b349f0f1d20233c40c2247e9c00d1296446ec5729',
  'macos-arm64':
      '7ec293c79fc4a1ba74e367b31567a6eed616ce2d37b4d3eedc4fd67b998182e8',
  'macos-x86_64':
      '1c033603f99ca3b9a7aca96c98ecefea2043c7729e65f711a380240fb556ae1b',
  'windows-arm64':
      '464cd1b5d0637c85d248361ab27de9ae977d0e05b4079a6731c76e61ab9a06b9',
  'windows-x64':
      '970c019489aa4e698c915a9e54f82cf0328facd93f2cd9fc9b1394ea81141693',
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
    sha256: 'faa8eb0cadf3dfd22b4f4052b6460c9f1f87a00853c6237e516d88867bdb4a00',
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
const stableDiffusionReleaseTag = 'v0.3.0-4';

/// First Apple companion release containing [stableDiffusionReleaseTag].
const stableDiffusionAppleCompanionVersion = '0.19.10';

/// Explicitly qualified older Apple SD pins that preserve existing app locks.
///
/// These builds share the pinned upstream and C ABI, not identical machine
/// code. The Dart worker rejects recorded Metal backend failures even when
/// native generation returns images; the newer native guard remains preferred.
/// Clear and requalify this map whenever [stableDiffusionReleaseTag] changes.
///
/// `v0.3.0-3` has the same upstream as `v0.3.0-4` and lacks only the
/// `sd_dart_graph_split_*` exports, which the bindings load as an optional
/// group, so an older framework keeps the iOS full-VAE refusal.
const stableDiffusionCompatibleAppleCompanionTags = <String, String>{
  'v0.3.0-3': 'the sd_dart_graph_split_* exports (iOS full-VAE decoding)',
};

/// Checksums of the exact published XCFrameworks accepted by the SD hook.
const stableDiffusionAppleCompanionChecksums = <String, String>{
  'v0.3.0-3':
      '8f35c67f72d1d4bf86d31f20f3437d04baaf3b6ac7389908000fd166e387783f',
  'v0.3.0-4':
      '0d022638f54be80aa75fd8e73a94d139ad8887f4f3c73084501369ca5e7ac354',
};

/// stable_diffusion cache directory version derived from
/// [stableDiffusionReleaseTag].
const stableDiffusionVersion = '0.3.0-4';

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
    sha256: 'fdc1a614bc7b50d838dfee4416a8ffea04eb01a0042f2d65821e80225e4000cd',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'ios-arm64',
    sha256: 'c24c7df0a7c21370d026668cd12a98baf646d7951829088e6957f25ad13cdce9',
    requiredLibraries: {'libstable-diffusion.dylib'},
  ),
  StableDiffusionBundleSpec(
    'ios-arm64-sim',
    sha256: 'be5ab833a7a902ba75bce16c3020565372bef672106e5b91a2d9bcb7e85d0fb2',
    requiredLibraries: {'libstable-diffusion.dylib'},
  ),
  StableDiffusionBundleSpec(
    'ios-x64-sim',
    sha256: 'eae74517da056d3cd44964a5ada097b4ec58158be4978721efdb9801d90e7540',
    requiredLibraries: {'libstable-diffusion.dylib'},
  ),
  StableDiffusionBundleSpec(
    'macos-arm64',
    sha256: 'd34dbaf3c9ecfbbaa97e1c89687e27cefdae824ed27a1a8cf694a9c9489d3eae',
    requiredLibraries: {'libstable-diffusion.dylib'},
  ),
  StableDiffusionBundleSpec(
    'macos-x64',
    sha256: '7f5954264d0e904a5049822e320eb6b06696c38a59428868537915b439eec478',
    requiredLibraries: {'libstable-diffusion.dylib'},
  ),
  StableDiffusionBundleSpec(
    'linux-arm64',
    sha256: '71277d3a6f2c3a500b69fae829318c19ef00ed035a86cef09215865167b354a4',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'linux-arm64-vulkan',
    sha256: '58b362b189473334d3ca92f40eb998228ef723b740efc1f1d9b885c7ad711be6',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'linux-x64',
    sha256: '4b5405c319f500d1190e2e363386d561484ebcc88fe41cdfb6fa67fe863e68f4',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'linux-x64-vulkan',
    sha256: '43c3331afc6c72dd5ac16eef6625abdbc8fbed29544b442d3299e11c36d1caba',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'windows-x64',
    sha256: '5eff9c03d5a8b13412df02816d451b9f5e53aba689d8b65118cc2e4862dd1848',
    requiredLibraries: {'stable-diffusion.dll'},
  ),
  StableDiffusionBundleSpec(
    'windows-x64-vulkan',
    sha256: '19351af58dc09ee6d66b2b09b3206518a4920e28377c86a5f1ebf2fb8dfac8c4',
    requiredLibraries: {'stable-diffusion.dll'},
  ),
];
