// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "JMTerm",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.12.0"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.11.0"),
    ],
    targets: [
        .executableTarget(
            name: "JMTerm",
            dependencies: [
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            resources: [
                .copy("Resources/AppIcon.icns"),
            ]
        ),
    ]
)
