// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Diriger",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Diriger", targets: ["Diriger"])
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0")
    ],
    targets: [
        .executableTarget(
            name: "Diriger",
            dependencies: ["KeyboardShortcuts"],
            path: "Sources/Diriger"
        )
    ]
)
