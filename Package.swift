// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ExtSelector",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "ExtSelector",
            resources: [.process("Resources/Catalog.json")]
        ),
        .testTarget(
            name: "ExtSelectorTests",
            dependencies: ["ExtSelector"]
        )
    ]
)
