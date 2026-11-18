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
const stableDiffusionReleaseTag = 'v0.4.0';

/// First Apple companion release containing [stableDiffusionReleaseTag].
const stableDiffusionAppleCompanionVersion = '0.20.0';

/// Explicitly qualified older Apple SD pins that preserve existing app locks.
///
/// The v0.4.0 image generation parameter layout is incompatible with the
/// v0.3.0 line. Clear and requalify this map whenever
/// [stableDiffusionReleaseTag] changes.
const stableDiffusionCompatibleAppleCompanionTags = <String, String>{};

/// Checksums of the exact published XCFrameworks accepted by the SD hook.
const stableDiffusionAppleCompanionChecksums = <String, String>{
  'v0.4.0': '3a9d99a0f818c1511c62b585d3170c41c68f35756143979fe29f4a476bece3ce',
};

/// stable_diffusion cache directory version derived from
/// [stableDiffusionReleaseTag].
const stableDiffusionVersion = '0.4.0';

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
    sha256: 'b9f0e9b7b6daf62f48457cb36465397a8a7805cef3317a9b0a4cd5f3f20ea45b',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'ios-arm64',
    sha256: '21ea0cdd69545445d8f5e9579e300a415db6859437f5b92c8d78717ebaa82d25',
    requiredLibraries: {'libstable-diffusion.dylib'},
  ),
  StableDiffusionBundleSpec(
    'ios-arm64-sim',
    sha256: '84554867c86eb439ef4929722a9af75950b5c365f66c9691adadbe2ad2de84cc',
    requiredLibraries: {'libstable-diffusion.dylib'},
  ),
  StableDiffusionBundleSpec(
    'ios-x64-sim',
    sha256: '73a1264dc7f396ad62f8765eeef48afd4ff26014204842c869ea524e909a5d4e',
    requiredLibraries: {'libstable-diffusion.dylib'},
  ),
  StableDiffusionBundleSpec(
    'macos-arm64',
    sha256: 'db386420ccd34b07dbd4ef5c943e49c04c7965a96aa32d437eac524a968893c6',
    requiredLibraries: {'libstable-diffusion.dylib'},
  ),
  StableDiffusionBundleSpec(
    'macos-x64',
    sha256: 'cfd5228df4eea3706187fb8faf1afb2221e8537582f52e3cb9d3d553c6cda9ff',
    requiredLibraries: {'libstable-diffusion.dylib'},
  ),
  StableDiffusionBundleSpec(
    'linux-arm64',
    sha256: 'c6fd70911050931e6cfbae311fd6f9e40a2bd7b93f4740c4f56b15952f431747',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'linux-arm64-vulkan',
    sha256: 'e2c253e056f4c7a605d334a67f2d845d7b23371ba0f69ead42e2d5e9f5abc148',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'linux-x64',
    sha256: '97eed4c3a181d28b167c55b1b132d8e6ea75e14f0f4712b921eade086d437fc9',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'linux-x64-vulkan',
    sha256: '63637887575783b121d0cd0f00bbcbe2f72a3f22ffa550a9f5ea30820d079f9a',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'windows-x64',
    sha256: '9e807c03805475edebb88ee3675f06d79823dbe5696565517cf473f43b941c60',
    requiredLibraries: {'stable-diffusion.dll'},
  ),
  StableDiffusionBundleSpec(
    'windows-x64-vulkan',
    sha256: 'cca8b94826f60bc172007acc44f15984fe233f8007120c3def572f14b074194f',
    requiredLibraries: {'stable-diffusion.dll'},
  ),
];
