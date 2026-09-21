// swift-tools-version: 6.2
import PackageDescription

// Everything testable without an app bundle lives here, so `swift test` runs in
// seconds and never links AppKit. The app target consumes these as a local
// package; nothing here may import AppKit or SwiftUI.
let package = Package(
    name: "PeekKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "PeekCore", targets: ["PeekCore"]),
        .library(name: "PeekProviders", targets: ["PeekProviders"]),
        .library(name: "PeekSecurity", targets: ["PeekSecurity"]),
        .library(name: "PeekPersistence", targets: ["PeekPersistence"]),
    ],
    targets: [
        .target(name: "PeekCore"),
        .target(name: "PeekProviders", dependencies: ["PeekCore"]),
        .target(name: "PeekSecurity"),
        .target(name: "PeekPersistence", dependencies: ["PeekCore"]),
        .testTarget(name: "PeekCoreTests", dependencies: ["PeekCore"]),
        .testTarget(name: "PeekProvidersTests", dependencies: ["PeekProviders"], resources: [.copy("Fixtures")]),
        .testTarget(name: "PeekSecurityTests", dependencies: ["PeekSecurity"]),
        .testTarget(name: "PeekPersistenceTests", dependencies: ["PeekPersistence"]),
    ]
)
