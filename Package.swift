// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Cliphoard",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "Cliphoard",
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
