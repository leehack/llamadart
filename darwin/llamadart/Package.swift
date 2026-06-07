// swift-tools-version: 5.9
import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let artifactsRoot = packageRoot.appendingPathComponent("Artifacts")
let llamaCppTag = "b9547"
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
            checksum: "df326c10018c0ac739560d0744db52598b7ea8158fd935b02f769d3ac2905237"
        ),
        nativeRepoBinaryTarget(
            name: "LiteRtLm",
            repository: "leehack/litert-lm-native",
            artifactName: "litert-lm-native-apple-LiteRtLm-xcframework-\(liteRtLmTag).zip",
            tag: liteRtLmTag,
            checksum: "6fa9169d7c93eb1b70dc537b35640e2652cd9ee139014251404d4e6b15ad2686"
        ),
        nativeRepoBinaryTarget(
            name: "CLiteRTLM",
            repository: "leehack/litert-lm-native",
            artifactName: "litert-lm-native-apple-CLiteRTLM-xcframework-\(liteRtLmTag).zip",
            tag: liteRtLmTag,
            checksum: "81880c7bf84586bc08820cc645a1c52869870676ff7de123ac0ba99c2e6820f7"
        ),
        nativeRepoBinaryTarget(
            name: "GemmaModelConstraintProvider",
            repository: "leehack/litert-lm-native",
            artifactName: "litert-lm-native-apple-GemmaModelConstraintProvider-xcframework-\(liteRtLmTag).zip",
            tag: liteRtLmTag,
            checksum: "d039fe952eb3187626b7950c42b35c6f7d16340ab8d1e6b1ff63a998022446f9"
        ),
        nativeRepoBinaryTarget(
            name: "LiteRt",
            repository: "leehack/litert-lm-native",
            artifactName: "litert-lm-native-apple-LiteRt-xcframework-\(liteRtLmTag).zip",
            tag: liteRtLmTag,
            checksum: "0055e5483c0aff861a37a20c66e485051eb081fb2dbded5501ffdc2cc82d0df7"
        ),
        nativeRepoBinaryTarget(
            name: "LiteRtMetalAccelerator",
            repository: "leehack/litert-lm-native",
            artifactName: "litert-lm-native-apple-LiteRtMetalAccelerator-xcframework-\(liteRtLmTag).zip",
            tag: liteRtLmTag,
            checksum: "5e3ce138a722cbc4730b8986db0134fcf64f6f486876c2a3bacd922f50fdebf3"
        ),
        nativeRepoBinaryTarget(
            name: "LiteRtTopKMetalSampler",
            repository: "leehack/litert-lm-native",
            artifactName: "litert-lm-native-apple-LiteRtTopKMetalSampler-xcframework-\(liteRtLmTag).zip",
            tag: liteRtLmTag,
            checksum: "f9c4f5e62be9a9c8d69298f5196c213cef8760394262fd02da0c9b13580f08a7"
        ),
        nativeRepoBinaryTarget(
            name: "LiteRtTopKWebGpuSampler",
            repository: "leehack/litert-lm-native",
            artifactName: "litert-lm-native-apple-LiteRtTopKWebGpuSampler-xcframework-\(liteRtLmTag).zip",
            tag: liteRtLmTag,
            checksum: "e99fc2aef67b24e6c024bed89fee36bf8cf8bb2870c2b48dfae9ba7f42c0dcd6"
        ),
        nativeRepoBinaryTarget(
            name: "LiteRtWebGpuAccelerator",
            repository: "leehack/litert-lm-native",
            artifactName: "litert-lm-native-apple-LiteRtWebGpuAccelerator-xcframework-\(liteRtLmTag).zip",
            tag: liteRtLmTag,
            checksum: "9a3de6686d37cf06475b4fd8dfb094aaa8e3f55b1cbbdc60ae38e6eb8f5f1ba1"
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
