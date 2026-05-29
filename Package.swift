// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Vellum",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "Vellum", targets: ["Vellum"])
    ],
    targets: [
        .executableTarget(
            name: "Vellum",
            path: "Sources/Vellum"
        )
    ]
)
