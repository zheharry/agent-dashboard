// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AgentQuota",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(
            name: "AgentQuota",
            targets: ["AgentQuota"],
        ),
    ],
    targets: [
        .executableTarget(
            name: "AgentQuota",
        ),
    ],
)
