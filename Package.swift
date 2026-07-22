// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Cliphoard",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        // Tokenizers for the High/Max tiers (MiniLM WordPiece, Gemma SentencePiece).
        // The ogma models keep the hand-rolled OgmaTokenizer (custom pipeline).
        .package(url: "https://github.com/huggingface/swift-transformers.git", from: "0.1.0")
    ],
    targets: [
        .executableTarget(
            name: "Cliphoard",
            dependencies: [.product(name: "Transformers", package: "swift-transformers")],
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
