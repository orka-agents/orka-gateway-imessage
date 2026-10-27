// swift-tools-version: 6.2

import PackageDescription

let swiftSettings: [SwiftSetting] = [.swiftLanguageMode(.v6)]

let package = Package(
    name: "OrkaIMessageGateway",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "OrkaIMessageGateway", targets: ["OrkaIMessageGateway"]),
        .executable(name: "gateway-conformance-host", targets: ["ConformanceHost"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.28.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.16.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.13.0"),
        .package(url: "https://github.com/openclaw/imsg.git", exact: "0.19.0"),
    ],
    targets: [
        // orka.gateway.v1 protocol, safety rules, durable state, and the HTTP server.
        .target(
            name: "GatewayCore",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            swiftSettings: swiftSettings,
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // Messages access through imsg's IMsgCore library.
        .target(
            name: "MessagesBridge",
            dependencies: [
                "GatewayCore",
                .product(name: "IMsgCore", package: "imsg"),
            ],
            swiftSettings: swiftSettings
        ),
        // The menu bar app.
        .executableTarget(
            name: "OrkaIMessageGateway",
            dependencies: [
                "GatewayCore",
                "MessagesBridge",
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: swiftSettings
        ),
        // A headless host with a fake Messages backend for Orka's conformance tool.
        // It never touches Messages.
        .executableTarget(
            name: "ConformanceHost",
            dependencies: [
                "GatewayCore",
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "GatewayCoreTests",
            dependencies: [
                "GatewayCore",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ],
            swiftSettings: swiftSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
