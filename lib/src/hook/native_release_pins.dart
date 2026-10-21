/// Native runtime release pins consumed by `hook/build.dart`.
///
/// `tool/native/sync_native_release_pins.py` rewrites this file from published
/// release metadata. Hook logic stays in `hook/build.dart`.
library;

/// `leehack/llamadart-native` release tag downloaded for the llama.cpp runtime.
const llamaCppTag = 'v0.7.0-2';

/// The first `llamadart_llama_cpp_flutter` release whose `Package.swift` pins
/// [llamaCppTag].
///
/// Incompatible-companion build errors name it, because a caret constraint on
/// an earlier companion can never resolve it. A core from
/// `appleCompanionLockstepStart` on names it only when it shares the core's
/// `MAJOR.MINOR`, and its own minor's first release otherwise. The native pin
/// sync sets it to the companion's next release whenever it moves the
/// companion pin.
const llamaCppAppleCompanionVersion = '0.15.2';

/// Earlier `leehack/llamadart-native` tags that a published Apple llama.cpp
/// companion pins and the build still accepts, each mapped to what its
/// frameworks lack compared with [llamaCppTag].
///
/// Every entry must be a wrapper rebuild of the same upstream llama.cpp
/// release as [llamaCppTag]: the same `vMAJOR.MINOR.PATCH` prefix, which the
/// native release manifest binds to one upstream commit, with the same header
/// declarations and the same exported symbols on every framework slice, so
/// its frameworks are ABI- and symbol-identical to the ones the Dart bindings
/// expect. `test/fixtures/native/llama_cpp_apple_compatibility.json` records
/// that comparison for the exact XCFramework checksums. The build accepts
/// such a companion with a warning. The native pin sync clears this map
/// whenever it moves [llamaCppTag], because each entry is verified against
/// one pin.
const llamaCppCompatibleAppleCompanionTags = <String, String>{
  'v0.7.0-1': 'the fix that seeds every Qwen3-TTS codebook from the request',
};

/// The exact XCFramework checksum a companion pinning each
/// [llamaCppCompatibleAppleCompanionTags] entry must declare.
///
/// A tag alone establishes no ABI compatibility, so the build rejects a
/// compatible tag whose checksum is missing here or differs. The native pin
/// sync clears it together with [llamaCppCompatibleAppleCompanionTags].
const llamaCppCompatibleAppleCompanionChecksums = <String, String>{
  'v0.7.0-1':
      '90fee6868a611c5b053179e6944baba36975cf0d91b5e9888f51e03a74b4cbe0',
};

/// SHA-256 of each published `llamadart-native-<bundle>-<llamaCppTag>.tar.gz`
/// archive, keyed by bundle.
///
/// The hook verifies a downloaded or cached archive of the pinned release
/// against this map before extracting it.
const llamaCppBundleSha256 = <String, String>{
  'android-arm64':
      '72fd7d6ed2bec218cbc23901b6c82fc7ddaac989d7ea287a1054d3e20c538a89',
  'android-x64':
      'ee3d096f214d1790c34c516b511f0386cefc9a52ed19024573b0cc2f62873026',
  'ios-arm64':
      'fb9fb1ce49c1a91a07da4baadb7abaddc47ed172ec45cc5da21350a05c6971f0',
  'ios-arm64-sim':
      '8d0f8aad3ae3b854b809c3f7d3d8e1c0b97e10c4b850f0f8bac36d76394aecdc',
  'ios-x86_64-sim':
      '471e62bd3b07c626e0499ed5679cadf10fbf81c35e0d7ad6c63acc4e32fe88b7',
  'linux-arm64':
      'e491a5300b2994774c7cc130ec20ad75f0ac0d9db8e08698e47f6382e09cb6b7',
  'linux-x64':
      '2c3671399545c409b69707aca04a85c46b1f9cceb8020c234b392104a299652b',
  'macos-arm64':
      'c57c9e2cff650ba0f34844b99a5dbcf70fb6358899792ac117f4ddf028ede718',
  'macos-x86_64':
      'd840fec8eb5846b88f17e8f0041b3418a24cf5c7f566787fd7572f03ebc58f91',
  'windows-arm64':
      'bbea24506fe5551d092a0efb5a6dc3915a066f5a80a62cab9e24d5f5af97dcbd',
  'windows-x64':
      '0bec255d9336eab934f601408f2871b53f83a29432587e01b0fa71a4d33840e2',
};

