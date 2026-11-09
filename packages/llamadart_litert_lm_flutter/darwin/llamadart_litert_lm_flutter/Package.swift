// swift-tools-version: 5.9
import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let artifactsRoot = packageRoot.appendingPathComponent("Artifacts")
let liteRtLmTag = "v0.19.1-2"

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
            checksum: "66ee469310ee7aec7bcc438cf0ab5bed6f8ab376f49516839bb18ed70e4e40e0"
        ),
        nativeRepoBinaryTarget(
            name: "CLiteRTLM",
            repository: "leehack/litert-lm-native",
            artifactName: "litert-lm-native-apple-CLiteRTLM-xcframework-\(liteRtLmTag).zip",
            tag: liteRtLmTag,
            checksum: "ef10e320169b741552b99dad122d0f7c6b8929332e53c86213e9754c3191c9f4"
        ),
        nativeRepoBinaryTarget(
            name: "CLiteRTLMMac",
            repository: "leehack/litert-lm-native",
            artifactName: "litert-lm-native-apple-CLiteRTLMMac-xcframework-\(liteRtLmTag).zip",
            tag: liteRtLmTag,
            checksum: "94083e21752430320f3ff210712efcfc090719dd6f63968a7e7fdf5ce57042af"
        ),
        nativeRepoBinaryTarget(
            name: "LiteRtMetalAccelerator",
            repository: "leehack/litert-lm-native",
            artifactName: "litert-lm-native-apple-LiteRtMetalAccelerator-xcframework-\(liteRtLmTag).zip",
            tag: liteRtLmTag,
            checksum: "12a5315dd958956724fc7a1fa42e179a69575d6fc9be18c22dc4db4bc3019fff"
        ),
        nativeRepoBinaryTarget(
            name: "LiteRt",
            repository: "leehack/litert-lm-native",
            artifactName: "litert-lm-native-apple-LiteRt-xcframework-\(liteRtLmTag).zip",
            tag: liteRtLmTag,
            checksum: "3a57e1b43a341629dd7934863d2c02d97d17bf935fe8908a24aea757d93a8461"
        ),
        nativeRepoBinaryTarget(
            name: "LiteRtWebGpuAccelerator",
            repository: "leehack/litert-lm-native",
            artifactName: "litert-lm-native-apple-LiteRtWebGpuAccelerator-xcframework-\(liteRtLmTag).zip",
            tag: liteRtLmTag,
            checksum: "22c737793e329dd7c05fce3d928572a1679906feceee199c02918960225ca225"
        ),
        nativeRepoBinaryTarget(
            name: "WebgpuDawn",
            repository: "leehack/litert-lm-native",
            artifactName: "litert-lm-native-apple-WebgpuDawn-xcframework-\(liteRtLmTag).zip",
            tag: liteRtLmTag,
            checksum: "9b943bed89b9dd21178d4b0f3f2dab5273c941ce045ba28940e5e494ece75036"
        ),
        .target(
            name: "llamadart_litert_lm_flutter",
            dependencies: [
                .target(name: "LiteRtLm", condition: .when(platforms: [.iOS, .macOS])),
                .target(name: "CLiteRTLM", condition: .when(platforms: [.iOS])),
                .target(name: "CLiteRTLMMac", condition: .when(platforms: [.macOS])),
                .target(name: "LiteRtMetalAccelerator", condition: .when(platforms: [.iOS])),
                .target(name: "LiteRt", condition: .when(platforms: [.macOS])),
                .target(name: "LiteRtWebGpuAccelerator", condition: .when(platforms: [.macOS])),
                .target(name: "WebgpuDawn", condition: .when(platforms: [.macOS]))
            ],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-reexport_framework", "-Xlinker", "LiteRtLm"], .when(platforms: [.iOS])),
                .unsafeFlags(["-Xlinker", "-reexport_framework", "-Xlinker", "CLiteRTLM"], .when(platforms: [.iOS]))
            ]
        )
    ]
)
