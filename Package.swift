// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Ditto",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "Ditto",
            path: "Sources/Ditto",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Carbon"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "DittoTests",
            dependencies: ["Ditto"],
            path: "Tests/DittoTests",
            resources: [.copy("Fixtures")]
        )
    ]
)
