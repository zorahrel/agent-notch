// swift-tools-version: 5.9
import PackageDescription

/// `agent-notch` — standalone macOS HUD app that visualizes live AI coding
/// agent sessions in the MacBook Pro dynamic notch.
///
/// Wave 1 (this release): single executable target. Backend is HTTP-only,
/// configurable via the `AGENT_NOTCH_BACKEND_URL` env var. Consumers like
/// Jarvis spawn the built binary as a subprocess (no Swift Package import).
///
/// Wave 1.5 (planned): split the views into a `AgentNotchKit` library
/// product so consumers can embed individual SwiftUI views in their own apps.
///
/// Wave 2 (planned): pluggable `NotchBackend` protocol with a subprocess
/// implementation that consumes `agent-conductor watch --format json-lines`,
/// eliminating the need for an HTTP server when the user has agent-conductor
/// installed.
let package = Package(
    name: "AgentNotch",
    platforms: [.macOS(.v14)],
    products: [
        .executable(
            name: "agent-notch",
            targets: ["AgentNotch"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/MrKai77/DynamicNotchKit", from: "1.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "AgentNotch",
            dependencies: [
                .product(name: "DynamicNotchKit", package: "DynamicNotchKit"),
            ],
            resources: [
                .copy("Orb"),
            ]
        ),
        .testTarget(
            name: "AgentNotchTests",
            dependencies: ["AgentNotch"],
            path: "Tests/AgentNotchTests"
        ),
    ]
)
