// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Moonglade",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "moonglade", targets: ["Moonglade"]),
        .executable(name: "MoongladeApp", targets: ["MoongladeApp"]),
        .executable(name: "moonglade-tests", targets: ["MoongladeTests"]),
    ],
    targets: [
        .target(
            name: "MoongladeCore",
            resources: [.copy("Resources")]
        ),
        .executableTarget(
            name: "Moonglade",
            dependencies: ["MoongladeCore"]
        ),
        .executableTarget(
            name: "MoongladeApp",
            dependencies: ["MoongladeCore"],
            // swift build does not compile Metal sources, so the shader ships
            // as a prebuilt default.metallib; regenerate it from Ripple.metal
            // with scripts/compile-shaders.sh after editing the source.
            exclude: ["Ripple.metal"],
            resources: [.copy("Resources/default.metallib")]
        ),
        .executableTarget(
            name: "MoongladeTests",
            dependencies: ["MoongladeCore"],
            path: "Tests/MoongladeCoreTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
