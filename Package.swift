// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Impuls",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Impuls", targets: ["Impuls"])
    ],
    targets: [
        .executableTarget(
            name: "Impuls",
            path: "Sources/Cyclop",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
