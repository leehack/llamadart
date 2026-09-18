// swift-tools-version: 5.9
import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let artifactsRoot = packageRoot.appendingPathComponent("Artifacts")
let liteRtLmTag = "v0.17.0-5"

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
    name: "llamadart_litert_lm_flutter",
    platforms: [
        .iOS("16.4"),
        .macOS("14.0")
    ],
    products: [
        .library(
            name: "llamadart-litert-lm-flutter",
            type: .dynamic,
            targets: ["llamadart_litert_lm_flutter"]
        )
    ],
    targets: [
        nativeRepoBinaryTarget(
            name: "LiteRtLm",
            repository: "leehack/litert-lm-native",
            artifactName: "litert-lm-native-apple-LiteRtLm-xcframework-\(liteRtLmTag).zip",
            tag: liteRtLmTag,
            checksum: "28e75801c4ab5f5dd62e0e1311b29fe4b6f1c4f0026136f1e94610646b71f87d"
        ),
        nativeRepoBinaryTarget(
            name: "CLiteRTLM",
            repository: "leehack/litert-lm-native",
            artifactName: "litert-lm-native-apple-CLiteRTLM-xcframework-\(liteRtLmTag).zip",
            tag: liteRtLmTag,
            checksum: "8af7ffc380164102cd25902ca87709776cecb44b7319b33fe67f55d068d7b390"
        ),
        nativeRepoBinaryTarget(
            name: "CLiteRTLMMac",
            repository: "leehack/litert-lm-native",
            artifactName: "litert-lm-native-apple-CLiteRTLMMac-xcframework-\(liteRtLmTag).zip",
            tag: liteRtLmTag,
            checksum: "6c5ba35cd3e735ca3fdfae0eecc6ace205e4177d39703ff511dfd307d8d14116"
        ),
        nativeRepoBinaryTarget(
            name: "GemmaModelConstraintProvider",
            repository: "leehack/litert-lm-native",
            artifactName: "litert-lm-native-apple-GemmaModelConstraintProvider-xcframework-\(liteRtLmTag).zip",
            tag: liteRtLmTag,
            checksum: "4fe3f71c3b507235cb2c4f6ba392b8ce94154b5cbd6ea7647e60769d531750e4"
        ),
        nativeRepoBinaryTarget(
            name: "LiteRtMetalAccelerator",
            repository: "leehack/litert-lm-native",
            artifactName: "litert-lm-native-apple-LiteRtMetalAccelerator-xcframework-\(liteRtLmTag).zip",
            tag: liteRtLmTag,
            checksum: "f3e00383369ed3b973273fb4a8c134bf1d682ded43fe82cc73eaa78eaa0d0359"
        ),
        nativeRepoBinaryTarget(
            name: "LiteRtTopKMetalSampler",
            repository: "leehack/litert-lm-native",
            artifactName: "litert-lm-native-apple-LiteRtTopKMetalSampler-xcframework-\(liteRtLmTag).zip",
            tag: liteRtLmTag,
            checksum: "0d6a42e6c0ec35aab6260c6f1ec0446f2f71745efe06ba4f254ff61a64b9bb57"
        ),
        .target(
            name: "llamadart_litert_lm_flutter",
            dependencies: [
                .target(name: "LiteRtLm", condition: .when(platforms: [.iOS, .macOS])),
                .target(name: "CLiteRTLM", condition: .when(platforms: [.iOS])),
                .target(name: "CLiteRTLMMac", condition: .when(platforms: [.macOS])),
                .target(name: "GemmaModelConstraintProvider", condition: .when(platforms: [.iOS])),
                .target(name: "LiteRtMetalAccelerator", condition: .when(platforms: [.iOS])),
                .target(name: "LiteRtTopKMetalSampler", condition: .when(platforms: [.iOS]))
            ],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-reexport_framework", "-Xlinker", "LiteRtLm"], .when(platforms: [.iOS])),
                .unsafeFlags(["-Xlinker", "-reexport_framework", "-Xlinker", "CLiteRTLM"], .when(platforms: [.iOS]))
            ]
        )
    ]
)
