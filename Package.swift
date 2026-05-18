// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ScreenDrawOverlay",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "ScreenDrawOverlay", targets: ["ScreenDrawOverlay"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "ScreenDrawOverlay",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon")
            ]
        )
    ]
)
