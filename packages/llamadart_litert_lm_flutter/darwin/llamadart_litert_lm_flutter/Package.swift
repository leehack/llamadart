// swift-tools-version: 5.9
import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let artifactsRoot = packageRoot.appendingPathComponent("Artifacts")
let liteRtLmTag = "v0.18.0-2"

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
            checksum: "c3607845d4c7263e479d90d4cb78be38123c2804900ea11dac600d52e52867b1"
        ),
        nativeRepoBinaryTarget(
            name: "CLiteRTLM",
            repository: "leehack/litert-lm-native",
            artifactName: "litert-lm-native-apple-CLiteRTLM-xcframework-\(liteRtLmTag).zip",
            tag: liteRtLmTag,
            checksum: "1bcfc03a3e8829f6861cbc6cf59dcf953426ce5381cf50e73c24eecdf0f510ba"
        ),
        nativeRepoBinaryTarget(
            name: "CLiteRTLMMac",
            repository: "leehack/litert-lm-native",
            artifactName: "litert-lm-native-apple-CLiteRTLMMac-xcframework-\(liteRtLmTag).zip",
            tag: liteRtLmTag,
            checksum: "aa4479635599f700f32580057c11aa38a2838cd3a734dc8a1a2b0c5be49c7e6c"
        ),
        nativeRepoBinaryTarget(
            name: "LiteRtMetalAccelerator",
            repository: "leehack/litert-lm-native",
            artifactName: "litert-lm-native-apple-LiteRtMetalAccelerator-xcframework-\(liteRtLmTag).zip",
            tag: liteRtLmTag,
            checksum: "42897fca46a97732892489ca51f5f831600139ae53aa801f44aaf742e4fd179f"
        ),
        nativeRepoBinaryTarget(
            name: "LiteRtTopKMetalSampler",
            repository: "leehack/litert-lm-native",
            artifactName: "litert-lm-native-apple-LiteRtTopKMetalSampler-xcframework-\(liteRtLmTag).zip",
            tag: liteRtLmTag,
            checksum: "07336325a5aba5d3061901f2016986639a7e142a2a22fc2e5c68e486847d2140"
        ),
        nativeRepoBinaryTarget(
            name: "LiteRt",
            repository: "leehack/litert-lm-native",
            artifactName: "litert-lm-native-apple-LiteRt-xcframework-\(liteRtLmTag).zip",
            tag: liteRtLmTag,
            checksum: "c1310db645ab456e65a5eaa79f841f982d2b85bfef5f3ac915db2bace7a879da"
        ),
        nativeRepoBinaryTarget(
            name: "LiteRtTopKWebGpuSampler",
            repository: "leehack/litert-lm-native",
            artifactName: "litert-lm-native-apple-LiteRtTopKWebGpuSampler-xcframework-\(liteRtLmTag).zip",
            tag: liteRtLmTag,
            checksum: "3530441033aa04145f044ca77e5a5711973f6f791ff30eaf4122085a24b7004a"
        ),
        nativeRepoBinaryTarget(
            name: "LiteRtWebGpuAccelerator",
            repository: "leehack/litert-lm-native",
            artifactName: "litert-lm-native-apple-LiteRtWebGpuAccelerator-xcframework-\(liteRtLmTag).zip",
            tag: liteRtLmTag,
            checksum: "0164e3954226c19416750b70a1290a384f16f22e62466ea11826c8cee603e00f"
        ),
        nativeRepoBinaryTarget(
            name: "WebgpuDawn",
            repository: "leehack/litert-lm-native",
            artifactName: "litert-lm-native-apple-WebgpuDawn-xcframework-\(liteRtLmTag).zip",
            tag: liteRtLmTag,
            checksum: "3477373ac2bbeb256e8ad8c8f28f41aea7a75aa5782b746e82020203ab076df6"
        ),
        .target(
            name: "llamadart_litert_lm_flutter",
            dependencies: [
                .target(name: "LiteRtLm", condition: .when(platforms: [.iOS, .macOS])),
                .target(name: "CLiteRTLM", condition: .when(platforms: [.iOS])),
                .target(name: "CLiteRTLMMac", condition: .when(platforms: [.macOS])),
                .target(name: "LiteRtMetalAccelerator", condition: .when(platforms: [.iOS])),
                .target(name: "LiteRtTopKMetalSampler", condition: .when(platforms: [.iOS])),
                .target(name: "LiteRt", condition: .when(platforms: [.macOS])),
                .target(name: "LiteRtTopKWebGpuSampler", condition: .when(platforms: [.macOS])),
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
