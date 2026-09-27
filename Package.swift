// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Scratch",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ScratchKit", targets: ["ScratchKit"]),
        .executable(name: "Scratch", targets: ["Scratch"]),
        // Installed as `scratch`; a distinct product name because Scratch and scratch would
        // collide on a case-insensitive volume.
        .executable(name: "ScratchCLI", targets: ["ScratchCLI"]),
    ],
    dependencies: [
        .package(path: "../hudkit"),
    ],
    targets: [
        // Pure core: pads, the markdown-file store, search, inbox, transforms. No UI.
        .target(
            name: "ScratchKit",
            path: "Sources/ScratchKit"
        ),
        .executableTarget(
            name: "Scratch",
            dependencies: ["ScratchKit", .product(name: "HUDKit", package: "hudkit")],
            path: "Sources/Scratch",
            // Bundle files, assembled into the .app by hudkit/scripts/hud-build.sh.
            exclude: ["Resources"]
        ),
        // `scratch <command> [key=value ...]`: a thin client for Scratch's MacHUD control socket.
        .executableTarget(
            name: "ScratchCLI",
            dependencies: [.product(name: "HUDKit", package: "hudkit")],
            path: "Sources/ScratchCLI"
        ),
        .testTarget(
            name: "ScratchKitTests",
            dependencies: ["ScratchKit"],
            path: "Tests/ScratchKitTests"
        ),
        // Host logic in the app target (e.g. where `panel mode parked` parks) and the shipped
        // manifest/settings schema/Info.plist.
        .testTarget(
            name: "ScratchTests",
            dependencies: ["Scratch", "ScratchKit", .product(name: "HUDKit", package: "hudkit")],
            path: "Tests/ScratchTests"
        ),
    ]
)
