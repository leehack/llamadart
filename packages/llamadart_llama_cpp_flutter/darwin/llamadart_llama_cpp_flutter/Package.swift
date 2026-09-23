// swift-tools-version: 5.9
import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let artifactsRoot = packageRoot.appendingPathComponent("Artifacts")
let llamaCppTag = "v0.4.1-1"

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
    name: "llamadart_llama_cpp_flutter",
    platforms: [
        .iOS("16.4"),
        .macOS("14.0")
    ],
    products: [
        .library(
            name: "llamadart-llama-cpp-flutter",
            type: .dynamic,
            targets: ["llamadart_llama_cpp_flutter"]
        )
    ],
    targets: [
        nativeRepoBinaryTarget(
            name: "llama",
            repository: "leehack/llamadart-native",
            artifactName: "llamadart-native-apple-xcframework-\(llamaCppTag).zip",
            tag: llamaCppTag,
            checksum: "bab353ce17dfbac9afe65ade73751d67f110b1807a1fb365b4d1df2db25a5418"
        ),
        .target(
            name: "llamadart_llama_cpp_flutter",
            dependencies: [
                "llama"
            ],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-reexport_framework", "-Xlinker", "llama"])
            ]
        )
    ]
)
