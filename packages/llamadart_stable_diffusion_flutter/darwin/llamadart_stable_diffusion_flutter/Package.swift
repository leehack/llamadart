// swift-tools-version: 5.9
import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let artifactsRoot = packageRoot.appendingPathComponent("Artifacts")
let stableDiffusionTag = "v0.2.0-1"

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
            checksum: "32c571e9c5204f1e8d2cdbae2371e3fac80bd1170715366e622d657cdca7a39b"
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
