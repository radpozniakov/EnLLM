// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "EnLLM",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(name: "EnLLMCore", targets: ["EnLLMCore"]),
        .library(name: "EnLLMPlatform", targets: ["EnLLMPlatform"])
    ],
    targets: [
        .target(name: "EnLLMCore"),
        .target(
            name: "EnLLMPlatform",
            dependencies: ["EnLLMCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("Security"),
                .linkedFramework("UserNotifications")
            ]
        ),
        .testTarget(
            name: "EnLLMCoreTests",
            dependencies: ["EnLLMCore"]
        ),
        .testTarget(
            name: "EnLLMPlatformTests",
            dependencies: ["EnLLMCore", "EnLLMPlatform"]
        )
    ]
)
