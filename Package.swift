// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DesktopBot",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "desktopbot", targets: ["DesktopBot"]),
        .library(name: "DesktopBotCore", targets: ["DesktopBotCore"])
    ],
    targets: [
        .target(
            name: "DesktopBotCore",
            linkerSettings: [
                .linkedFramework("Vision"),
                .linkedFramework("PDFKit")
            ]
        ),
        .executableTarget(
            name: "DesktopBot",
            dependencies: ["DesktopBotCore"]
        ),
        .testTarget(
            name: "DesktopBotCoreTests",
            dependencies: ["DesktopBotCore"]
        )
    ]
)
