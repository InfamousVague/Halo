// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Halo",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Halo", targets: ["Halo"])
    ],
    dependencies: [
        // SuiteKit gives us SuiteLiveActivityStore (the shared-state
        // file format) so panes + standalone agents from elsewhere
        // in the suite publish to a single shape Halo reads.
        .package(path: "../suitekit-swift")
    ],
    targets: [
        .executableTarget(
            name: "Halo",
            dependencies: [
                .product(name: "SuiteKit", package: "suitekit-swift")
            ],
            resources: [
                .process("Resources"),
                .process("Assets.xcassets")
            ]
        )
    ]
)
