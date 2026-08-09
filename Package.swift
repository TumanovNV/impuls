// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Impuls",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Impuls", targets: ["Impuls"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/sparkle-project/Sparkle",
            exact: "2.9.5"
        )
    ],
    targets: [
        .target(
            name: "ImpulsCore",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/Impuls",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Impuls",
            dependencies: ["ImpulsCore"],
            path: "Sources/ImpulsLauncher",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks"
                ])
            ]
        ),
        .testTarget(
            name: "ImpulsTests",
            dependencies: ["ImpulsCore"],
            path: "Tests/ImpulsTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
