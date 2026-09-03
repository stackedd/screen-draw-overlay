// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Scrim",
    platforms: [
        .macOS(.v11)
    ],
    products: [
        .executable(name: "Scrim", targets: ["Scrim"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "Scrim",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement")
            ]
        )
    ]
)
