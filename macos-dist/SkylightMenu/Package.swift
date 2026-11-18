// swift-tools-version: 6.0
// S0 walking skeleton (docs/design/menubar-app.md): the native Skylight menubar app.
// A plain SwiftPM executable -- build.sh wraps the built binary into a proper
// SkylightMenu.app bundle (Info.plist, LSUIElement) and signs it. No Xcode project needed.
import PackageDescription

let package = Package(
    name: "SkylightMenu",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        // Pure logic: config-schema decode model + the hand-authored settings-catalog enums/
        // formatters. No SwiftUI View bodies, no HostConnection/XPC calls -- this is the one
        // piece with real unit-test coverage.
        .target(
            name: "SkylightMenuCore",
            path: "Sources/SkylightMenuCore"
        ),
        .executableTarget(
            name: "SkylightMenu",
            dependencies: ["SkylightMenuCore"],
            path: "Sources/SkylightMenu"
        ),
        .testTarget(
            name: "SkylightMenuCoreTests",
            dependencies: ["SkylightMenuCore"],
            path: "Tests/SkylightMenuCoreTests"
        ),
        .testTarget(
            name: "SkylightMenuTests",
            dependencies: ["SkylightMenu", "SkylightMenuCore"],
            path: "Tests/SkylightMenuTests"
        )
    ]
)
