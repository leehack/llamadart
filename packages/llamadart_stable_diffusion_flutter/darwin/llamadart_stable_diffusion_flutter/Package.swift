// swift-tools-version: 5.9
import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let artifactsRoot = packageRoot.appendingPathComponent("Artifacts")
let stableDiffusionTag = "v0.2.0"

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
    name: "llamadart_stable_diffusion_flutter",
    platforms: [
        .iOS("16.4"),
        .macOS("14.0")
    ],
    products: [
        .library(
            name: "llamadart-stable-diffusion-flutter",
            type: .dynamic,
            targets: ["llamadart_stable_diffusion_flutter"]
        )
    ],
    targets: [
        nativeRepoBinaryTarget(
            name: "stable_diffusion",
            repository: "leehack/stable-diffusion-native",
            artifactName: "stable-diffusion-native-apple-xcframework-\(stableDiffusionTag).zip",
            tag: stableDiffusionTag,
            checksum: "a48a5fc1724dabc6fc6c32813221aaee25765b168d0267562354ed1b4c077de1"
        ),
        .target(
            name: "llamadart_stable_diffusion_flutter",
            dependencies: [
                "stable_diffusion"
            ],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-reexport_framework", "-Xlinker", "stable_diffusion"])
            ]
        )
    ]
)
