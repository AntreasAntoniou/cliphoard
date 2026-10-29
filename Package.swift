// swift-tools-version:5.9
import PackageDescription

// Exact Argmax 1.1.1 selected Swift 6.2 target settings; the app keeps language 5.
let argmaxAudioSettings: [SwiftSetting] = [
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .unsafeFlags(["-swift-version", "6", "-enable-library-evolution",
                  "-Xfrontend", "-alias-module-names-in-module-interface"])
]

let package = Package(
    name: "Cliphoard",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        // Tokenizer for the High tier (MiniLM WordPiece).
        // The ogma models keep the hand-rolled OgmaTokenizer (custom pipeline).
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "0.1.24")
    ],
    targets: [
        .binaryTarget(
            name: "CLiteRTLM_mac",
            url: "https://github.com/google-ai-edge/LiteRT-LM/releases/download/v0.18.1/CLiteRTLM_mac.xcframework.zip",
            checksum: "91b8c968fb61486c3eb6b0e7a6a1dfa32181efd4f2e5df14fb8bb5746dd8dd9f"
        ),
        .target(name: "LiteRTLM", dependencies: ["CLiteRTLM_mac"], path: "Vendor/LiteRTLM",
                exclude: ["LICENSE", "README.md", "UPSTREAM-SOURCE-PINS.json", "Notices"]),
        .target(name: "ArgmaxCore", path: "Vendor/ArgmaxAudio/Sources/ArgmaxCore",
                swiftSettings: argmaxAudioSettings),
        .target(name: "WhisperKit", dependencies: ["ArgmaxCore"],
                path: "Vendor/ArgmaxAudio/Sources/WhisperKit", swiftSettings: argmaxAudioSettings),
        .executableTarget(
            name: "Cliphoard",
            dependencies: [.product(name: "Transformers", package: "swift-transformers"), "LiteRTLM",
                           "WhisperKit"],
            path: "Sources/Cliphoard",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Carbon"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "CliphoardTests",
            dependencies: ["Cliphoard"],
            path: "Tests/CliphoardTests",
            resources: [.copy("Fixtures")]
        )
    ]
)
