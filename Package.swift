// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HeadsetControl-MacOSTray",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .systemLibrary(
            name: "HeadsetControlCLib",
            path: "HeadsetControlCLib"
        ),
        .executableTarget(
            name: "HeadsetControl-MacOSTray",
            dependencies: ["HeadsetControlCLib"],
            path: "HeadsetControl-MacOSTray"
        ),
        .testTarget(
            name: "HeadsetControl-MacOSTrayTests",
            dependencies: ["HeadsetControl-MacOSTray"],
            path: "HeadsetControl-MacOSTrayTests"
        )
    ]
)
