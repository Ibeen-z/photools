// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PhotoolsMobile",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "PhotoolsMobileCore",
            targets: ["PhotoolsMobileCore"]
        )
    ],
    targets: [
        .target(
            name: "PhotoolsMobileCore",
            dependencies: [],
            path: "Sources/PhotoolsMobileCore",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "PhotoolsMobileCoreTests",
            dependencies: ["PhotoolsMobileCore"],
            path: "Tests/PhotoolsMobileCoreTests"
        )
    ]
)
