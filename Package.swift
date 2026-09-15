// swift-tools-version: 5.9
import PackageDescription

// NotchBuddy is deliberately dependency-free.
//
// Every third-party package is a permanent addition to the binary's RAM floor,
// launch time and audit surface. Since the #1 complaint about this app category
// is idle resource cost (see docs/decisions/0001-native-appkit-over-electron.md),
// the bar for a dependency is "we cannot reasonably hand-roll it". So far nothing
// has cleared that bar -- including the terminal emulator, which is ~600 lines of
// VT100 handling instead of a package that pulls in a full xterm feature set.
let package = Package(
    name: "NotchBuddy",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "NotchBuddy", targets: ["NotchBuddy"])
    ],
    targets: [
        .executableTarget(
            name: "NotchBuddy",
            path: "Sources/NotchBuddy",
            swiftSettings: [
                .unsafeFlags(["-suppress-warnings"], .when(configuration: .release))
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("IOKit"),
                .linkedFramework("EventKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("Carbon"),
                .linkedFramework("Security"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("CoreLocation"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Network"),
                .linkedFramework("CryptoKit")
            ]
        ),
        // Tests cover the parts that are pure logic and therefore genuinely
        // testable without a window server: the polling hub's coalescing, the
        // arbitration rule, the VT parser, the JSON-path resolver and the
        // snippet store's retention rules. UI and IOKit paths are verified by
        // running the app, not mocked into meaninglessness.
        .testTarget(
            name: "NotchBuddyTests",
            dependencies: ["NotchBuddy"],
            path: "Tests/NotchBuddyTests"
        )
    ]
)
