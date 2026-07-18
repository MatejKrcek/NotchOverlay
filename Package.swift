// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "NotchOverlay",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "NotchOverlay", path: "Sources/NotchOverlay")
    ]
)
