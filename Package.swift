// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "DJIMicTray",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "DJIMicTray",
            path: "Sources/DJIMicTray",
            linkerSettings: [
                .linkedFramework("IOUSBHost"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreBluetooth"),
            ]
        ),
    ]
)
