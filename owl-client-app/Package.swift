// swift-tools-version: 5.9

import PackageDescription

let chromiumBuildDir = "/Users/xiaoyang/Project/chromium/src/out/owl-host"

// Shared build settings for all targets that use OWLBridge.framework
let owlBridgeSwiftSettings: [SwiftSetting] = [
    .unsafeFlags(["-F\(chromiumBuildDir)"]),
]
let owlBridgeLinkerSettings: [LinkerSetting] = [
    .unsafeFlags([
        "-F\(chromiumBuildDir)",
        "-Xlinker", "-rpath",
        "-Xlinker", chromiumBuildDir,
    ]),
    .linkedFramework("OWLBridge"),
]

let package = Package(
    name: "OWLBrowser",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        // ── OWLBrowserLib: production code library (no @main) ──
        // Contains Views, ViewModels, Services. Other targets depend on this.
        .target(
            name: "OWLBrowserLib",
            path: ".",
            exclude: [
                "App",
                "CLI",
                "Tests",
                "UITest",
                "UITests",
                "TestKit",
                "Package.swift",
                "Resources",
                "project.yml",
                "OWLBrowser.xcodeproj",
                "OWLBrowser.entitlements",
                "default.profraw",
            ],
            sources: [
                "Models",
                "Views",
                "ViewModels",
                "Services",
            ],
            swiftSettings: owlBridgeSwiftSettings
        ),

        // ── OWLBrowser: executable entry point ──
        // Only contains @main app struct + AppDelegate.
        .executableTarget(
            name: "OWLBrowser",
            dependencies: ["OWLBrowserLib"],
            path: "App",
            swiftSettings: owlBridgeSwiftSettings,
            linkerSettings: owlBridgeLinkerSettings
        ),

        // ── OWLCLI: standalone CLI executable ──
        // Communicates with running GUI via Unix socket.
        .executableTarget(
            name: "OWLCLI",
            dependencies: [
                "OWLBrowserLib",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "CLI",
            swiftSettings: owlBridgeSwiftSettings,
            linkerSettings: owlBridgeLinkerSettings
        ),

        // ── OWLTestKit: shared test utilities library ──
        // Contains AppHost, UIDriver, WebDriver, etc. (Phase B)
        .target(
            name: "OWLTestKit",
            dependencies: ["OWLBrowserLib"],
            path: "TestKit",
            swiftSettings: owlBridgeSwiftSettings
        ),

        // ── OWLUITest: standalone CGEvent test executable ──
        .executableTarget(
            name: "OWLUITest",
            path: "UITest",
            swiftSettings: owlBridgeSwiftSettings,
            linkerSettings: owlBridgeLinkerSettings
        ),

        // ── OWLBrowserTests: pipeline integration tests (existing) ──
        .testTarget(
            name: "OWLBrowserTests",
            path: "Tests",
            exclude: ["Unit", "Integration"],
            swiftSettings: owlBridgeSwiftSettings,
            linkerSettings: owlBridgeLinkerSettings
        ),

        // ── OWLUnitTests: ViewModel + pure logic tests (Phase C) ──
        .testTarget(
            name: "OWLUnitTests",
            dependencies: ["OWLBrowserLib"],
            path: "Tests/Unit",
            swiftSettings: owlBridgeSwiftSettings,
            linkerSettings: owlBridgeLinkerSettings
        ),

        // ── OWLIntegrationTests: cross-layer E2E tests (Phase B) ──
        .testTarget(
            name: "OWLIntegrationTests",
            dependencies: ["OWLTestKit"],
            path: "Tests/Integration",
            exclude: ["OWLNSEventPOCTests.swift", "POC_RESULTS.md"],
            swiftSettings: owlBridgeSwiftSettings,
            linkerSettings: owlBridgeLinkerSettings
        ),
    ]
)
