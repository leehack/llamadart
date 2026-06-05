// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "llamadart",
    platforms: [
        .iOS("16.4"),
        .macOS("13.3")
    ],
    products: [
        .library(
            name: "llamadart",
            type: .dynamic,
            targets: ["llamadart"]
        )
    ],
    targets: [
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b9371/llama-b9371-xcframework.zip",
            checksum: "efa73913816b8a4be5bef3e548758669c87616d6d316e5a981a3bf2e8e6bc50d"
        ),
        .binaryTarget(
            name: "CLiteRTLM",
            url: "https://github.com/google-ai-edge/LiteRT-LM/releases/download/v0.13.1/CLiteRTLM.xcframework.zip",
            checksum: "7ff01c42106b754748b5dd3036a4a57161b25ebf523e705bebc1219061852362"
        ),
        .binaryTarget(
            name: "CLiteRTLM_mac",
            url: "https://github.com/google-ai-edge/LiteRT-LM/releases/download/v0.13.1/CLiteRTLM_mac.xcframework.zip",
            checksum: "ec9ffe230dc39117a7fc8933b1cc15910454027fee6d3041534ab7cf17313981"
        ),
        .target(
            name: "llamadart",
            dependencies: [
                "llama",
                .target(name: "CLiteRTLM", condition: .when(platforms: [.iOS])),
                .target(name: "CLiteRTLM_mac", condition: .when(platforms: [.macOS]))
            ],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-reexport_framework", "-Xlinker", "llama"]),
                .unsafeFlags(["-Xlinker", "-reexport_framework", "-Xlinker", "CLiteRTLM"], .when(platforms: [.iOS])),
                .unsafeFlags(["-Xlinker", "-reexport-lCLiteRTLM_mac"], .when(platforms: [.macOS]))
            ]
        )
    ]
)
