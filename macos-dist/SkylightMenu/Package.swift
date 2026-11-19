// swift-tools-version: 6.0
// SwiftPM builds the menu executable. The packaging scripts assemble and sign
// the app bundle and its streaming service.
import PackageDescription

let package = Package(
    name: "SkylightMenu",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        // Models and settings logic shared by the menu and headless tests.
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