/// `leehack/litert-lm-native` release tag downloaded for the LiteRT-LM runtime.
const liteRtLmReleaseTag = 'v0.18.0-3';

/// LiteRT-LM cache directory version derived from [liteRtLmReleaseTag].
const liteRtLmVersion = '0.18.0-3';

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
    sha256: '99bec56a402a53901ee3c9ced1234a53e1038aec2ce8300db35d9270e286c131',
    requiredLibraries: {
      'libGemmaModelConstraintProvider.so',
      'libLiteRtGpuAccelerator.so',
      'libLiteRtLm.so',
      'libLiteRtOpenClAccelerator.so',
      'libLiteRtTopKOpenClSampler.so',
      'libLiteRtTopKWebGpuSampler.so',
      'libLiteRtWebGpuAccelerator.so',
      'libwebgpu_dawn.so',
    },
  ),
  LiteRtLmBundleSpec(
    'android-x64',
    sha256: '3dd596c6f4cfa4d9986c51a95ab77e6c70d7910397cddf3647f89911aa12c480',
    requiredLibraries: {
      'libGemmaModelConstraintProvider.so',
      'libLiteRtGpuAccelerator.so',
      'libLiteRtLm.so',
      'libLiteRtOpenClAccelerator.so',
      'libLiteRtTopKOpenClSampler.so',
      'libLiteRtTopKWebGpuSampler.so',
      'libLiteRtWebGpuAccelerator.so',
      'libwebgpu_dawn.so',
    },
  ),
  LiteRtLmBundleSpec(
    'ios-arm64',
    sha256: '21d4d730466de7aa64601b4a677f14bed579631354303dbe5ead295c6a6a3c6b',
    requiredLibraries: {
      'CLiteRTLM',
      'LiteRtLm',
      'LiteRtMetalAccelerator',
      'LiteRtTopKMetalSampler',
    },
  ),
  LiteRtLmBundleSpec(
    'ios-arm64-sim',
    sha256: '06942fd284de5422f0670f14059ca69cbcee72067aef0e9811d825965a47deb2',
    requiredLibraries: {
      'CLiteRTLM',
      'LiteRtLm',
      'LiteRtMetalAccelerator',
      'LiteRtTopKMetalSampler',
    },
  ),
  LiteRtLmBundleSpec(
    'macos-arm64',
    sha256: '4197578f3f13c2b1bcbfcbccb55fd0a72bbad11a596eea0bcb278047955e7790',
    requiredLibraries: {
      'libCLiteRTLM_mac.dylib',
      'libGemmaModelConstraintProvider.dylib',
      'libLiteRt.dylib',
      'libLiteRtLm.dylib',
      'libLiteRtMetalAccelerator.dylib',
      'libLiteRtTopKMetalSampler.dylib',
      'libLiteRtTopKWebGpuSampler.dylib',
      'libLiteRtWebGpuAccelerator.dylib',
      'libwebgpu_dawn.dylib',
    },
  ),
  LiteRtLmBundleSpec(
    'linux-arm64',
    sha256: '1a0a6f472628d2fd70a34a878974b9d0565668f6acf9ae1e208412428addbc0a',
    requiredLibraries: {
      'libGemmaModelConstraintProvider.so',
      'libLiteRt.so',
      'libLiteRtLm.so',
      'libLiteRtTopKWebGpuSampler.so',
      'libLiteRtWebGpuAccelerator.so',
      'libwebgpu_dawn.so',
    },
  ),
  LiteRtLmBundleSpec(
    'linux-x64',
    sha256: '18ee2e30d8b82d43218bec78b28a358e67a342b57f6cbddffc1aa8af77411836',
    requiredLibraries: {
      'libGemmaModelConstraintProvider.so',
      'libLiteRt.so',
      'libLiteRtLm.so',
      'libLiteRtTopKWebGpuSampler.so',
      'libLiteRtWebGpuAccelerator.so',
      'libwebgpu_dawn.so',
    },
  ),
  LiteRtLmBundleSpec(
    'windows-x64',
    sha256: '62ca2f55894f15c45e48cc8a2cb1d1a183a8ca6eefb3f316e5c6b640ef43cd87',
    requiredLibraries: {
      'LiteRtLm.dll',
      'dxcompiler.dll',
      'dxil.dll',
      'libGemmaModelConstraintProvider.dll',
      'libLiteRt.dll',
      'libLiteRtTopKWebGpuSampler.dll',
      'libLiteRtWebGpuAccelerator.dll',
      'libwebgpu_dawn.dll',
      'webgpu_dawn.dll',
    },
  ),
];

