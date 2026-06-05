// swift-tools-version: 5.9
import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let artifactsRoot = packageRoot.appendingPathComponent("Artifacts")
let llamaCppTag = "b9536"
let liteRtLmTag = "v0.13.1"

func localArtifactPath(_ name: String) -> String? {
    let path = artifactsRoot.appendingPathComponent(name).path
    return FileManager.default.fileExists(atPath: path) ? "Artifacts/\(name)" : nil
}

func nativeRepoBinaryTarget(
    name: String,
    repository: String,
    artifactName: String,
    tag: String,
    checksum: String
) -> Target {
    if let path = localArtifactPath("\(name).xcframework") {
        return .binaryTarget(name: name, path: path)
    }
    return .binaryTarget(
        name: name,
        url: "https://github.com/\(repository)/releases/download/\(tag)/\(artifactName)",
        checksum: checksum
    )
}

let package = Package(
    name: "llamadart",
    platforms: [
        .iOS("16.4"),
        .macOS("14.0")
    ],
    products: [
        .library(
            name: "llamadart",
            type: .dynamic,
            targets: ["llamadart"]
        )
    ],
    targets: [
        // Native version management:
        // Keep llamaCppTag aligned with _llamaCppTag in hook/build.dart.
        // Keep liteRtLmTag aligned with _litertLmVersion in hook/build.dart.
        // After native release workflows
        // publish Apple XCFramework zips, refresh each checksum with
        // `swift package compute-checksum <zip>`.
        nativeRepoBinaryTarget(
            name: "llama",
            repository: "leehack/llamadart-native",
            artifactName: "llamadart-native-apple-xcframework-\(llamaCppTag).zip",
            tag: llamaCppTag,
            checksum: "88f50e3ebf13e82d0c69799b30e2ea99406a95ba5e8a37901487f337ff52a9c7"
        ),
        nativeRepoBinaryTarget(
            name: "LiteRtLm",
            repository: "leehack/litert-lm-native",
            artifactName: "litert-lm-native-apple-LiteRtLm-xcframework-\(liteRtLmTag).zip",
            tag: liteRtLmTag,
            checksum: "f0e7cff11394b953ecf675c0d935f757752c841902e46514c8177ccf3ea34cbd"
        ),
        nativeRepoBinaryTarget(
            name: "CLiteRTLM",
            repository: "leehack/litert-lm-native",
            artifactName: "litert-lm-native-apple-CLiteRTLM-xcframework-\(liteRtLmTag).zip",
            tag: liteRtLmTag,
            checksum: "11bc1e1367b44c8424f7a17e0c369fa5e97209a9890e4c6d0fc02f3d0f62c75a"
        ),
        nativeRepoBinaryTarget(
            name: "GemmaModelConstraintProvider",
            repository: "leehack/litert-lm-native",
            artifactName: "litert-lm-native-apple-GemmaModelConstraintProvider-xcframework-\(liteRtLmTag).zip",
            tag: liteRtLmTag,
            checksum: "c9cc5b9b249b9d7e4049c4314246246f9e8216d25c73b3c0817e41a47cbea767"
        ),
        nativeRepoBinaryTarget(
            name: "LiteRt",
            repository: "leehack/litert-lm-native",
            artifactName: "litert-lm-native-apple-LiteRt-xcframework-\(liteRtLmTag).zip",
            tag: liteRtLmTag,
            checksum: "6453a27c3dc9303e2b8a19b09dcc36dee4fe27e2daad042b8055eeb5893fa5a4"
        ),
        nativeRepoBinaryTarget(
            name: "LiteRtMetalAccelerator",
            repository: "leehack/litert-lm-native",
            artifactName: "litert-lm-native-apple-LiteRtMetalAccelerator-xcframework-\(liteRtLmTag).zip",
            tag: liteRtLmTag,
            checksum: "45a15c36a48be7973d0ffdb9eb42a235485bdfc639fb28b47e84129f75400477"
        ),
        nativeRepoBinaryTarget(
            name: "LiteRtTopKMetalSampler",
            repository: "leehack/litert-lm-native",
            artifactName: "litert-lm-native-apple-LiteRtTopKMetalSampler-xcframework-\(liteRtLmTag).zip",
            tag: liteRtLmTag,
            checksum: "2289e5e8a73322691c3e4d4ebb0cab4fca2401d211d5c37d13fc1a678488d3ef"
        ),
        nativeRepoBinaryTarget(
            name: "LiteRtTopKWebGpuSampler",
            repository: "leehack/litert-lm-native",
            artifactName: "litert-lm-native-apple-LiteRtTopKWebGpuSampler-xcframework-\(liteRtLmTag).zip",
            tag: liteRtLmTag,
            checksum: "fa2738a3bb0655f8de6bb440cc4fa3bcc56340eb41dccef33b528599ce1ce905"
        ),
        nativeRepoBinaryTarget(
            name: "LiteRtWebGpuAccelerator",
            repository: "leehack/litert-lm-native",
            artifactName: "litert-lm-native-apple-LiteRtWebGpuAccelerator-xcframework-\(liteRtLmTag).zip",
            tag: liteRtLmTag,
            checksum: "59980392845ff61f842cea1dd264053fb2ba2012651c4d606cce68d89724cfc5"
        ),
        .target(
            name: "llamadart",
            dependencies: [
                "llama",
                "LiteRtLm",
                .target(name: "CLiteRTLM", condition: .when(platforms: [.iOS])),
                .target(name: "GemmaModelConstraintProvider", condition: .when(platforms: [.macOS])),
                .target(name: "LiteRt", condition: .when(platforms: [.macOS])),
                .target(name: "LiteRtMetalAccelerator", condition: .when(platforms: [.macOS])),
                .target(name: "LiteRtTopKMetalSampler", condition: .when(platforms: [.macOS])),
                .target(name: "LiteRtTopKWebGpuSampler", condition: .when(platforms: [.macOS])),
                .target(name: "LiteRtWebGpuAccelerator", condition: .when(platforms: [.macOS]))
            ],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-reexport_framework", "-Xlinker", "llama"]),
                .unsafeFlags(["-Xlinker", "-reexport_framework", "-Xlinker", "LiteRtLm"]),
                .unsafeFlags(["-Xlinker", "-reexport_framework", "-Xlinker", "CLiteRTLM"], .when(platforms: [.iOS]))
            ]
        )
    ]
)
