// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Impuls",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Impuls", targets: ["Impuls"])
    ],
    targets: [
        .target(
            name: "ImpulsCore",
            path: "Sources/Impuls",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Impuls",
            dependencies: ["ImpulsCore"],
            path: "Sources/ImpulsLauncher",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ImpulsTests",
            dependencies: ["ImpulsCore"],
            path: "Tests/ImpulsTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