/// `leehack/stable-diffusion-native` release tag downloaded for the opt-in
/// stable-diffusion.cpp runtime.
const stableDiffusionReleaseTag = 'v0.2.0-4';

/// First Apple companion release containing [stableDiffusionReleaseTag].
const stableDiffusionAppleCompanionVersion = '0.15.2';

/// Explicitly qualified older Apple SD pins that preserve existing app locks.
///
/// These builds share the pinned upstream and C ABI, not identical machine
/// code. The Dart worker rejects recorded Metal backend failures even when
/// native generation returns images; the newer native guard remains preferred.
/// Clear and requalify this map whenever [stableDiffusionReleaseTag] changes.
const stableDiffusionCompatibleAppleCompanionTags = <String, String>{
  'v0.2.0-3':
      'the native Metal command-buffer/VAE failure guard in v0.2.0-4; '
      'Dart rejects recorded Metal backend errors, but this older native '
      'payload is not upgraded by updating the core alone',
};

/// Checksums of the exact published XCFrameworks accepted by the SD hook.
const stableDiffusionAppleCompanionChecksums = <String, String>{
  'v0.2.0-3':
      '0d496cb8f16cf11c99ac4612b47781e1f01cfe727b402936c6a2308e628688f5',
  'v0.2.0-4':
      '24b5fe8b0203ab7e35eb3e103fe18305aff82cfe57376a49d128135abe89d00b',
};

/// stable_diffusion cache directory version derived from
/// [stableDiffusionReleaseTag].
const stableDiffusionVersion = '0.2.0-4';

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
    sha256: 'b46613bc6ec68e13d81fa6247b4620effccee882b008164bf31040b34e4d175d',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'ios-arm64',
    sha256: '1045743a2cd1465ea0c9140502ea9819b746f1ec2185ad16fe2e49691e04f646',
    requiredLibraries: {'libstable-diffusion.dylib'},
  ),
  StableDiffusionBundleSpec(
    'ios-arm64-sim',
    sha256: '9d4f1b9523e72d854866fb66ca73ceaa41dc07bedad1bc772c9ac77b25c94a65',
    requiredLibraries: {'libstable-diffusion.dylib'},
  ),
  StableDiffusionBundleSpec(
    'ios-x64-sim',
    sha256: '1f2999fd7dea328429e521628bc738067e7a4051aac1ffc2472936fde7ffece9',
    requiredLibraries: {'libstable-diffusion.dylib'},
  ),
  StableDiffusionBundleSpec(
    'macos-arm64',
    sha256: '840df6e27e1cac6d378dd5529f7c3b8d3b176417f950ef523c3535c09c92f528',
    requiredLibraries: {'libstable-diffusion.dylib'},
  ),
  StableDiffusionBundleSpec(
    'macos-x64',
    sha256: 'b90cf445c63e5d00197ae11b2d554dd25c982046fe1f3da3a043cbd43dc9cf1c',
    requiredLibraries: {'libstable-diffusion.dylib'},
  ),
  StableDiffusionBundleSpec(
    'linux-arm64',
    sha256: 'a563cf3b90cba8517d35b16d8f7c5899e889e396a9274fe40d8d81339b5c26ac',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'linux-arm64-vulkan',
    sha256: 'f84350026774769a55114324b089c1d7955e70e1565206b3e896fa9c0f77edbf',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'linux-x64',
    sha256: '35a5ad38b801f8e04f440509f526b7c396809608181400238b0adbc0a4941b95',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'linux-x64-vulkan',
    sha256: 'fd49fc570fb02fecacfcaefd2bb8de66f205797b7b7795960deb983c9d298b20',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'windows-x64',
    sha256: '94a26f128a97f7a94ea645ecf3fc83b303ef51a1a184c3a3c77c8466f1ebe4c2',
    requiredLibraries: {'stable-diffusion.dll'},
  ),
  StableDiffusionBundleSpec(
    'windows-x64-vulkan',
    sha256: '67cdb87c47be5e8878d1dab065c3c1311abd1e9b72a893610c9130dfecdd3c5b',
    requiredLibraries: {'stable-diffusion.dll'},
  ),
];
