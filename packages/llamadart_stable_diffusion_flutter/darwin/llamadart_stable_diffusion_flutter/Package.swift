// swift-tools-version: 5.9
import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let artifactsRoot = packageRoot.appendingPathComponent("Artifacts")
let stableDiffusionTag = "v0.3.0"

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
            checksum: "3b83a0c21a00f6418890b679ea45b00c20d012da0a57fe989635b793e09f096a"
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
