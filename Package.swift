// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TrainerCore",
    products: [.library(name: "TrainerCore", targets: ["TrainerCore"])],
    targets: [
        .target(name: "TrainerCore", path: "Core"),
        .testTarget(name: "TrainerCoreTests", dependencies: ["TrainerCore"], path: "Tests")
    ]
)
